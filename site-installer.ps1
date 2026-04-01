param(
    [string]$AsioAgentFileName,
    [string]$ScreenConnectURL
)

$AsioAgentURL = "https://prod.setup.itsupport247.net/windows/BareboneAgent/32/$AsioAgentFileName/MSI/setup"

# --- LOGGING SETUP ---
$LogPath = "C:\Windows\Temp\RMM_Redo.log"
Write-Host "Log file: $LogPath" -ForegroundColor Cyan
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

Add-Type -TypeDefinition @"
    public enum AgentWatermarks {
        NoWatermark = 0,
        AsioWatermark = 1,
        ScriptWatermark = 2
    }
"@

function Get-Watermark {
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

function Set-Watermark {
    param (
        [AgentWatermarks]$WatermarkValue = [AgentWatermarks]::ScriptWatermark
    )

    $WatermarkKey = "HKLM:\SOFTWARE\DealerServicesNetwork\RMMReplacement"
    if (-not (Test-Path $WatermarkKey)) {
        New-Item -Path $WatermarkKey -Force | Out-Null
    }
    Set-ItemProperty -Path $WatermarkKey -Name "AgentWatermark" -Value ([int]$WatermarkValue) -Type DWord -ErrorAction SilentlyContinue
}

function Unlock-ITSFolderForcefully {
    param (
        [string]$TargetFolder = "ITSPlatform"
    )
    Write-Log "Scanning for processes locking '$TargetFolder'..." "WARN"

    # 1. Define critical system processes we must NOT kill (Safety Guardrail)
    $SafeList = @("lsass", "csrss", "wininit", "services", "smss", "System", "Idle")

    # 2. Get all processes and inspect their loaded modules
    $AllProcs = Get-Process -ErrorAction SilentlyContinue
    
    foreach ($p in $AllProcs) {
        # Skip safe processes
        if ($SafeList -contains $p.ProcessName) { continue }

        $IsLocked = $false
        $LockType = ""

        try {
            # Check 1: Is the executable itself inside the folder?
            if ($p.Path -match $TargetFolder) {
                $IsLocked = $true
                $LockType = "Executable execution"
            }
            
            # Check 2: Has the process loaded a DLL from the folder?
            # (Only check if not already found to save time)
            if (-not $IsLocked -and $p.Modules) {
                if ($p.Modules.FileName -match $TargetFolder) {
                    $IsLocked = $true
                    $LockType = "DLL Injection"
                }
            }
        } catch {
            # Access Denied usually means system process, ignore
        }

        # 3. Kill the offender
        if ($IsLocked) {
            Write-Log "KILLING LOCK: [$($p.ProcessName)] ID:$($p.Id) Reason: $LockType" "WARN"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-ITSProcesses {
    Write-Log "Stopping and killing RMM processes..."
    $Services = @("ITSPlatform", "LTSVC", "LTSvcMon", "MEPService")
    $Processes = @("ITSPlatform", "ITSrv", "LTSVC", "LTSvcMon")

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

function Uninstall-Agent {
    Write-Host "Checking for existing RMM Agent..."
    $guid = "{18f39771-f9d8-4cfd-9654-f6c67c8ad9f4}"
    
    # Faster than Win32_Product: Check Registry
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid", 
               "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    
    foreach ($key in $regPath) {
        if (Test-Path $key) {
            Write-Host "Uninstalling RMM via MSIEXEC..."
            $proc = Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -PassThru
            
            if ($proc.ExitCode -eq 0) {
                Write-Host "Uninstall finished successfully."
                Set-Watermark ([AgentWatermarks]::NoWatermark) # Clear watermark on successful uninstall to allow re-detection of new agent
            } else {
                Write-Host "Uninstall finished with code $($proc.ExitCode)"
            }
            
            return
        }
    }
    Write-Host "RMM Agent GUID not found."

}

function Remove-RMMDeepClean {
    Write-Log "Starting Deep Clean of RMM remnants..." "WARN"
    $guid = "{18f39771-f9d8-4cfd-9654-f6c67c8ad9f4}"
    
    # Force delete services via SC
    Write-Log "Removing ITSPlatform Service via SC..."
    cmd /c sc.exe delete "ITSPlatform"
    
    # Wipe Registry keys
    $RegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$guid",
        "HKLM:\SOFTWARE\ITSPlatform",
        "HKLM:\SOFTWARE\WOW6432Node\ITSPlatform"
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

function Install-ApplicationMSI {
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
    # Check if service exists
    if ($null -eq $svc) {
        Write-Log "ITSPlatform service not found." "ERROR"
        return $false
    }

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
    $Watermark = Get-Watermark # Check if new agent was installed during routine execution
    if ($Watermark -eq [AgentWatermarks]::AsioWatermark) {
        Write-Log "New Asio agent detected. Exiting." "WARN"
        ExitCleanup
        exit 0
    } else {
        Write-Log "Current watermark: $([AgentWatermarks]$Watermark.ToString()) - Continuing with script execution." "INFO"
    }
}

function Redo-AgentExtreme {
    Write-Log " --- Initiating Deep Clean Routine --- " "WARN"
    Exit-OnAsioWatermark # Check again before deep clean to avoid unnecessary aggressive cleanup if new agent was installed during basic routine

    Stop-ITSProcesses
    Unlock-ITSFolderForcefully
    Remove-RMMDeepClean
    Start-Sleep -s 5
    $result = Install-ApplicationMSI -Url $AsioAgentURL -Name $AsioAgentFileName
    if ($result -eq 0) { Set-Watermark }
}

function Redo-AgentBasic {
    Write-Log " --- Initiating Basic Routine --- " "WARN"
    Exit-OnAsioWatermark # If new agent is detected, exit immediately to avoid unnecessary uninstall/install attempts

    Stop-ITSProcesses
    Uninstall-Agent
    Start-Sleep -s 5
    $result = Install-ApplicationMSI -Url $AsioAgentURL -Name $AsioAgentFileName
    if ($result -eq 0) { Set-Watermark }
}

function Test-AgentService {
    if (Test-ITSManagerRunning) {
        Write-Log "RMM Agent is running." "SUCCESS"
        return $true
    }
    Write-Log "RMM Agent failed to start." "ERROR"
    return $false
}

function Start-AgentService {
    Write-Log "Attempting to start ITSPlatform service..."
    Start-Service "ITSPlatform" -ErrorAction SilentlyContinue
    Start-Sleep -s 10
}

function Assert-RunningAgentService {
    if (Test-AgentService) {
        return $true
    }

    Write-Log "RMM Agent service is not running. Attempting to start..." "WARN"

    Start-AgentService
    return Test-AgentService
}

function ExitCleanup {
    Write-Log "--- Process Complete. Log saved to $LogPath ---"
}

function Clear-Log {
    try {
        Clear-Content -Path $LogPath -ErrorAction SilentlyContinue
    } catch {
        # If log file is locked or doesn't exist, ignore
    }   
}

# --- MAIN EXECUTION LOGIC ---
Clear-Log
Write-Log "--- Script Started: $(Get-Date) ---"
Write-Log "Running on: $env:COMPUTERNAME"

# Blanket ScreenConnect Install
Install-ApplicationMSI -Url $ScreenConnectURL -Name "ScreenConnect_Client"

Redo-AgentBasic # Run basic uninstall/install routine first

# Verification & Retry Logic
# Wait for agent check in

if (Assert-RunningAgentService) {
    Write-Log "RMM Service is running after basic routine." "SUCCESS"
    if (Get-Watermark -eq [AgentWatermarks]::ScriptWatermark) {
        Write-Log "New Agent detected after basic routine. Exiting." "WARN"
        ExitCleanup
        exit 0
    }
} else {
    Write-Log "Agent was unable to start." "WARN"
}

Write-Log "Initiating retry with Deep Clean..." "WARN"

Redo-AgentExtreme # Run deep clean routine if basic routine fails

if (Assert-RunningAgentService) {
    Write-Log "RMM Service is running after deep clean routine." "SUCCESS"
    Exit-OnAsioWatermark
}

$Watermark = Get-Watermark # Check watermark
Write-Log "RMM Agent is not running with watermark: $([AgentWatermarks]$Watermark.ToString())" "WARN"

ExitCleanup
