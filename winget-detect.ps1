# Winget Detect - WIP v2 (Intune custom detection script)
$AppToDetect = "PLACEHOLDER"

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

# BurntToast helpers for detection as well (best-effort)
$script:BurntToastAvailable = $false
$script:BurntToastInstalledThisRun = $false

function Initialize-Toast {
    if ($script:BurntToastAvailable) { return }

    try {
        $installed = Get-Module -ListAvailable BurntToast | Select-Object -First 1
        if (-not $installed) {
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
        Write-Log "BurntToast module loaded for detection." "INFO"
    }
    catch {
        Write-Log "BurntToast not available for detection: $($_.Exception.Message)" "WARN"
        $script:BurntToastAvailable = $false
    }
}

function Cleanup-ToastModule {
    try {
        if ($script:BurntToastAvailable) {
            Remove-Module BurntToast -ErrorAction SilentlyContinue
        }
        if ($script:BurntToastInstalledThisRun) {
            Uninstall-Module -Name BurntToast -AllVersions -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Show-DetectToast {
    param(
        [string]$Status,
        [string]$Message
    )

    if (-not $script:BurntToastAvailable) { return }

    try {
        $title = "WinGet Intune - Detect"
        $body  = "$Status - $Message"
        New-BurntToastNotification -Text $title, $body | Out-Null
    }
    catch {
        Write-Log "Failed to show BurntToast detection notification: $($_.Exception.Message)" "WARN"
    }
}

Initialize-Toast
Write-Log "Starting detection for '$AppToDetect'."
Show-DetectToast -Status "Start" -Message "Checking $AppToDetect..."

# Locate winget
try {
    $winget = (Get-Command winget.exe -ErrorAction Stop).Source
    Write-Log "Using winget at '$winget'."
}
catch {
    Write-Log "winget.exe not found: $($_.Exception.Message)" "ERROR"
    Show-DetectToast -Status "Error" -Message "winget.exe not found."
    Cleanup-ToastModule
    exit 1
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
    Show-DetectToast -Status "Error" -Message "Failed to run 'winget list'."
    Cleanup-ToastModule
    exit 1
}

if (-not $listOut -or ($listOut | Out-String) -notmatch [regex]::Escape($AppToDetect)) {
    Write-Log "'$AppToDetect' not present in 'winget list' → NOT INSTALLED (exit 1)."
    Show-DetectToast -Status "Not installed" -Message "$AppToDetect not found."
    Cleanup-ToastModule
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
    Write-Log "'$AppToDetect' is installed but an UPGRADE is available → NOT COMPLIANT (exit 1)."
    Show-DetectToast -Status "Not compliant" -Message "Upgrade available for $AppToDetect."
    Cleanup-ToastModule
    exit 1
}

Write-Log "'$AppToDetect' installed and up to date → DETECTED (exit 0)."
Show-DetectToast -Status "Detected" -Message "$AppToDetect installed and compliant."

# Intune custom detection script expects exit code 0 AND something on STDOUT
"Detected $AppToDetect"
Cleanup-ToastModule
exit 0
