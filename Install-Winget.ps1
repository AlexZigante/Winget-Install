<#
Install-Winget.ps1
Purpose:
  - Install/repair WinGet (Microsoft.DesktopAppInstaller) in SYSTEM context, then initialize sources.
  - Used as the install command for the Intune Win32 app: "WinGet Dependency for WIP".

Behavior:
  1) Try default registration by family name (fast)
  2) Try Microsoft.WinGet.Client + Repair-WinGetPackageManager (Sandbox-style bootstrap)
  3) Fallback to SYSTEM bootstrap: download App Installer + dependencies and install with Add-AppxPackage
  After each method (when winget becomes available), run:
    winget source reset --force
    winget source update
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Logging ---
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message
    Write-Host $line
    try { Add-Content -Path $Global:LogFile -Value $line } catch {}
}

function Initialize-LogFile {
    $root = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\WinGetDependencyForWIP"
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $Global:LogFile = Join-Path $root ("Install_{0}.log" -f $ts)
}
Initialize-LogFile
Write-Log "========== Install-Winget starting =========="

# --- Helpers ---
function Set-Tls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12
    } catch {}
}

function Get-WinGetExePath {
    # Fast path: Desktop App Installer folders in WindowsApps
    $progApps = "C:\Program Files\WindowsApps"
    if (Test-Path $progApps) {
        try {
            $daiDirs = Get-ChildItem -Path $progApps -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe" } |
                Sort-Object -Property Name -Descending
            foreach ($d in $daiDirs) {
                $p = Join-Path $d.FullName 'winget.exe'
                if (Test-Path $p) { return $p }
            }
        } catch {}
    }

    # PATH / alias
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch {}

    $alias = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"),
        "C:\Users\Default\AppData\Local\Microsoft\WindowsApps\winget.exe",
        "C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe"
    )
    foreach ($p in $alias) { if (Test-Path $p) { return $p } }

    return $null
}

function Initialize-WinGetSources {
    param([Parameter(Mandatory)][string]$WingetPath)

    Write-Log "Initializing WinGet sources (reset + update) using '$WingetPath'." "INFO"
    try {
        & $WingetPath source reset --force --disable-interactivity --accept-source-agreements 2>&1 | Out-String | ForEach-Object { if ($_ -and $_.Trim()) { Write-Log $_.Trim() "INFO" } }
    } catch {
        Write-Log "winget source reset failed: $($_.Exception.Message)" "WARN"
    }

    try {
        & $WingetPath source update --disable-interactivity --accept-source-agreements 2>&1 | Out-String | ForEach-Object { if ($_ -and $_.Trim()) { Write-Log $_.Trim() "INFO" } }
    } catch {
        Write-Log "winget source update failed: $($_.Exception.Message)" "WARN"
    }
}

function Test-WinGetReady {
    param([Parameter(Mandatory)][string]$WingetPath)

    try {
        $v = & $WingetPath --version 2>&1
        Write-Log "winget --version: $($v | Out-String | ForEach-Object { $_.Trim() } | Where-Object { $_ })" "INFO"
        return $true
    } catch {
        Write-Log "winget version check failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# --- Method 1: Default registration (fast) ---
function Try-DefaultRegister {
    Write-Log "Method 1/3: Default Add-AppxPackage -RegisterByFamilyName (Microsoft.DesktopAppInstaller_8wekyb3d8bbwe)." "INFO"
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop | Out-Null
        Write-Log "Default registration command executed." "INFO"
        return $true
    } catch {
        Write-Log "Default registration failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# --- Method 2: Microsoft.WinGet.Client + Repair-WinGetPackageManager ---
function Try-RepairCmdlet {
    Write-Log "Method 2/3: Microsoft.WinGet.Client + Repair-WinGetPackageManager -AllUsers." "INFO"
    try {
        Set-Tls
        try {
            Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "Install-PackageProvider NuGet failed (continuing): $($_.Exception.Message)" "WARN"
        }

        try {
            # Force AllUsers to avoid user-profile scope in SYSTEM context
            Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -ErrorAction Stop | Out-Null
        } catch {
            # If PSGallery is blocked, this will fail; log and continue to method 3
            Write-Log "Install-Module Microsoft.WinGet.Client failed: $($_.Exception.Message)" "WARN"
            return $false
        }

        try {
            Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "Import-Module Microsoft.WinGet.Client failed: $($_.Exception.Message)" "WARN"
            return $false
        }

        try {
            Repair-WinGetPackageManager -AllUsers -ErrorAction Stop | Out-Null
            Write-Log "Repair-WinGetPackageManager completed." "INFO"
            return $true
        } catch {
            Write-Log "Repair-WinGetPackageManager failed: $($_.Exception.Message)" "WARN"
            return $false
        }
    } catch {
        Write-Log "Method 2 failed unexpectedly: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# --- Method 3: SYSTEM bootstrap (download + Add-AppxPackage) ---
$Uri_AppInstaller = 'https://aka.ms/getwinget'
$Uri_VCLibs       = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
$Uri_UIXaml       = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'

$Name_AppInstaller = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
$Name_VCLibs       = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
$Name_UIXaml       = 'Microsoft.UI.Xaml.2.8.x64.appx'

$CacheDir = Join-Path $env:ProgramData "WinGetDependencyForWIP\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Set-Tls
    Write-Log "Downloading: $Uri -> $OutFile" "INFO"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    } catch {
        # Some environments block IWR; try BITS
        Write-Log "Invoke-WebRequest failed, trying BITS: $($_.Exception.Message)" "WARN"
        Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
    }
}

function Resolve-Or-DownloadPayload {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Uri
    )
    $candidate = Join-Path $CacheDir $FileName
    if (Test-Path $candidate) {
        Write-Log "Found cached payload: $candidate" "INFO"
        return $candidate
    }
    Invoke-DownloadFile -Uri $Uri -OutFile $candidate
    if (-not (Test-Path $candidate)) { throw "Download failed: $Uri" }
    return $candidate
}

function Install-AppxFromPath {
    param([Parameter(Mandatory)][string]$Path)
    Write-Log "Installing AppX/MSIX: $Path" "INFO"
    Add-AppxPackage -Path $Path -ForceApplicationShutdown -ErrorAction Stop | Out-Null
}

function Try-SystemBootstrap {
    Write-Log "Method 3/3: SYSTEM bootstrap (download App Installer + deps, Add-AppxPackage)." "INFO"
    try {
        $pathAppInstaller = Resolve-Or-DownloadPayload -FileName $Name_AppInstaller -Uri $Uri_AppInstaller
        $pathVCLibs       = Resolve-Or-DownloadPayload -FileName $Name_VCLibs       -Uri $Uri_VCLibs
        $pathUIXaml       = Resolve-Or-DownloadPayload -FileName $Name_UIXaml       -Uri $Uri_UIXaml

        # Install dependencies first
        try { Install-AppxFromPath -Path $pathVCLibs } catch { Write-Log "VCLibs install failed: $($_.Exception.Message)" "WARN" }
        try { Install-AppxFromPath -Path $pathUIXaml } catch { Write-Log "UI.Xaml install failed: $($_.Exception.Message)" "WARN" }

        # Install App Installer bundle (winget)
        Install-AppxFromPath -Path $pathAppInstaller

        Write-Log "SYSTEM bootstrap installation attempted." "INFO"
        return $true
    } catch {
        Write-Log "SYSTEM bootstrap failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

# --- Main flow ---
$success = $false

try {
    # If already installed, just initialize sources
    $wg = Get-WinGetExePath
    if ($wg -and (Test-WinGetReady -WingetPath $wg)) {
        Write-Log "WinGet already available: $wg" "INFO"
        Initialize-WinGetSources -WingetPath $wg
        exit 0
    }

    if (Try-DefaultRegister) {
        $wg = Get-WinGetExePath
        if ($wg -and (Test-WinGetReady -WingetPath $wg)) {
            Initialize-WinGetSources -WingetPath $wg
            $success = $true
        }
    }

    if (-not $success) {
        if (Try-RepairCmdlet) {
            $wg = Get-WinGetExePath
            if ($wg -and (Test-WinGetReady -WingetPath $wg)) {
                Initialize-WinGetSources -WingetPath $wg
                $success = $true
            }
        }
    }

    if (-not $success) {
        if (Try-SystemBootstrap) {
            $wg = Get-WinGetExePath
            if ($wg -and (Test-WinGetReady -WingetPath $wg)) {
                Initialize-WinGetSources -WingetPath $wg
                $success = $true
            }
        }
    }

    if (-not $success) {
        throw "All WinGet install methods failed."
    }

    Write-Log "WinGet installation succeeded." "INFO"
    exit 0
}
catch {
    Write-Log "Install-Winget fatal error: $($_.Exception.Message)" "ERROR"
    exit 1
}
