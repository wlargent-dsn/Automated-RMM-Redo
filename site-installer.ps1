param(
    [string]$AsioAgentFileName,
    [string]$ScreenConnectURL
)

$AsioAgentURL = "https://prod.setup.itsupport247.net/windows/BareboneAgent/32/$AsioAgentFileName/MSI/setup"

# --- CORE SETTINGS ---
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

enum AgentWatermarks {
    NoWatermark = 0
    AsioWatermark = 1
    ScriptWatermark = 2
}

function CheckWatermark {
    # HKLM:\SOFTWARE\DealerServicesNetwork\RMMReplacement\AgentWatermark = 0 (No Watermark), 1 (Asio RMM Agent), 2 (Script Ran)
    $WatermarkKey = "HKLM:\SOFTWARE\DealerServicesNetwork\RMMReplacement"
    if (Test-Path $WatermarkKey) {
        $value = Get-ItemProperty -Path $WatermarkKey -Name "AgentWatermark" -ErrorAction SilentlyContinue
        if ($value) {
            return [AgentWatermarks]$value.AgentWatermark
        }
    }

    return [AgentWatermarks]::NoWatermark
}

function SetWatermark {
    $WatermarkKey = "HKLM:\SOFTWARE\DealerServicesNetwork\RMMReplacement"
    if (-not (Test-Path $WatermarkKey)) {
        New-Item -Path $WatermarkKey -Force | Out-Null
    }
    Set-ItemProperty -Path $WatermarkKey -Name "AgentWatermark" -Value ([int][AgentWatermarks]::ScriptWatermark) -Type DWord -ErrorAction SilentlyContinue
}

function KillRMMProcess {
    Write-Log "Stopping and killing RMM processes..."
    $Services = @("ITSPlatform", "LTSVC", "LTSvcMon", "MEPService")
    $Processes = @("ITSPlatform", "ITSrv", "LTSVC", "LTSvcMon", "msiexec")

    foreach ($Svc in $Services) { 
        if (Get-Service $Svc -ErrorAction SilentlyContinue) {
            Write-Log "Stopping Service: $Svc"
            Stop-Service $Svc -Force -ErrorAction SilentlyContinue 
        }
    }
    
    foreach ($Proc in $Processes) { 
        $p = Get-Process $Proc -ErrorAction SilentlyContinue
        if ($p) {
            Write-Log "Killing Process: $Proc"
            $p | Stop-Process -Force -ErrorAction SilentlyContinue 
        }
    }
    Start-Sleep -s 3
}

function Uninstall-RMMAgent {
    Write-Host "Checking for existing RMM Agent..."
    $guid = "{18f39771-f9d8-4cfd-9654-f6c67c8ad9f4}"
    
    # Faster than Win32_Product: Check Registry
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid", 
               "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    
    foreach ($key in $regPath) {
        if (Test-Path $key) {
            Write-Host "Uninstalling RMM via MSIEXEC..."
            Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait
            Write-Host "Uninstall finished with code $($proc.ExitCode)"
            return
        }
    }
    Write-Host "RMM Agent GUID not found."
}

function DeepCleanRMM {
    Write-Log "Starting Deep Clean of RMM remnants..." "WARN"
    $guid = "{18f39771-f9d8-4cfd-9654-f6c67c8ad9f4}"
    
    # Force delete services via SC
    Write-Log "Removing ITSPlatform Service via SC..."
    & cmd /c sc.exe delete "ITSPlatform" | Out-Null
    
    # Wipe Registry keys
    $RegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid",
        "HKLM:\SOFTWARE\ITSPlatform"
    )
    foreach ($Reg in $RegPaths) { 
        if (Test-Path $Reg) { 
            Write-Log "Removing Registry Key: $Reg"
            Remove-Item -Path $Reg -Recurse -Force -ErrorAction SilentlyContinue 
        } 
    }

    # Wipe Folders
    $Dirs = @("$env:ProgramFiles\ITSPlatform", "${env:ProgramFiles(x86)}\ITSPlatform", "$env:ProgramData\ITSPlatform")
    foreach ($Dir in $Dirs) { 
        if (Test-Path $Dir) { 
            Write-Log "Removing Directory: $Dir"
            Remove-Item -Path $Dir -Recurse -Force -ErrorAction SilentlyContinue 
        } 
    }
}

# ScreenConnect Install
Install-Module -Url $ScreenConnectURL -Name "ScreenConnect_Client"

Write-Log "--- Process Complete. Log saved to $LogPath ---"

function Install-Module {
    param ($Url, $Name)
    $FilePath = "$env:TEMP\$Name.msi"
    Write-Log "Downloading $Name from $Url"
    
    try {
        (New-Object System.Net.WebClient).DownloadFile($Url, $FilePath)
    } catch {
        Write-Log "Download Failed: $($_.Exception.Message)" "ERROR"
        return 1
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

function Test-ITSManagerRunning {
    $svc = Get-Service "ITSPlatform" -ErrorAction SilentlyContinue
    if ($svc.Status -ne 'Running') { 
        Write-Log "ITSPlatform service exists but is stopped. Attempting start..." "WARN"
        Start-Service "ITSPlatform" -ErrorAction SilentlyContinue
        Start-Sleep -s 10
    }
    
    $CurrentState = (Get-Service "ITSPlatform" -ErrorAction SilentlyContinue).Status
    Write-Log "ITSPlatform Service Status: $CurrentState"
    
    return ($CurrentState -eq 'Running')
}

function Exit-OnAsioWatermark {
    if ($AgentWatermark -eq [AgentWatermarks]::AsioWatermark) {
        Write-Log "New Asio RMM Agent detected. Exiting." "WARN"
        exit 0
    }
}

function DeepCleanRoutine {
    KillRMMProcess
    DeepCleanRMM
    Install-Module -Url $AsioAgentURL -Name $RMMAgentName
    if ($?) {
        SetWatermark
    }
}

function BasicRoutine {
    KillRMMProcess
    Uninstall-RMMAgent
    Install-Module -Url $AsioAgentURL -Name $RMMAgentName
    if ($?) {
        SetWatermark
    }
}

# --- MAIN EXECUTION LOGIC ---
Write-Log "--- Script Started: $(Get-Date) ---"
Write-Log "Running on: $env:COMPUTERNAME (User: $env:USERNAME)"

# Blanket ScreenConnect Install
Install-Module -Url $ScreenConnectURL -Name "ScreenConnect_Client"

Exit-OnAsioWatermark # If new Asio agent is detected, exit immediately to avoid unnecessary uninstall/install attempts
BasicRoutine # Run basic uninstall/install routine first

# Verification & Retry Logic
if (-not (Test-ITSManagerRunning)) {
    Write-Log "Initial validation failed. Initiating retry with Deep Clean..." "ERROR"
    
    Exit-OnAsioWatermark # Check again before deep clean to avoid unnecessary aggressive cleanup if new agent was installed during basic routine
    DeepCleanRoutine # Run deep clean routine if basic routine fails
    
    if (Test-ITSManagerRunning) {
        Write-Log "Recovery Successful: RMM Agent is running." "SUCCESS"
    } else {
        Write-Log "CRITICAL FAILURE: RMM Agent failed to start after deep clean." "ERROR"
    }
} else {
    Write-Log "RMM Agent passed validation." "SUCCESS"
}

Write-Log "--- Process Complete. Log saved to $LogPath ---"
