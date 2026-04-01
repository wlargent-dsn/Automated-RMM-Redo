function Get-ConfigScript {
    $scriptDir = Join-Path -Path $PSScriptRoot -ChildPath "Secret Scripts"
    $scripts = Get-ChildItem -Path $scriptDir -Filter "*.ps1" |
        Select-Object -Property Name, FullName
    if ($scripts.Count -eq 0) {
        Write-Host "No scripts found in $scriptDir" -ForegroundColor Red
        exit 1
    }

    Write-Host "Available Site Installer Scripts:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $scripts.Count; $i++) {
        Write-Host "[$($i+1)] $($scripts[$i].Name)" -ForegroundColor Yellow
    }
    $selection = Read-Host "Enter the number of the script to run"
    if (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $scripts.Count) {
        Write-Host "Invalid selection. Exiting." -ForegroundColor Red
        exit 1
    }
    $selectedScript = $scripts[[int]$selection - 1].FullName
    Write-Host "You selected: $($scripts[[int]$selection - 1].
    Name)" -ForegroundColor Green
    return $selectedScript
}

# List scripts in ./Secret Scripts/ and prompt user to select one, then use dot source to get the configuration variables out of it.
# Dot source the selected script to load its variables and functions into the current scope
. $(Get-ConfigScript)

# 1. Define the actual work (Version-Agnostic Download and Run)
# Using WebClient for PS 2.0 support and forcing TLS 1.2
$innerPayload = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
`$p = "`$env:TEMP\rmm_install.ps1";
(New-Object System.Net.WebClient).DownloadFile('$installerLogicScriptURL', `$p);
powershell.exe -ExecutionPolicy Bypass -File `$p -AsioAgentFileName "$AsioAgentFileName" -ScreenConnectURL "$ScreenConnectURL" *> "C:\Windows\Temp\AgentInstaller_Bootstrap.log";
"@

# 2. Encode for PowerShell
$bytes = [System.Text.Encoding]::Unicode.GetBytes($innerPayload)
$encoded = [Convert]::ToBase64String($bytes)

# 3. Build the WMI/CIM Hybrid Launcher
# We wrap the command in a way that handles the 'Marked for Deletion' or 'Access Denied' quirks of older WMI versions
$wrapper = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
$escapedWrapper = $wrapper.Replace("'", "''")

$finalCmd = "powershell -NoProfile -Command ""if(Get-Command Invoke-CimMethod -ErrorAction SilentlyContinue){Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='$escapedWrapper'}}else{(Get-WmiObject -List Win32_Process).Create('$escapedWrapper')};type 'C:\Windows\Temp\AgentInstaller_Bootstrap.log';"""

Write-Host "`n--- UNIVERSAL CMD WRAPPER (WS08R2 to WS25) ---`n" -ForegroundColor Green
Write-Output $finalCmd
