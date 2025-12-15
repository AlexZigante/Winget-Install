[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppIDs,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0


# Selected WinGet CLI exit codes we care about for detection/logging
$WinGetCodeInfo = @{
    -1978335212 = "APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND: No packages found"
    -1978335210 = "APPINSTALLER_CLI_ERROR_MULTIPLE_APPLICATIONS_FOUND: Multiple packages found matching the criteria"
    -1978335189 = "APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE: No applicable update found"
}

function Write-WinGetCodeInfo {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Code
    )
    if ($WinGetCodeInfo.ContainsKey($Code)) {
        Write-Log ("WinGet exit code {0}: {1}" -f $Code, $WinGetCodeInfo[$Code]) "INFO"
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    Write-Host $line
    try {
        Add-Content -Path $Global:LogFile -Value $line
    }
    catch {
    }
}
function Set-AppLogFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        [switch]$Uninstall
    )

    $safeName   = $AppId -replace '[^\w\.-]', '_'
    $imeLogRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
    if (-not (Test-Path $imeLogRoot)) {
        New-Item -ItemType Directory -Path $imeLogRoot -Force | Out-Null
    }
    $logRoot = Join-Path $imeLogRoot $safeName
    if (-not (Test-Path $logRoot)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }

    $ts     = Get-Date -Format "yyyyMMdd_HHmmss"
    $prefix = if ($Uninstall) { "Uninstall" } else { "Install" }
    $Global:LogFile = Join-Path $logRoot ("{0}_{1}.log" -f $prefix, $ts)
}


try {
}
catch {
    Write-Log "Failed to start transcript: $($_.Exception.Message)" "WARN"
}

function Map-InstallerExitCode {
    param(
        [Parameter(Mandatory=$true)]
        [int]$RawExit,
        [switch]$IsUninstall
    )

    switch ($RawExit) {
        0    { return 0     }
        1707 { return 0     }
        3010 { return 3010  }
        1641 { return 1641  }
        1618 { return 1618  }
        default { return $RawExit }
    }
}

function Set-ExitCode {
    param(
        [Parameter(Mandatory=$true)]
        [int]$Code,
        [string]$AppId,
        [string]$Phase
    )

    if ($Code -ne 0) {
        Write-Log "Setting script ExitCode to $Code (AppId='$AppId', Phase='$Phase')." "WARN"
        $script:ExitCode = $Code
    }
    else {
        Write-Log "Operation successful (AppId='$AppId', Phase='$Phase', Code=$Code)." "INFO"
    }
}

function Get-WingetPath {
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        return $cmd.Source
    }
    catch {
        Write-Log "winget.exe not found via PATH: $($_.Exception.Message)" "WARN"
    }

    $progApps = "C:\Program Files\WindowsApps"
    if (Test-Path $progApps) {
        try {
            $candidate = Get-ChildItem -Path $progApps -Recurse -Filter 'winget.exe' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($candidate) {
                Write-Log "winget.exe found in WindowsApps: '$($candidate.FullName)'."
                return $candidate.FullName
            }
        }
        catch {
            Write-Log "Error while searching '$progApps' for winget.exe: $($_.Exception.Message)" "WARN"
        }
    }

    $defaultUserWinget = "C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $defaultUserWinget) {
        Write-Log "winget.exe found at defaultuser0 path: '$defaultUserWinget'."
        return $defaultUserWinget
    }

    Write-Log "winget.exe not found, attempting to register App Installer (Microsoft.DesktopAppInstaller_8wekyb3d8bbwe)..." "WARN"

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        Write-Log "App Installer registration completed, re-checking for winget.exe."
    }
    catch {
        Write-Log "Failed to register App Installer: $($_.Exception.Message)" "ERROR"
    }

    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        return $cmd.Source
    }
    catch {
        Write-Log "winget.exe still not found via PATH after App Installer registration." "WARN"
    }

    if (Test-Path $progApps) {
        try {
            $candidate = Get-ChildItem -Path $progApps -Recurse -Filter 'winget.exe' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($candidate) {
                Write-Log "winget.exe found in WindowsApps after App Installer registration: '$($candidate.FullName)'."
                return $candidate.FullName
            }
        }
        catch {
            Write-Log "Error while searching '$progApps' for winget.exe after App Installer registration: $($_.Exception.Message)" "WARN"
        }
    }

    if (Test-Path $defaultUserWinget) {
        Write-Log "winget.exe found at defaultuser0 path after App Installer registration: '$defaultUserWinget'."
        return $defaultUserWinget
    }

    throw "winget.exe not found even after attempting App Installer registration."
}

Write-Log "========== Winget-Install starting =========="

try {
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
        Write-Log "Refreshing WinGet sources via 'winget upgrade --accept-source-agreements'." "INFO"
        try {
            $null = & $winget source update --accept-source-agreements 2>&1
            $null = & $winget upgrade --accept-source-agreements 2>&1
        }
        catch {
            Write-Log "Source refresh via 'winget upgrade' failed: $($_.Exception.Message)" "WARN"
        }
    }
    catch {
        Write-Log "winget.exe not available even after App Installer registration: $($_.Exception.Message)" "ERROR"
        $script:ExitCode = 1001
        throw
    }

    foreach ($AppRaw in $AppIDs) {

        $tokens    = $AppRaw -split ' '
        $AppId     = $tokens[0]
        $extraArgs = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }
        # Initialize per-app log file
        Set-AppLogFile -AppId $AppId -Uninstall:([bool]$Uninstall)
        Write-Log ("===== {0} for '{1}' (raw: '{2}') =====" -f ($(if ($Uninstall) { "Uninstall" } else { "Install" }), $AppId, $AppRaw))


        if ($Uninstall) {
            Write-Log "Uninstalling '$AppId' (raw: '$AppRaw')."

            $args = @(
                "uninstall",
                "--id", $AppId,
                "-e",
                "--silent",
                "--disable-interactivity",
                "--accept-source-agreements",
                "--accept-package-agreements"
            )

            if ($extraArgs.Count -gt 0) {
                $args += $extraArgs
            }

            Write-Log "Executing: winget $($args -join ' ')"
            $out = & $winget @args 2>&1
            $rawExit = $LASTEXITCODE

            Write-Log ($out | Out-String).Trim()
            Write-Log "Raw winget Uninstall exit code: $rawExit"
            Write-WinGetCodeInfo -Code $rawExit

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
                "--accept-source-agreements",
                "--accept-package-agreements",
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
            Write-Log "Raw winget Install exit code: $rawExit"
            Write-WinGetCodeInfo -Code $rawExit

            $mappedExit = Map-InstallerExitCode -RawExit $rawExit
            if ($mappedExit -eq 0 -and $rawExit -ne 0) {
                $mappedExit = 1003
            }

            Set-ExitCode -Code $mappedExit -AppId $AppId -Phase "Install"

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
        $script:ExitCode = 1000
        Write-Log "Unexpected fatal error: $($_.Exception.Message)" "ERROR"
    }
}
finally {
    Write-Log "Winget-Install finished with ExitCode $script:ExitCode."}

exit $script:ExitCode