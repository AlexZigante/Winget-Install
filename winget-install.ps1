[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppIDs,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

if (-not $AppIDs -or $AppIDs.Count -eq 0) {
    Write-Error "No AppIDs provided."
    exit 1002
}

# Use first AppId (first token) to build log folder name
$baseToken = ($AppIDs[0] -split ' ')[0]
$logDirName = $baseToken -replace '[^\w\.-]', '_'

$imeLogRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $imeLogRoot)) {
    New-Item -ItemType Directory -Path $imeLogRoot -Force | Out-Null
}

$logRoot = Join-Path $imeLogRoot $logDirName
if (-not (Test-Path $logRoot)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}

$phaseName = if ($Uninstall) { "Uninstall" } else { "Install" }
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logRoot ("{0}_{1}.log" -f $phaseName, $timestamp)

Start-Transcript -Path $logFile -Append | Out-Null

$script:ExitCode = 0

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $ts, $Level, $Message
    Write-Host $line
}

# BurntToast helpers - install from PSGallery on the fly and remove on exit
$script:BurntToastAvailable = $false
$script:BurntToastInstalledThisRun = $false

function Initialize-Toast {
    if ($script:BurntToastAvailable) { return }

    try {
        # Check if BurntToast is already available
        $installed = Get-Module -ListAvailable BurntToast | Select-Object -First 1
        if (-not $installed) {
            # Install from PSGallery into CurrentUser scope
            Write-Log "BurntToast not found. Installing from PSGallery..." "INFO"

            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            }

            if (-not (Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
                Register-PSRepository -Default -ErrorAction Stop
            }

            $params = @{
                Name         = 'BurntToast'
                Force        = $true
                Scope        = 'CurrentUser'
                AllowClobber = $true
            }
            Install-Module @params -ErrorAction Stop | Out-Null
            $script:BurntToastInstalledThisRun = $true
        }

        Import-Module BurntToast -Force -ErrorAction Stop
        $script:BurntToastAvailable = $true
        Write-Log "BurntToast module loaded." "INFO"
    }
    catch {
        Write-Log "BurntToast not available: $($_.Exception.Message)" "WARN"
        $script:BurntToastAvailable = $false
    }
}

function Cleanup-ToastModule {
    try {
        if ($script:BurntToastAvailable) {
            Remove-Module BurntToast -ErrorAction SilentlyContinue
        }
        if ($script:BurntToastInstalledThisRun) {
            # Remove the module from disk only if we installed it in this run
            Uninstall-Module -Name BurntToast -AllVersions -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Best-effort cleanup; ignore failures
    }
}

function Show-AppToast {
    param(
        [string]$AppId,
        [string]$Phase,
        [string]$Message
    )

    if (-not $script:BurntToastAvailable) { return }

    try {
        $title = "WinGet Intune - $Phase"
        $body  = "$AppId - $Message"
        New-BurntToastNotification -Text $title, $body | Out-Null
    }
    catch {
        Write-Log "Failed to show BurntToast notification: $($_.Exception.Message)" "WARN"
    }
}

function Set-ExitCode {
    param(
        [int]$Code,
        [string]$AppId,
        [string]$Phase
    )

    $desc = switch ($Code) {
        0     { "Success" }
        1707  { "Success (no action)" }
        3010  { "Soft reboot required" }
        1641  { "Hard reboot required" }
        1618  { "Another installer in progress" }
        1001  { "winget.exe not found" }
        1002  { "Script internal error" }
        1003  { "WinGet command failed" }
        1004  { "Post-install mod script error" }
        default { "Error/Unknown" }
    }

    Write-Log "[$Phase][$AppId] exit code $Code → $desc"

    if ($script:ExitCode -eq 0 -and $Code -ne 0) {
        $script:ExitCode = $Code
    }
}

try {
    # Locate winget
    try {
        $winget = (Get-Command winget.exe -ErrorAction Stop).Source
        Write-Log "Using winget at '$winget'."
    }
    catch {
        Write-Log "winget.exe not found: $($_.Exception.Message)" "ERROR"
        Initialize-Toast
        Show-AppToast -AppId $baseToken -Phase $phaseName -Message "winget.exe not available (code 1001)."
        $script:ExitCode = 1001
        return
    }

    Initialize-Toast
    Show-AppToast -AppId $baseToken -Phase $phaseName -Message "Starting WinGet $phaseName. See $logFile for details."

    foreach ($AppRaw in $AppIDs) {

        # AppRaw may contain extra arguments from WingetIntunePackager (e.g. '--version', '--override').
        $tokens    = $AppRaw -split ' '
        $AppId     = $tokens[0]
        $extraArgs = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }

        if ($Uninstall) {
            Write-Log "Uninstalling '$AppId' (raw: '$AppRaw')."

            $args = @(
                "uninstall",
                "--id", $AppId,
                "-e",
                "--silent",
                "--disable-interactivity",
                "--accept-source-agreements"
            )

            if ($extraArgs.Count -gt 0) {
                $args += $extraArgs
            }

            Write-Log "Executing: winget $($args -join ' ')"
            $out = & $winget @args 2>&1
            $exit = $LASTEXITCODE

            Write-Log ($out | Out-String).Trim()

            if ($exit -eq 0) {
                Show-AppToast -AppId $AppId -Phase "Uninstall" -Message "Completed successfully."
            }
            else {
                Show-AppToast -AppId $AppId -Phase "Uninstall" -Message "Failed (code $exit)."
            }

            Set-ExitCode -Code $exit -AppId $AppId -Phase "Uninstall"
        }
        else {
            Write-Log "Installing/upgrading '$AppId' (raw: '$AppRaw')."

            $args = @(
                "install",
                "--id", $AppId,
                "-e",
                "--silent",
                "--disable-interactivity",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--scope", "machine",
                "-s", "winget"
            )

            if ($extraArgs.Count -gt 0) {
                $args += $extraArgs
            }

            Write-Log "Executing: winget $($args -join ' ')"
            $out = & $winget @args 2>&1
            $exit = $LASTEXITCODE

            Write-Log ($out | Out-String).Trim()

            if ($exit -eq 0) {
                Show-AppToast -AppId $AppId -Phase "Install" -Message "Completed successfully."
            }
            else {
                Show-AppToast -AppId $AppId -Phase "Install" -Message "Failed (code $exit)."
            }

            Set-ExitCode -Code $exit -AppId $AppId -Phase "Install"

            # Optional post-install mod script, only if install succeeded
            if ($exit -eq 0) {
                $modsPath = Join-Path $PSScriptRoot "mods"
                $modFile  = Join-Path $modsPath ($AppId + ".ps1")

                if (Test-Path $modFile) {
                    Write-Log "Running mod script '$modFile'."
                    try {
                        . $modFile
                    }
                    catch {
                        Write-Log "Mod script failed: $($_.Exception.Message)" "ERROR"
                        if ($script:ExitCode -eq 0) {
                            $script:ExitCode = 1004
                        }
                    }
                }
                else {
                    Write-Log "No mod script found for '$AppId'."
                }
            }
        }
    }
}
finally {
    try {
        Stop-Transcript | Out-Null
    } catch {}
    Cleanup-ToastModule
}

exit $script:ExitCode
