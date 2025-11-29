#Change app to detect [Application ID]
$AppToDetect = "Notepad++.Notepad++"

<#
  Alex edition - Improved WinGet detection for Intune

  Exit codes:
    0 = App detected AND no upgrade available
    1 = App not detected OR upgrade available OR detection error

  Logging:
    - Writes to C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\MyWinGet\Detect_<AppId>.log
    - Also writes to console so messages appear in AppWorkload.log
#>

function Get-WingetCmd {

    $WingetCmd = $null

    try {
        # Admin context
        $WingetInfo = Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe\winget.exe" -ErrorAction Stop |
            Select-Object -ExpandProperty VersionInfo |
            Sort-Object -Property FileVersionRaw
        if ($WingetInfo) {
            $WingetCmd = $WingetInfo[-1].FileName
        }
    }
    catch {
        # User context
        if (Test-Path "$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe") {
            $WingetCmd = "$env:LocalAppData\Microsoft\WindowsApps\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\winget.exe"
        }
    }

    return $WingetCmd
}

function Get-MyWinGetDetectLogFile {
    param(
        [Parameter(Mandatory)]
        [string] $AppId
    )

    $root = Join-Path -Path $env:ProgramData -ChildPath "Microsoft\IntuneManagementExtension\Logs\MyWinGet"
    if (-not (Test-Path $root)) {
        New-Item -Path $root -ItemType Directory -Force | Out-Null
    }

    $safeId = ($AppId -replace '[^\w\.-]', '_')
    return Join-Path -Path $root -ChildPath ("Detect_{0}.log" -f $safeId)
}

function Write-DetectLog {
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "{0} [DETECT] [{1}] {2}" -f $timestamp, $global:DetectAppId, $Message

    # Console (for AppWorkload.log)
    Write-Host $line

    # File
    if ($global:DetectLogFile) {
        Add-Content -Path $global:DetectLogFile -Value $line
    }
}

$global:DetectAppId = $AppToDetect
$global:DetectLogFile = Get-MyWinGetDetectLogFile -AppId $AppToDetect

try {
    $winget = Get-WingetCmd
    if (-not $winget) {
        Write-DetectLog "winget.exe not found. Cannot detect $AppToDetect."
        exit 1
    }

    Write-DetectLog "Using winget at: $winget"
    Write-DetectLog "Running detection for: $AppToDetect"

    # 1) Is app installed?
    Write-DetectLog "Executing: winget list --id $AppToDetect --exact"
    $listOutput = & $winget list --id $AppToDetect --exact 2>&1
    $listOutput | ForEach-Object { Write-DetectLog $_ }

    if ($LASTEXITCODE -ne 0 -or -not $listOutput) {
        Write-DetectLog "winget list failed or returned no output. ExitCode=$LASTEXITCODE"
        exit 1
    }

    $installedLine = $listOutput | Select-String -SimpleMatch $AppToDetect | Select-Object -First 1
    if (-not $installedLine) {
        Write-DetectLog "$AppToDetect not found in winget list output."
        exit 1
    }

    Write-DetectLog "$AppToDetect appears installed. Checking for upgrades..."

    # 2) Is an upgrade available?
    Write-DetectLog "Executing: winget upgrade --id $AppToDetect --exact"
    $upgradeOutput = & $winget upgrade --id $AppToDetect --exact 2>&1
    $upgradeOutput | ForEach-Object { Write-DetectLog $_ }

    if ($LASTEXITCODE -eq 0 -and ($upgradeOutput | Select-String -SimpleMatch $AppToDetect)) {
        Write-DetectLog "$AppToDetect is installed, but an upgrade is available."
        exit 1
    }

    Write-DetectLog "$AppToDetect is installed and up to date."
    exit 0
}
catch {
    Write-DetectLog ("Detection error: {0}" -f $_.Exception.Message)
    if ($_.InvocationInfo) {
        Write-DetectLog $_.InvocationInfo.PositionMessage
    }
    exit 1
}
