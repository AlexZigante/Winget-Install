# Winget Detect - WIP v4 (Intune custom detection script)
$AppToDetect = "PLACEHOLDER"

# Detection internal result codes (for logs only)
# 2000 : Unknown detection error
# 2001 : winget.exe not found
# 2002 : 'winget list' failed
# 2003 : App not present in 'winget list' (not installed)
# 2004 : 'winget upgrade' indicates an update available (not compliant)
# 2005 : Installed & up to date (detected)
# 2006 : Marker-based detection error

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
    Add-Content -Path $logFile -Value $line
    Write-Host $line
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


function Get-WIPInstallMarkerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )
    $markerRoot = "C:\ProgramData\Microsoft\IntuneManagementExtension\WinGetInstalled"
    if (-not (Test-Path $markerRoot)) {
        return $null
    }
    $fileName = ($AppId -replace '[^\w\.-]', '_') + ".installed"
    return (Join-Path $markerRoot $fileName)
}
Write-Log "Starting detection for '$AppToDetect'."

try {
    # Locate winget
    $hasWinget = $true
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
    }
    catch {
        Write-Log "winget.exe not found, will attempt marker-based detection." "WARN"
        $hasWinget = $false
        $DetectionResultCode = 2001
        throw
    }

    # Check if app is installed, based on 'winget list'
    try {
        $listOut = & $winget list --id $AppToDetect -e --accept-source-agreements 2>&1
        $listExit = $LASTEXITCODE
        Write-Log "'winget list' exit code: $listExit"
        Write-Log ("'winget list' output:`n{0}" -f (($listOut | Out-String).Trim()))
    }
    catch {
        Write-Log "Error running 'winget list': $($_.Exception.Message)" "ERROR"
        $DetectionResultCode = 2002
        throw
    }

    if (-not $listOut -or ($listOut | Out-String) -notmatch [regex]::Escape($AppToDetect)) {
        Write-Log "'$AppToDetect' not present in 'winget list' → NOT INSTALLED."
        $DetectionResultCode = 2003
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2003"
        exit 1
    }

    # Optional: treat available upgrade as non-compliant
    try {
        $upgOut = & $winget upgrade --id $AppToDetect -e --accept-source-agreements 2>&1
        $upgExit = $LASTEXITCODE
        Write-Log "'winget upgrade' exit code: $upgExit"
        Write-Log ("'winget upgrade' output:`n{0}" -f (($upgOut | Out-String).Trim()))
    }
    catch {
        Write-Log "Error running 'winget upgrade': $($_.Exception.Message)" "WARN"
        $upgOut = $null
    }

    if ($upgOut -and ($upgOut | Out-String) -match [regex]::Escape($AppToDetect)) {
        Write-Log "'$AppToDetect' is installed but an UPGRADE is available → NOT COMPLIANT."
        $DetectionResultCode = 2004
        $global:LASTEXITCODE = 1
        "NotDetected: Code 2004"
        exit 1
    }

    Write-Log "'$AppToDetect' installed and up to date → DETECTED."
    $DetectionResultCode = 2005

    # Intune custom detection script expects exit code 0 AND something on STDOUT for "installed"
    "Detected: Code 2005"
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
