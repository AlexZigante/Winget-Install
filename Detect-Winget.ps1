<#
Detect-Winget.ps1
Purpose:
  - Detect whether WinGet is available and functional for USER context (first user login).
  - Used as the detection script for the Intune Win32 app: "WinGet Dependency for WIP" (Install experience: User).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

function Initialize-LogFile {
    $root = Get-IMELogRoot
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $Global:LogFile = Join-Path $root ("Detect_{0}.log" -f $ts)
}
Initialize-LogFile

Write-Log "========== Detect-Winget starting =========="


function Get-WinGetExePath {
    # User-context focused resolution (App Execution Alias + per-user WindowsApps).
    # Returns full path to winget.exe, or $null.

    # 1) PATH / AppExecutionAlias
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction Stop
        if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    } catch {}

    # 2) Per-user WindowsApps
    $wa = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if (Test-Path $wa) {
        $direct = Join-Path $wa "winget.exe"
        if (Test-Path $direct) { return $direct }

        try {
            $daiDirs = Get-ChildItem -Path $wa -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "Microsoft.Desktop.AppInstaller_*" -or $_.Name -like "Microsoft.DesktopAppInstaller_*" } |
                Sort-Object -Property Name -Descending

            foreach ($d in $daiDirs) {
                $p = Join-Path $d.FullName 'winget.exe'
                if (Test-Path $p) { return $p }
            }
        } catch {}
    }

    # 3) Default profile aliases (rare)
    $alias = @(
        "C:\Users\Default\AppData\Local\Microsoft\WindowsApps\winget.exe",
        "C:\Users\defaultuser0\AppData\Local\Microsoft\WindowsApps\winget.exe"
    )
    foreach ($p in $alias) { if (Test-Path $p) { return $p } }

    return $null
}


function Initialize-WinGetSources {
    param([Parameter(Mandatory)][string]$WingetPath)

    Write-Log "Refreshing WinGet sources (reset + update) using '$WingetPath'." "INFO"
    try {
        & $WingetPath source reset --force --disable-interactivity --accept-source-agreements 2>&1 | Out-Null
    } catch {
        Write-Log "winget source reset failed: $($_.Exception.Message)" "WARN"
    }
    try {
        & $WingetPath source update --disable-interactivity --accept-source-agreements 2>&1 | Out-Null
    } catch {
        Write-Log "winget source update failed: $($_.Exception.Message)" "WARN"
    }
}

try {
    $wg = Get-WinGetExePath
    if (-not $wg) {
        Write-Log "winget.exe not found." "ERROR"
        "NotDetected: WinGet not found"
        exit 1
    }

    Write-Log "Using winget at '$wg'." "INFO"

    try {
        $v = & $wg --version 2>&1
        $verStr = ($v | Out-String).Trim()
        Write-Log "winget --version: $verStr" "INFO"
    } catch {
        Write-Log "winget --version failed: $($_.Exception.Message)" "ERROR"
        "NotDetected: WinGet not functional"
        exit 1
    }

    # Refresh sources before any further winget usage (important in SYSTEM profile)
    Initialize-WinGetSources -WingetPath $wg

    # Sanity check: list sources
    try {
        $src = & $wg source list --disable-interactivity --accept-source-agreements 2>&1
        Write-Log ("winget source list:`n{0}" -f (($src | Out-String).Trim())) "INFO"
    } catch {
        Write-Log "winget source list failed: $($_.Exception.Message)" "WARN"
    }

    Write-Log "WinGet detected and functional." "INFO"
    "Detected: WinGet ready"
    exit 0
}
catch {
    Write-Log "Detect-Winget fatal error: $($_.Exception.Message)" "ERROR"
    "NotDetected: Fatal"
    exit 1
}
