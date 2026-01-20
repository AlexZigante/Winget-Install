Start-Transcript -Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\InitializeWinget-detect.log" -Force

Import-Module Microsoft.WinGet.Client
$mods = Get-Module -ListAvailable -Name Microsoft.WinGet.Client | Sort-Object Version -Descending
if (-not $mods) {
  Write-Host "MODULE_NOT_FOUND"
  exit 2
}

Stop-Transcript
exit 0