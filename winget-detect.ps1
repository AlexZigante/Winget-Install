# Winget Detect - Autopilot Bootstrap v3 (Intune custom detection script)
$AppToDetect = "PLACEHOLDER"
$ExpectedVersion = "PLACEHOLDER_VERSION"


# Safety: if the script is still a template (PLACEHOLDER not replaced), fail fast to avoid false folders/detections
if ([string]::IsNullOrWhiteSpace($AppToDetect) -or $AppToDetect -eq "PLACEHOLDER") {
    Write-Host "NotDetected: AppToDetect is not set (template placeholder)."
    exit 1
}
if ($ExpectedVersion -eq "PLACEHOLDER_VERSION") {
    $ExpectedVersion = ""
}

# Detection internal result codes (for logs only)
# 2000 : Unknown detection error
# 2001 : winget.exe not available (even after App Installer registration)
# 2002 : 'winget list' failed
# 2003 : App not present in 'winget list' (not installed)
# 2004 : 'winget upgrade' indicates an update available (not compliant)
# 2005 : Installed & up to date (detected)

$DetectionResultCode = 0
$IsVersionPinned = -not [string]::IsNullOrWhiteSpace($ExpectedVersion)


# Selected WinGet CLI exit codes we care about for detection/logging
$WinGetCodeInfo = @{
    -1978335212 = "APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND: No packages found"
    -1978335210 = "APPINSTALLER_CLI_ERROR_MULTIPLE_APPLICATIONS_FOUND: Multiple packages found matching the criteria"
    -1978335189 = "APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE: No applicable update found"
    -1978334963 = "APPINSTALLER_CLI_ERROR_INSTALL_ALREADY_INSTALLED: Another version of this application is already installed"
    -1978334962 = "APPINSTALLER_CLI_ERROR_INSTALL_DOWNGRADE: A higher version of this application is already installed"
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

# Logs under Intune Management Extension tree, per app
$logDirName = $AppToDetect -replace '[^\w\.-]', '_'
$imeLogRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $imeLogRoot)) {
    New-Item -ItemType Directory -Path $imeLogRoot -Force | Out-Null
}
$logRoot = Join-Path $imeLogRoot $logDirName
if (-not (Test-Path $logRoot)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logRoot ("Detect_{0}.log" -f $timestamp)

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $ts, $Level, $Message
    try {
        Add-Content -Path $logFile -Value $line
    }
    catch {
        # Ignore logging errors to avoid breaking detection
    }
    Write-Host $line
}

function Get-WingetPath {
    <#
        Returns the path to winget.exe.

        Strategy:
        1. Try Get-Command winget.exe.
        2. Search under C:\Program Files\WindowsApps.
        3. Check Autopilot default user location:
           C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe
        4. If still not found, try to register App Installer:
           Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
        5. Re-run 1–3. If still missing, throw.
    #>

    # 1) Try normal PATH
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        return $cmd.Source
    }
    catch {
        Write-Log "winget.exe not found via PATH: $($_.Exception.Message)" "WARN"
    }

    # Helper: search Program Files\WindowsApps
    $progApps = "C:\Program Files\WindowsApps"
    if (Test-Path $progApps) {
        try {
            $candidate = Get-ChildItem -Path $progApps -Recurse -Filter 'winget.exe' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($candidate) {
                Write-Log "winget.exe found in WindowsApps: '$($candidate.FullName)'." "INFO"
                return $candidate.FullName
            }
        }
        catch {
            Write-Log "Error while searching '$progApps' for winget.exe: $($_.Exception.Message)" "WARN"
        }
    }

    # Autopilot defaultuser0 location
    $defaultUserWinget = "C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $defaultUserWinget) {
        Write-Log "winget.exe found at defaultuser0 path: '$defaultUserWinget'." "INFO"
        return $defaultUserWinget
    }

    # Try to register App Installer, which should provision winget
    Write-Log "winget.exe not found, attempting to register App Installer (Microsoft.DesktopAppInstaller_8wekyb3d8bbwe)..." "WARN"

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        Write-Log "App Installer registration completed, re-checking for winget.exe." "INFO"
    }
    catch {
        Write-Log "Failed to register App Installer: $($_.Exception.Message)" "ERROR"
    }

    # Re-try PATH
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        return $cmd.Source
    }
    catch {
        Write-Log "winget.exe still not found via PATH after App Installer registration." "WARN"
    }

    # Re-try WindowsApps
    if (Test-Path $progApps) {
        try {
            $candidate = Get-ChildItem -Path $progApps -Recurse -Filter 'winget.exe' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            if ($candidate) {
                Write-Log "winget.exe found in WindowsApps after App Installer registration: '$($candidate.FullName)'." "INFO"
                return $candidate.FullName
            }
        }
        catch {
            Write-Log "Error while searching '$progApps' for winget.exe after App Installer registration: $($_.Exception.Message)" "WARN"
        }
    }

    # Re-try defaultuser0 path
    if (Test-Path $defaultUserWinget) {
        Write-Log "winget.exe found at defaultuser0 path after App Installer registration: '$defaultUserWinget'." "INFO"
        return $defaultUserWinget
    }

    throw "winget.exe not found even after attempting App Installer registration."
}

Write-Log "Starting detection for '$AppToDetect'."

try {
    # Locate winget
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'." "INFO"
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
        $DetectionResultCode = 2001
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2001 (winget not available)"
        exit 1
    }

    # Check if app is installed, based on 'winget list'
    try {
        Write-Log "Running 'winget list' for '$AppToDetect'." "INFO"
        $listOut = & $winget list --id $AppToDetect -e -s winget --accept-source-agreements 2>&1
        $listExit = $LASTEXITCODE
        Write-Log "'winget list' exit code: $listExit" "INFO"
        Write-Log ("'winget list' output:`n{0}" -f (($listOut | Out-String).Trim())) "INFO"
        Write-WinGetCodeInfo -Code $listExit
    }
    catch {
        Write-Log "Error running 'winget list': $($_.Exception.Message)" "ERROR"
        $DetectionResultCode = 2002
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2002 (winget list failed)"
        exit 1
    }

    # Interpret list exit code
    if ($listExit -eq 0) {
        $installed = $false
        $installedVersion = $null
        if ($listOut) {
            foreach ($line in $listOut) {
                if ($line -match [regex]::Escape($AppToDetect)) {
                    $installed = $true
                    # Try to parse installed version from the row containing the AppId
                    $tokens = $line -split '\s+'
                    $idIndex = [Array]::IndexOf($tokens, $AppToDetect)
                    if ($idIndex -ge 0 -and ($idIndex + 1) -lt $tokens.Length) {
                        $installedVersion = $tokens[$idIndex + 1]
                    }
                    break
                }
            }
        }

        if (-not $installed) {
            Write-Log "'$AppToDetect' not present in 'winget list' → NOT INSTALLED." "INFO"
            $DetectionResultCode = 2003
            $global:LASTEXITCODE = 1
            "NotDetected: Code 2003 (not installed)"
            exit 1
        }
    }
    elseif ($listExit -eq -1978335212) {
        # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
        Write-Log "winget list returned APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND (-1978335212) → NOT INSTALLED." "INFO"
        $DetectionResultCode = 2003
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2003 (not installed)"
        exit 1
    }
    elseif ($listExit -eq -1978335210) {
        # APPINSTALLER_CLI_ERROR_MULTIPLE_APPLICATIONS_FOUND
        Write-Log "winget list returned APPINSTALLER_CLI_ERROR_MULTIPLE_APPLICATIONS_FOUND (-1978335210) → ambiguous AppId." "ERROR"
        $DetectionResultCode = 2006
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2006 (multiple matches)"
        exit 1
    }
    elseif ($listExit -ne 0) {
        # Any other non-zero exit is a generic list failure
        Write-Log "winget list failed with unexpected exit code $listExit." "ERROR"
        $DetectionResultCode = 2002
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2002 (winget list failed)"
        exit 1
    }

    # At this point, app is installed. If a specific version was requested via WingetIntunePackager,
    # enforce that version (upgrade or downgrade). If version is satisfied, do NOT check for upgrades.
    if ($IsVersionPinned) {
        if (-not $installedVersion) {
            Write-Log "App is installed but installed version could not be parsed from 'winget list'." "WARN"
            # Avoid blocking Autopilot on formatting quirks; treat as detected.
            $DetectionResultCode = 2005
            "Detected: Code 2005 (installed)"
            $global:LASTEXITCODE = 0
            exit 0
        }

        Write-Log "Expected version: '$ExpectedVersion', installed version: '$installedVersion'." "INFO"
        if ($installedVersion -eq $ExpectedVersion) {
            Write-Log "Installed version matches expected version → DETECTED (pinned)." "INFO"
            $DetectionResultCode = 2005
            "Detected: Code 2005 (installed, pinned version)"
            $global:LASTEXITCODE = 0
            exit 0
        }

        Write-Log "Version mismatch → attempting remediation to reach expected version '$ExpectedVersion'." "WARN"

        # Attempt 1: direct install of expected version (may upgrade/repair).
        $remediateOut = & $winget install --id $AppToDetect -e -s winget --version $ExpectedVersion --scope machine --silent --disable-interactivity --accept-source-agreements --accept-package-agreements 2>&1
        $remediateExit = $LASTEXITCODE
        Write-Log "Remediation (install --version) exit code: $remediateExit" "INFO"
        Write-Log ("Remediation output:`n{0}" -f (($remediateOut | Out-String).Trim())) "INFO"
        Write-WinGetCodeInfo -Code $remediateExit

        # Re-check version after attempt 1
        $postList = & $winget list --id $AppToDetect -e -s winget --accept-source-agreements 2>&1
        $postExit = $LASTEXITCODE
        $postVersion = $null
        if ($postExit -eq 0 -and $postList) {
            foreach ($line in $postList) {
                if ($line -match [regex]::Escape($AppToDetect)) {
                    $tokens = $line -split '\s+'
                    $idIndex = [Array]::IndexOf($tokens, $AppToDetect)
                    if ($idIndex -ge 0 -and ($idIndex + 1) -lt $tokens.Length) {
                        $postVersion = $tokens[$idIndex + 1]
                    }
                    break
                }
            }
        }

        if ($postVersion -eq $ExpectedVersion) {
            Write-Log "Remediation succeeded: installed version now matches expected version → DETECTED." "INFO"
            $DetectionResultCode = 2005
            "Detected: Code 2005 (remediated to pinned version)"
            $global:LASTEXITCODE = 0
            exit 0
        }

        # Attempt 2: uninstall then install expected version (handles downgrades reliably).
        Write-Log "Attempting uninstall+install to enforce pinned version." "WARN"
        $unOut = & $winget uninstall --id $AppToDetect -e -s winget --silent --disable-interactivity --accept-source-agreements --accept-package-agreements 2>&1
        $unExit = $LASTEXITCODE
        Write-Log "Uninstall exit code: $unExit" "INFO"
        Write-Log ("Uninstall output:`n{0}" -f (($unOut | Out-String).Trim())) "INFO"
        Write-WinGetCodeInfo -Code $unExit

        $inOut = & $winget install --id $AppToDetect -e -s winget --version $ExpectedVersion --scope machine --silent --disable-interactivity --accept-source-agreements --accept-package-agreements 2>&1
        $inExit = $LASTEXITCODE
        Write-Log "Install pinned version exit code: $inExit" "INFO"
        Write-Log ("Install output:`n{0}" -f (($inOut | Out-String).Trim())) "INFO"
        Write-WinGetCodeInfo -Code $inExit

        # Final check
        $finalList = & $winget list --id $AppToDetect -e -s winget --accept-source-agreements 2>&1
        $finalExit = $LASTEXITCODE
        $finalVersion = $null
        if ($finalExit -eq 0 -and $finalList) {
            foreach ($line in $finalList) {
                if ($line -match [regex]::Escape($AppToDetect)) {
                    $tokens = $line -split '\s+'
                    $idIndex = [Array]::IndexOf($tokens, $AppToDetect)
                    if ($idIndex -ge 0 -and ($idIndex + 1) -lt $tokens.Length) {
                        $finalVersion = $tokens[$idIndex + 1]
                    }
                    break
                }
            }
        }

        if ($finalVersion -eq $ExpectedVersion) {
            Write-Log "Pinned version enforced successfully → DETECTED." "INFO"
            $DetectionResultCode = 2005
            "Detected: Code 2005 (pinned version enforced)"
            $global:LASTEXITCODE = 0
            exit 0
        }

        Write-Log "Pinned version enforcement failed. Expected '$ExpectedVersion', got '$finalVersion'." "ERROR"
        $DetectionResultCode = 2007
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2007 (version mismatch)"
        exit 1
    }

    # If we reach here, app is installed; proceed to upgrade check
    # If installed, optionally check if an upgrade is available (informational only)
    try {
        Write-Log "Running 'winget upgrade' for '$AppToDetect' (informational only)." "INFO"
        $upgOut = & $winget upgrade --id $AppToDetect -e -s winget --silent --disable-interactivity --accept-source-agreements --accept-package-agreements 2>&1
        $upgExit = $LASTEXITCODE
        Write-Log "'winget upgrade' exit code: $upgExit" "INFO"
        Write-Log ("'winget upgrade' output:`n{0}" -f (($upgOut | Out-String).Trim())) "INFO"
        Write-WinGetCodeInfo -Code $upgExit
        if ($upgExit -eq 0) {
            $upgradeAvailable = $false
            if ($upgOut) {
                foreach ($line in $upgOut) {
                    if ($line -match [regex]::Escape($AppToDetect)) {
                        $upgradeAvailable = $true
                        break
                    }
                }
            }
            if ($upgradeAvailable) {
                Write-Log "'$AppToDetect' appears to have an upgrade available (informational only, detection remains SUCCESS)." "WARN"
            }
        }
    }
    catch {
        Write-Log "Error running 'winget upgrade' (informational): $($_.Exception.Message)" "WARN"
    }

    # At this point we know the app is installed; detection is SUCCESS regardless of upgrade availability
    Write-Log "'$AppToDetect' installed → DETECTED." "INFO"
    $DetectionResultCode = 2005
    "Detected: Code 2005 (installed)"
    $global:LASTEXITCODE = 0
    exit 0
}
catch {
    if ($DetectionResultCode -eq 0) {
        $DetectionResultCode = 2000
    }
    Write-Log "Detection fatal error (code $DetectionResultCode): $($_.Exception.Message)" "ERROR"
    $global:LASTEXITCODE = 1
    "NotDetected: Code $DetectionResultCode"
    exit 1
}