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


function Get-IMELogRoot {
    # Prefer ProgramData (visible in IME logs), but fall back to per-user log path when running in user context.
    $primary = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
    try {
        if (-not (Test-Path $primary)) {
            New-Item -ItemType Directory -Path $primary -Force -ErrorAction Stop | Out-Null
        }
        # quick write test (ProgramData can be read-only for user context on some devices)
        $testFile = Join-Path $primary ".__wip_write_test"
        "test" | Out-File -FilePath $testFile -Force -ErrorAction Stop
        Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
        return $primary
    } catch {
        $fallback = Join-Path $env:LOCALAPPDATA "Microsoft\IntuneManagementExtension\Logs"
        try {
            if (-not (Test-Path $fallback)) {
                New-Item -ItemType Directory -Path $fallback -Force -ErrorAction Stop | Out-Null
            }
        } catch {
            # Last resort: TEMP (should be writable)
            $fallback = Join-Path $env:TEMP "Microsoft\IntuneManagementExtension\Logs"
            if (-not (Test-Path $fallback)) { New-Item -ItemType Directory -Path $fallback -Force | Out-Null }
        }
        return $fallback
    }
}

function Initialize-GlobalLogFile {
    # Create a general run log before per-app log files are created.
    $root = Get-IMELogRoot
    $runDir = Join-Path $root "Winget-Install"
    try {
        if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force -ErrorAction Stop | Out-Null }
    } catch {
        # If even this fails, fall back to TEMP
        $runDir = Join-Path $env:TEMP "Winget-Install"
        if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $Global:LogFile = Join-Path $runDir ("Run_{0}.log" -f $ts)
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
        if ($Global:LogFile) {
            Add-Content -Path $Global:LogFile -Value $line -ErrorAction SilentlyContinue
        }
    } catch {
        # Never fail the script due to logging
    }
}

function Set-AppLogFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        [switch]$Uninstall
    )

    $safeName   = $AppId -replace '[^\\w\\.-]', '_'
    $imeLogRoot = Get-IMELogRoot
    $logRoot    = Join-Path $imeLogRoot $safeName

    try {
        if (-not (Test-Path $logRoot)) {
            New-Item -ItemType Directory -Path $logRoot -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        # Fallback to TEMP if per-app folder cannot be created
        $logRoot = Join-Path $env:TEMP $safeName
        if (-not (Test-Path $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
    }

    $ts     = Get-Date -Format "yyyyMMdd_HHmmss"
    $prefix = if ($Uninstall) { "Uninstall" } else { "Install" }
    $Global:LogFile = Join-Path $logRoot ("{0}_{1}.log" -f $prefix, $ts)
}

Initialize-GlobalLogFile
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
    # Find winget.exe without attempting any installation/registration.
    # This script relies on the WinGet dependency app (or OS) to ensure WinGet exists.
    # Returns full path to winget.exe, or throws if not found.

    # 1) PATH / AppExecutionAlias
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        if ($cmd -and $cmd.Source) {
            Write-Log "winget.exe found via PATH: '$($cmd.Source)'." "INFO"
            return $cmd.Source
        }
    }
    catch {
        Write-Log "winget.exe not found via PATH: $($_.Exception.Message)" "WARN"
    }

    # 2) Common alias locations
    $aliasCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"),
        "C:\Users\Default\AppData\Local\Microsoft\WindowsApps\winget.exe",
        "C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe"
    ) | Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Unique

    foreach ($p in $aliasCandidates) {
        if (Test-Path $p) {
            Write-Log "winget.exe found at alias path: '$p'." "INFO"
            return $p
        }
    }

    # 3) Per-user WindowsApps Desktop App Installer folder (common in Autopilot first-login)
    $userWA = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if (Test-Path $userWA) {
        try {
            $daiDirsU = Get-ChildItem -Path $userWA -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "Microsoft.Desktop.AppInstaller_*" -or $_.Name -like "Microsoft.DesktopAppInstaller_*" } |
                Sort-Object -Property Name -Descending
            foreach ($d in $daiDirsU) {
                $candidateU = Join-Path $d.FullName "winget.exe"
                if (Test-Path $candidateU) {
                    Write-Log "winget.exe found in user WindowsApps DesktopAppInstaller folder: '$candidateU'." "INFO"
                    return $candidateU
                }
            }
        } catch {
            Write-Log "Error while searching user WindowsApps for winget.exe: $($_.Exception.Message)" "WARN"
        }
    }

    # 4) WindowsApps (fast path: Desktop App Installer folders)
    $progApps = "C:\Program Files\WindowsApps"
    if (Test-Path $progApps) {
        try {
            $daiDirs = Get-ChildItem -Path $progApps -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe" } |
                Sort-Object -Property Name -Descending

            foreach ($d in $daiDirs) {
                $candidate = Join-Path $d.FullName "winget.exe"
                if (Test-Path $candidate) {
                    Write-Log "winget.exe found in WindowsApps DesktopAppInstaller folder: '$candidate'." "INFO"
                    return $candidate
                }
            }

            # Fallback: recursive search (can be slow, but last resort)
            $candidate2 = Get-ChildItem -Path $progApps -Recurse -Filter 'winget.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($candidate2) {
                Write-Log "winget.exe found in WindowsApps (recursive): '$($candidate2.FullName)'." "INFO"
                return $candidate2.FullName
            }
        }
        catch {
            Write-Log "Error while searching '$progApps' for winget.exe: $($_.Exception.Message)" "WARN"
        }
    }

    # 4) System locations (rare)
    $sysCandidates = @(
        (Join-Path $env:SystemRoot "System32\winget.exe"),
        (Join-Path $env:SystemRoot "SysWOW64\winget.exe")
    )
    foreach ($p in $sysCandidates) {
        if (Test-Path $p) {
            Write-Log "winget.exe found at system path: '$p'." "INFO"
            return $p
        }
    }

    throw "winget.exe not found. Ensure 'WinGet Dependency for WIP' (or OS WinGet) is installed."
}


Write-Log "========== Winget-Install starting =========="

try {
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
        Write-Log "Refreshing WinGet sources (update) before running package operations." "INFO"
        try {
            $null = & $winget source update --disable-interactivity 2>&1
            # (skipped) winget upgrade is intentionally not called during Autopilot/first-login
        }
        catch {
            Write-Log "Source refresh (source update) failed: $($_.Exception.Message)" "WARN"
        }
    }
    catch {
        Write-Log "winget.exe not available: $($_.Exception.Message)" "ERROR"
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

            # Determine if a specific version is pinned via --version <x> in extra args
            $pinnedVersion = $null
            for ($i = 0; $i -lt $extraArgs.Count; $i++) {
                if ($extraArgs[$i] -eq "--version" -and ($i + 1) -lt $extraArgs.Count) {
                    $pinnedVersion = $extraArgs[$i + 1]
                    break
                }
            }

            # If no pinned version, try to upgrade if the app is already installed
            $didUpgradeAttempt = $false
            $upgradeSucceeded  = $false
            if (-not $pinnedVersion) {
                try {
                    Write-Log "Checking if '$AppId' is already installed via winget list." "INFO"
                    $listOut = & $winget list --id $AppId -e -s winget --accept-source-agreements 2>&1
                    $listExit = $LASTEXITCODE
                    Write-Log "winget list exit code: $listExit" "INFO"
                    Write-Log ("winget list output:`n{0}" -f (($listOut | Out-String).Trim())) "INFO"
                    Write-WinGetCodeInfo -Code $listExit

                    $isInstalled = $false
                    if ($listExit -eq 0) {
                        foreach ($ln in $listOut) {
                            if ($ln -match [regex]::Escape($AppId)) { $isInstalled = $true; break }
                        }
                    }
                    elseif ($listExit -eq -1978335212) {
                        # No installed package found matching input criteria
                        $isInstalled = $false
                    }

                    if ($isInstalled) {
                        $didUpgradeAttempt = $true
                        Write-Log "App appears installed. Attempting winget upgrade for '$AppId'." "INFO"
                        $upArgs = @(
                            "upgrade",
                            "--id", $AppId,
                            "-e",
                            "--silent",
                            "--disable-interactivity",
                            "--accept-source-agreements",
                            "--accept-package-agreements",
                            "-s", "winget"
                        )
                        if ($extraArgs.Count -gt 0) {
                            $upArgs += $extraArgs
                        }
                        Write-Log ("Executing: winget {0}" -f ($upArgs -join " ")) "INFO"
                        $upOut = & $winget @upArgs 2>&1
                        $upExit = $LASTEXITCODE
                        Write-Log ("winget upgrade output:`n{0}" -f (($upOut | Out-String).Trim())) "INFO"
                        Write-Log "Raw winget Upgrade exit code: $upExit" "INFO"
                        Write-WinGetCodeInfo -Code $upExit

                        if ($upExit -eq 0 -or $upExit -eq -1978335189) {
                            # 0 = success; -1978335189 = update not applicable (treat as success)
                            $upgradeSucceeded = $true
                            Write-Log "Upgrade step considered successful for '$AppId' (exit $upExit)." "INFO"
                            # Map to success for Intune
                            Set-ExitCode -Code 0 -AppId $AppId -Phase "Upgrade"
                        }
                        else {
                            Write-Log "Upgrade step failed for '$AppId' (exit $upExit). Will fall back to install." "WARN"
                        }
                    }
                }
                catch {
                    Write-Log "Exception during upgrade pre-check/attempt: $($_.Exception.Message)" "WARN"
                }
            }

            if ($didUpgradeAttempt -and $upgradeSucceeded) {
                # Upgrade succeeded (or not applicable); skip install phase
                # Run optional per-app mod script after upgrade, same as after install
                $modsPath = Join-Path $PSScriptRoot "mods"
                $modFile  = Join-Path $modsPath ($AppId + ".ps1")
                if (Test-Path $modFile) {
                    Write-Log "Running mod script '$modFile' after upgrade." "INFO"
                    try { . $modFile } catch {
                        Write-Log "Mod script failed after upgrade: $($_.Exception.Message)" "ERROR"
                    }
                }
                continue
            }
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
            # Upgrade support: if another version is already installed and no pinned version is specified, run winget upgrade.
            $isPinned = $false
            if ($extraArgs -and ($extraArgs -contains "--version")) { $isPinned = $true }
            if (-not $isPinned -and $rawExit -eq -1978334963) {
                Write-Log "Install reported another version already installed; attempting winget upgrade for $AppId." "WARN"
                $upgArgs = @("upgrade","--id",$AppId,"-e","-s","winget","--silent","--disable-interactivity","--accept-source-agreements","--accept-package-agreements")
                $upgOut2 = & $winget @upgArgs 2>&1
                $upgExit2 = $LASTEXITCODE
                Write-Log "winget upgrade exit code: $upgExit2" "INFO"
                Write-Log ("winget upgrade output:`n{0}" -f (($upgOut2 | Out-String).Trim())) "INFO"
                Write-WinGetCodeInfo -Code $upgExit2
                if ($upgExit2 -in @(0, -1978335189)) {
                    Write-Log "Upgrade completed (or not applicable). Treating as success." "INFO"
                    $rawExit = 0
                }
            }
            # Pinned version enforcement: if higher/other version installed, uninstall then install to enforce pinned version.
            if ($isPinned -and $rawExit -in @(-1978334962, -1978334963)) {
                Write-Log "Pinned version requested but different/higher version installed; enforcing by uninstall+install." "WARN"
                $unArgs2 = @("uninstall","--id",$AppId,"-e","-s","winget","--silent","--disable-interactivity","--accept-source-agreements","--accept-package-agreements")
                $unOut2 = & $winget @unArgs2 2>&1
                $unExit2 = $LASTEXITCODE
                Write-Log "winget uninstall exit code: $unExit2" "INFO"
                Write-Log ("winget uninstall output:`n{0}" -f (($unOut2 | Out-String).Trim())) "INFO"
                Write-WinGetCodeInfo -Code $unExit2
                $installOut2 = & $winget @args 2>&1
                $rawExit = $LASTEXITCODE
                Write-Log "Retried winget install exit code: $rawExit" "INFO"
                Write-Log ("Retried winget install output:`n{0}" -f (($installOut2 | Out-String).Trim())) "INFO"
                Write-WinGetCodeInfo -Code $rawExit
            }
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