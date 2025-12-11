[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppToDetect
)

$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0
$DetectionResultCode = 0

function Get-LogDirectory {
    $base = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
    $dir  = Join-Path $base "Winget-Detect"
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    return $dir
}

function Get-LogFilePath {
    param(
        [string]$Prefix = "Detect"
    )
    $dir = Get-LogDirectory
    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"
    return Join-Path $dir ("{0}_{1}.log" -f $Prefix, $ts)
}

$Global:LogFile = Get-LogFilePath -Prefix "Detect"

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

try {
    Start-Transcript -Path $Global:LogFile -Append -ErrorAction SilentlyContinue | Out-Null
}
catch {
    Write-Log "Failed to start transcript: $($_.Exception.Message)" "WARN"
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
        Write-Log "Failed to register App Installer for detection: $($_.Exception.Message)" "ERROR"
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

Write-Log "========== Winget-Detect starting for '$AppToDetect' =========="

try {
    try {
        $winget = Get-WingetPath
        Write-Log "Using winget at '$winget'."
    }
    catch {
        Write-Log "winget.exe not available even after App Installer registration: $($_.Exception.Message)" "ERROR"
        $DetectionResultCode = 2001
        "NotDetected: Code 2001 (winget not available)"
        $global:LASTEXITCODE = 1
        exit 1
    }

    Write-Log "Running 'winget list' for '$AppToDetect'."
    $listArgs = @(
        "list",
        "--id", $AppToDetect,
        "-e"
    )

    $listOut = & $winget @listArgs 2>&1
    $listExit = $LASTEXITCODE

    Write-Log ($listOut | Out-String).Trim()
    Write-Log "winget list exit code: $listExit"

    if ($listExit -ne 0) {
        Write-Log "winget list failed for '$AppToDetect'." "ERROR"
        $DetectionResultCode = 2002
        "NotDetected: Code 2002 (winget list failed)"
        $global:LASTEXITCODE = 1
        exit 1
    }

    $installed = $false
    foreach ($line in $listOut) {
        if ($line -match [Regex]::Escape($AppToDetect)) {
            $installed = $true
            break
        }
    }

    if (-not $installed) {
        Write-Log "'$AppToDetect' not present in winget list → NOT INSTALLED." "INFO"
        $DetectionResultCode = 2003
        "NotDetected: Code 2003 (not installed)"
        $global:LASTEXITCODE = 1
        exit 1
    }

    Write-Log "Running 'winget upgrade' for '$AppToDetect'."
    $upArgs = @(
        "upgrade",
        "--id", $AppToDetect,
        "-e"
    )

    $upOut = & $winget @upArgs 2>&1
    $upExit = $LASTEXITCODE

    Write-Log ($upOut | Out-String).Trim()
    Write-Log "winget upgrade exit code: $upExit"

    $upgradeAvailable = $false
    if ($upExit == 0) {
        foreach ($line in $upOut) {
            if ($line -match [Regex]::Escape($AppToDetect)) {
                $upgradeAvailable = $true
                break
            }
        }
    }

    if ($upgradeAvailable) {
        Write-Log "'$AppToDetect' has an upgrade available → NOT COMPLIANT (but installed)." "WARN"
        $DetectionResultCode = 2004
        "NotDetected: Code 2004 (upgrade available)"
        $global:LASTEXITCODE = 1
        exit 1
    }

    Write-Log "'$AppToDetect' installed and up to date → DETECTED." "INFO"
    $DetectionResultCode = 2005
    "Detected: Code 2005 (installed & up to date)"
    $global:LASTEXITCODE = 0
    exit 0
}
catch {
    if ($DetectionResultCode -eq 0) {
        $DetectionResultCode = 2000
        Write-Log "Unexpected detection error: $($_.Exception.Message)" "ERROR"
    }
    $global:LASTEXITCODE = 1
    exit 1
}
finally {
    Write-Log "Winget-Detect finished with DetectionResultCode $DetectionResultCode, exit code $global:LASTEXITCODE."
    try { Stop-Transcript | Out-Null } catch {}
}
