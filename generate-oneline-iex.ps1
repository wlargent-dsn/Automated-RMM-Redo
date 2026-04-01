$remoteUrl = Read-Host "Enter the remote .ps1 URL"

# 1. Define the actual work (Version-Agnostic Download and Run)
# Using WebClient for PS 2.0 support and forcing TLS 1.2
$innerPayload = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
`$p = "`$env:TEMP\rmm_install.ps1";
(New-Object System.Net.WebClient).DownloadFile('$remoteUrl', `$p);
powershell.exe -ExecutionPolicy Bypass -File `$p *>> 'C:\Windows\Temp\AgentInstaller_Bootstrap.log';
"@

# 2. Encode for PowerShell
$bytes = [System.Text.Encoding]::Unicode.GetBytes($innerPayload)
$encoded = [Convert]::ToBase64String($bytes)

# 3. Build the WMI/CIM Hybrid Launcher
# We wrap the command in a way that handles the 'Marked for Deletion' or 'Access Denied' quirks of older WMI versions
$wrapper = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
$escapedWrapper = $wrapper.Replace("'", "''")

$finalCmd = "powershell -NoProfile -Command ""if(Get-Command Invoke-CimMethod -ErrorAction SilentlyContinue){Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine='$escapedWrapper'}}else{(Get-WmiObject -List Win32_Process).Create('$escapedWrapper')}"""

Write-Host "`n--- UNIVERSAL CMD WRAPPER (WS08R2 to WS25) ---`n" -ForegroundColor Green
Write-Output $finalCmd
