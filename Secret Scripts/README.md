# Scripts Containing Secrets

This directory has scripts that are specific to sites and contain the tokens to install the RMM.

Scripts look like this:

```powershell
# CHANGE-ME:
# MSI Installer for the RMM
$AsioAgentFileName = "<Secret RMM file name and token>"
# MSI Installer for ScreenConnect Client
$ScreenConnectURL = "<Secret ScreenConnect URL>"
# END-CHANGEME

$AsioAgentURL = "https://prod.setup.itsupport247.net/windows/BareboneAgent/32/$AsioAgentFileName/MSI/setup"

# --- LOGGING SETUP ---
$LogPath = "C:\Windows\Temp\RMM_Redo.log"

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$Timestamp] [$Level] $Message"

    # Console Output with Colors
    switch ($Level) {
        "ERROR" { Write-Host $LogLine -ForegroundColor Red }
        "WARN"  { Write-Host $LogLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogLine -ForegroundColor Green }
        Default { Write-Host $LogLine -ForegroundColor Cyan }
    }

    # File Output (Append)
    try {
        $LogLine | Out-File -FilePath $LogPath -Append -Encoding ASCII -ErrorAction SilentlyContinue
    } catch {
        # Failsafe if log file is locked
    }
}

# --- CORE SETTINGS ---
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- MAIN LOGIC ---
try {
    Invoke-Expression (New-Object Net.Webclient).DownloadString("https://placeholder.example.com/site-installer.ps1")
} catch {
    Write-Log "Failed to download or execute main logic script: $($_.Exception.Message)" "ERROR"
    exit 1
}
```
