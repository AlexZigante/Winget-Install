[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppIDs,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------
# Return code scheme (for Intune Win32App program results)
# ---------------------------------------------------------
# 0     : Success (standard)
# 1707  : Success, no action (MSI)
# 3010  : Soft reboot required
# 1641  : Hard reboot required
# 1618  : Retry (another installer in progress)
#
# Custom WIP failure codes:
# 1000  : Unknown fatal error (top-level catch)
# 1001  : winget.exe not found
# 1002  : Script precondition/parameter error
# 1003  : WinGet INSTALL failed
# 1004  : Post-install mod script error
# 1005  : WinGet UNINSTALL failed
# ---------------------------------------------------------

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

$StandardInstallerCodes = @(0, 1707, 3010, 1641, 1618)

function Map-InstallerExitCode {
    param(
        [int]$RawExit,
        [switch]$IsUninstall
    )

    if ($StandardInstallerCodes -contains $RawExit) {
        return $RawExit
    }

    if ($IsUninstall) {
        return 1005
    }
    else {
        return 1003
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
        1000  { "Unknown fatal error (top-level)" }
        1001  { "winget.exe not found" }
        1002  { "Script precondition/parameter error" }
        1003  { "WinGet INSTALL failed" }
        1004  { "Post-install mod script error" }
        1005  { "WinGet UNINSTALL failed" }
        default { "Error/Unknown" }
    }

    Write-Log "[$Phase][$AppId] exit code $Code → $desc"

    if ($script:ExitCode -eq 0 -and $Code -ne 0) {
        $script:ExitCode = $Code
    }
}

function Get-WingetPath {
    try {
        $cmd = Get-Command winget.exe -ErrorAction Stop
        return $cmd.Source
    }
    catch {
        Write-Log "winget.exe not in PATH, searching Program Files\WindowsApps..." "WARN"
        $candidates = Get-ChildItem "C:\Program Files\WindowsApps" -Recurse -Filter winget.exe -ErrorAction SilentlyContinue
        if ($candidates -and $candidates.Count -gt 0) {
            $path = $candidates[0].FullName
            Write-Log "Found winget.exe at '$path'." "INFO"
            return $path
        }
        throw
    }
}

try {
    # Locate winget
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
    }
    catch {
        Write-Log "winget.exe not found: $($_.Exception.Message)" "ERROR"
        $script:ExitCode = 1001
        throw
    }

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
            $rawExit = $LASTEXITCODE

            Write-Log ($out | Out-String).Trim()
            Write-Log "Raw winget uninstall exit code: $rawExit"

            $mappedExit = Map-InstallerExitCode -RawExit $rawExit -IsUninstall
            if ($mappedExit -eq 0 -and $rawExit -ne 0) {
                $mappedExit = 1005
            }

            Set-ExitCode -Code $mappedExit -AppId $AppId -Phase "Uninstall"
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
            $rawExit = $LASTEXITCODE

            Write-Log ($out | Out-String).Trim()
            Write-Log "Raw winget install exit code: $rawExit"

            $mappedExit = Map-InstallerExitCode -RawExit $rawExit
            if ($mappedExit -eq 0 -and $rawExit -ne 0) {
                $mappedExit = 1003
            }

            Set-ExitCode -Code $mappedExit -AppId $AppId -Phase "Install"

            # Optional post-install mod script, only if install succeeded
            if ($mappedExit -eq 0) {
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
                        Set-ExitCode -Code 1004 -AppId $AppId -Phase "Install"
                    }
                }
                else {
                    Write-Log "No mod script found for '$AppId'."
                }
            }
        }
    }
}
catch {
    if ($script:ExitCode -eq 0) {
        # Unexpected fatal error not mapped previously
        $script:ExitCode = 1000
        Write-Log "Unexpected fatal error: $($_.Exception.Message)" "ERROR"
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}

exit $script:ExitCode
