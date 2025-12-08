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
function Get-AgentExecutorPath {
    <#
        Returns the path to AgentExecutor.exe if present.
        This binary ships with the Intune Management Extension and can
        proxy WinGet operations even when winget.exe is not installed.
    #>
    $defaultPath = "C:\Program Files (x86)\Microsoft Intune Management Extension\agentexecutor.exe"
    if (Test-Path $defaultPath) {
        return $defaultPath
    }
    return $null
}

function Invoke-WIPWinGetOperation {
    <#
        Unified wrapper for WinGet operations.

        - If $WingetPath is provided, call winget.exe directly (current behavior).
        - If $WingetPath is $null, fall back to AgentExecutor.exe -executeWinGet
          where available. This primarily supports Microsoft Store sourced apps.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install','Uninstall')]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [string[]]$ExtraArgs,

        [string]$WingetPath,

        [string]$RepositoryType = "MicrosoftStore",  # AgentExecutor WinGet library currently supports MS Store
        [string]$InstallScope   = "System"
    )

    if ($WingetPath) {
        # Use winget.exe as before
        if ($Operation -eq 'Install') {
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
        }
        else {
            $args = @(
                "uninstall",
                "--id", $AppId,
                "-e",
                "--silent",
                "--disable-interactivity",
                "--accept-source-agreements"
            )
        }

        if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
            $args += $ExtraArgs
        }

        Write-Log "Executing: winget $($args -join ' ')"
        $out = & $WingetPath @args 2>&1
        $rawExit = $LASTEXITCODE

        Write-Log ($out | Out-String).Trim()
        Write-Log "Raw winget $Operation exit code: $rawExit"

        $mappedExit = if ($Operation -eq 'Install') {
            Map-InstallerExitCode -RawExit $rawExit
        }
        else {
            Map-InstallerExitCode -RawExit $rawExit -IsUninstall
        }

        if ($mappedExit -eq 0 -and $rawExit -ne 0) {
            $mappedExit = if ($Operation -eq 'Install') { 1003 } else { 1005 }
        }

        return [PSCustomObject]@{
            RawExit    = $rawExit
            MappedExit = $mappedExit
            Tool       = "winget.exe"
        }
    }
    else {
        # Fallback: AgentExecutor.exe -executeWinGet
        $agent = Get-AgentExecutorPath
        if (-not $agent) {
            Write-Log "Neither winget.exe nor AgentExecutor.exe could be located for '$AppId'." "ERROR"
            throw "No WinGet-capable tool available."
        }

        $pipeName = "WIP-{0}" -f ([guid]::NewGuid().ToString("N"))

        if ($Operation -eq 'Install') {
            $args = @(
                "-executeWinGet",
                "-packageId", $AppId,
                "-operationType", "Install",
                "-repositoryType", $RepositoryType,
                "-installScope", $InstallScope,
                "-installTimeout", "60",
                "-installVisibility", "0",
                "-pipeHandle", $pipeName
            )
        }
        else {
            $args = @(
                "-executeWinGet",
                "-packageId", $AppId,
                "-operationType", "Uninstall",
                "-repositoryType", $RepositoryType,
                "-installScope", $InstallScope,
                "-pipeHandle", $pipeName
            )
        }

        Write-Log "Executing AgentExecutor fallback: $agent $($args -join ' ')" "INFO"
        $out = & $agent @args 2>&1
        $rawExit = $LASTEXITCODE

        Write-Log ($out | Out-String).Trim()
        Write-Log "AgentExecutor $Operation exit code: $rawExit"

        # Conservative mapping: 0 = success, anything else = generic WinGet failure
        if ($Operation -eq 'Install') {
            $mappedExit = if ($rawExit -eq 0) { 0 } else { 1003 }
        }
        else {
            $mappedExit = if ($rawExit -eq 0) { 0 } else { 1005 }
        }

        return [PSCustomObject]@{
            RawExit    = $rawExit
            MappedExit = $mappedExit
            Tool       = "AgentExecutor.exe"
        }
    }
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
    # Locate winget (optional)
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
    }
    catch {
        Write-Log "winget.exe not found, will try AgentExecutor.exe fallback where available." "WARN"
        $winget = $null
    }

    foreach ($AppRaw in $AppIDs) {

        # AppRaw may contain extra arguments from WingetIntunePackager (e.g. '--version', '--override').
        $tokens    = $AppRaw -split ' '
        $AppId     = $tokens[0]
        $extraArgs = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }

        if ($Uninstall) {
            Write-Log "Uninstalling '$AppId' (raw: '$AppRaw')."

            $result = Invoke-WIPWinGetOperation -Operation 'Uninstall' -AppId $AppId -ExtraArgs $extraArgs -WingetPath $winget
            Set-ExitCode -Code $result.MappedExit -AppId $AppId -Phase "Uninstall"
        }
        else {
            Write-Log "Installing/upgrading '$AppId' (raw: '$AppRaw')."

            $result = Invoke-WIPWinGetOperation -Operation 'Install' -AppId $AppId -ExtraArgs $extraArgs -WingetPath $winget
            Set-ExitCode -Code $result.MappedExit -AppId $AppId -Phase "Install"

            # Optional post-install mod script, only if install succeeded
            if ($result.MappedExit -eq 0) {
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
