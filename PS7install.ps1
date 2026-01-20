Start-Transcript -Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\PS7-install.log" -Force

# GitHub API endpoint for PowerShell (7) releases
$githubApiUrl = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'

# Fetch the latest release details
$release = Invoke-RestMethod -Uri $githubApiUrl

# Find asset with .msi in the name and x64 in the name
$asset = $release.assets | Where-Object { $_.name -like "*msi*" -and $_.name -like "*x64*" }

# Get the download URL and filename of the asset (assuming it's a MSI file)
$downloadUrl = $asset.browser_download_url
$filename = $asset.name

# Download the latest release using .NET's System.Net.WebClient for faster download
$webClient = New-Object System.Net.WebClient
$webClient.DownloadFile($downloadUrl, $filename)

# Install PowerShell 7
Start-Process msiexec.exe -Wait -ArgumentList "/I $filename /qn"

Stop-Transcript