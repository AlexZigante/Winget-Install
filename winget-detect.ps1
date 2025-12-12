# Winget Detect - Autopilot Bootstrap v3 (Intune custom detection script)
$AppToDetect = "PLACEHOLDER"

# Detection internal result codes (for logs only)
# 2000 : Unknown detection error
# 2001 : winget.exe not available (even after App Installer registration)
# 2002 : 'winget list' failed
# 2003 : App not present in 'winget list' (not installed)
# 2004 : 'winget upgrade' indicates an update available (not compliant)
# 2005 : Installed & up to date (detected)

$DetectionResultCode = 0

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
            $null = & $winget upgrade --accept-source-agreements --accept-package-agreements 2>&1
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
    }
    catch {
        Write-Log "Error running 'winget list': $($_.Exception.Message)" "ERROR"
        $DetectionResultCode = 2002
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2002 (winget list failed)"
        exit 1
    }

    $installed = $false
    if ($listOut) {
        foreach ($line in $listOut) {
            if ($line -match [regex]::Escape($AppToDetect)) {
                $installed = $true
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

    # If installed, check if an upgrade is available
    try {
        Write-Log "Running 'winget upgrade' for '$AppToDetect'." "INFO"
        $upgOut = & $winget upgrade --id $AppToDetect -e -s winget --accept-source-agreements 2>&1
        $upgExit = $LASTEXITCODE
        Write-Log "'winget upgrade' exit code: $upgExit" "INFO"
        Write-Log ("'winget upgrade' output:`n{0}" -f (($upgOut | Out-String).Trim())) "INFO"
    }
    catch {
        # If upgrade check fails, we treat as unknown error
        Write-Log "Error running 'winget upgrade': $($_.Exception.Message)" "ERROR"
        $DetectionResultCode = 2002
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2002 (winget upgrade failed)"
        exit 1
    }

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
        Write-Log "'$AppToDetect' has an upgrade available → NOT COMPLIANT (but installed)." "WARN"
        $DetectionResultCode = 2004
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2004 (upgrade available)"
        exit 1
    }

    # Otherwise, installed and up to date
    Write-Log "'$AppToDetect' installed and up to date → DETECTED." "INFO"
    $DetectionResultCode = 2005
    "Detected: Code 2005 (installed & up to date)"
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
