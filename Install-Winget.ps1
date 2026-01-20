Start-Transcript -Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\InitializeWinget-install.log" -Force

Install-Script -Name Initialize-Module -Force -Repository PSGallery
Initialize-Module -Name Microsoft.WinGet.Client
Install-Script -Name Initialize-Winget -Force -Repository PSGallery
Initialize-Winget

Stop-Transcript