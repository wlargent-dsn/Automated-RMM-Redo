# CHANGEME: Update the URL to match your ScreenConnect instance
# MSI Installer for ScreenConnect Client
$ScreenConnectURL = "https://rmmus-dealerservicesnetwork.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest&c=DSN&c=DSN%20-%20QTS%20Miami&c=&c=&c=&c=&c=&c="
# END-CHANGEME

function Install-Module {
    param ($Url, $Name)
    $FilePath = "$env:TEMP\$Name.msi"
    Write-Log "Downloading $Name from $Url"
    
    try {
        (New-Object System.Net.WebClient).DownloadFile($Url, $FilePath)
    } catch {
        Write-Log "Download Failed: $($_.Exception.Message)" "ERROR"
        return 1603
    }
    
    Write-Log "Executing MSI Installer for $Name..."
    # /l*v enables verbose MSI logging for this specific install attempt as well
    $MSILog = "$env:TEMP\MSI_$Name.log"
    $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$FilePath`" /qn /norestart /l*v `"$MSILog`"" -Wait -PassThru
    
    if ($proc.ExitCode -eq 0) {
        Write-Log "$Name installed successfully." "SUCCESS"
    } else {
        Write-Log "$Name installer failed with code $($proc.ExitCode). Check $MSILog details." "ERROR"
    }
    return $proc.ExitCode
}

function Repair-ScreenConnectClient {
    $thumbprint = "74f1ccfefc41c845"
    $serviceName = "ScreenConnect Client ($thumbprint)"
    
    Write-Host "Cleaning up ScreenConnect..."
    
    # Kill Processes & Stop Service
    Get-Process | Where-Object { $_.ProcessName -like "*ScreenConnect*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Get-Service $serviceName -ErrorAction SilentlyContinue) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -s 2 # Allow time for handles to release
        & sc.exe delete $serviceName
    }

    $paths = @(
        "$env:ProgramFiles\ScreenConnect Client ($thumbprint)",
        "${env:ProgramFiles(x86)}\ScreenConnect Client ($thumbprint)",
        "$env:ProgramData\ScreenConnect Client ($thumbprint)"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) { Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Install ScreenConnect Client
    Install-Module -Url $ScreenConnectURL -Name "ScreenConnect_Client"

    if (Get-Service "ScreenConnect Client ($thumbprint)" -ErrorAction SilentlyContinue) {
        Restart-Service -Name "ScreenConnect Client ($thumbprint)" -Force -ErrorAction SilentlyContinue
    }

}

Repair-ScreenConnectClient
