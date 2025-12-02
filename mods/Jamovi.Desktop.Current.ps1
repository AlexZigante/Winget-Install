# Jamovi QuietUninstallString Fix Mod (Install hook)
$AppId = "Jamovi.Desktop.Current"

$winget = (Get-Command winget.exe).Source
$list = & $winget list --id $AppId --exact
try {
    $parts = ($list | Select-String -SimpleMatch $AppId).ToString().Split()
    $ver = $parts[-2]
} catch {
    Write-Host "Jamovi version parse failed"
    return
}

$regPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\jamovi $ver"
$expected = "C:\Program Files\jamovi $ver\uninstall.exe /S"

if(Test-Path $regPath){
    New-ItemProperty -Path $regPath -Name "QuietUninstallString" -Value $expected -PropertyType String -Force | Out-Null
    Write-Host "Jamovi QuietUninstallString set to: $expected"
} else {
    Write-Host "Jamovi uninstall key not found for version $ver"
}
