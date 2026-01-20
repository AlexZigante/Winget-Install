Start-Transcript -Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\PS7-detect.log" -Force


try {
    $candidate = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (Test-Path $candidate) {
    exit 0
    }
    Write-Warning "Powershell 7 Missing"
    exit 1
}
catch{
    Write-Error "Detection Failed"
    exit 1
}

Stop-Transcript