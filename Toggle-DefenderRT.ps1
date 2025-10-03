<#
    Toggle Windows Defender Real-Time Protection (Windows 10/11)
    - Uses Set-MpPreference -DisableRealtimeMonitoring $true/$false
    - Text menu to Disable/Enable/Check status
    - Verifies Administrator privileges
    - Shows current status on launch
    - Adds a "safety net" scheduled task to automatically re-enable protection at next startup
    - Friendly console messages with a dash of personality

    Note:
    - If Tamper Protection or organization policy is enabled, disabling via PowerShell may be blocked.
    - The safety-net task ensures the "temporary" part even if the OS wouldn't restore it quickly on its own.
#>

#region Helper functions

function Test-IsAdmin {
    <#
        Returns $true if the current PowerShell session is elevated.
    #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-DefenderStatus {
    <#
        Retrieves Defender status info (real-time protection and tamper protection if available).
        Returns a PSCustomObject with boolean properties, or $nulls on failure.
    #>
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop

        # Handle property name differences across builds for Tamper Protection
        $tpProp = $s.PSObject.Properties |
            Where-Object { $_.Name -in 'TamperProtectionEnabled','IsTamperProtected' } |
            Select-Object -First 1

        $tamper = $null
        if ($tpProp) {
            $tamper = [bool]$tpProp.Value
        }

        [pscustomobject]@{
            RealTimeProtectionEnabled = [bool]$s.RealTimeProtectionEnabled
            AntiVirusEnabled          = [bool]$s.AntiVirusEnabled
            AntispywareEnabled        = [bool]$s.AntispywareEnabled
            TamperProtectionEnabled   = $tamper
        }
    } catch {
        [pscustomobject]@{
            RealTimeProtectionEnabled = $null
            AntiVirusEnabled          = $null
            AntispywareEnabled        = $null
            TamperProtectionEnabled   = $null
        }
    }
}

function Show-Status {
    <#
        Prints a friendly status line showing the current state of real-time protection
        and (if available) tamper protection.
    #>
    $s = Get-DefenderStatus

    if ($null -eq $s.RealTimeProtectionEnabled) {
        Write-Host "Status: Unable to query Microsoft Defender (is it available on this system?)." -ForegroundColor Yellow
        return
    }

    if ($s.RealTimeProtectionEnabled) {
        Write-Host "Real-time protection: ON  ✅" -ForegroundColor Green
    } else {
        Write-Host "Real-time protection: OFF ⚠️" -ForegroundColor Yellow
    }

    if ($null -ne $s.TamperProtectionEnabled) {
        if ($s.TamperProtectionEnabled) {
            Write-Host "Tamper Protection: Enabled" -ForegroundColor DarkGray
        } else {
            Write-Host "Tamper Protection: Disabled" -ForegroundColor DarkGray
        }
    }
}

function Ensure-ReenableTask {
    <#
        Creates a one-time startup scheduled task that re-enables Defender real-time protection
        and then deletes itself. This ensures the "temporary" nature after a restart.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskName = 'ReEnableDefenderRT'
    )
    try {
        $cmd = @"
`$ErrorActionPreference = 'SilentlyContinue';
Start-Sleep -Seconds 15;
try { Set-MpPreference -DisableRealtimeMonitoring `$false } catch {};
try { Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false } catch {}
"@

        $bytes   = [Text.Encoding]::Unicode.GetBytes($cmd)
        $encoded = [Convert]::ToBase64String($bytes)

        $action     = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
        $trigger    = New-ScheduledTaskTrigger -AtStartup
        $principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
        $settings   = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $TaskName `
                               -Description 'Re-enable Microsoft Defender real-time protection at startup (safety net)' `
                               -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                               -Force | Out-Null
        return $true
    } catch {
        Write-Host "Heads up: Couldn't create the safety-net task. Defender usually turns itself back on after a reboot, but you may need to re-enable manually." -ForegroundColor Yellow
        return $false
    }
}

function Remove-ReenableTask {
    <#
        Removes the re-enable scheduled task if present (e.g., when the user manually turns protection back on).
    #>
    param(
        [string]$TaskName = 'ReEnableDefenderRT'
    )
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop | Out-Null
        }
    } catch {
        # Non-fatal; ignore
    }
}

function Disable-RTP {
    <#
        Disables Defender real-time protection (temporary), then sets up the safety-net scheduled task.
    #>
    try {
        Write-Host "Disabling real-time protection... 🛡️➡️😴" -ForegroundColor Yellow
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        Write-Host "Shields down (temporarily). Be careful out there! Unsigned downloads are not your friends." -ForegroundColor Yellow
        Ensure-ReenableTask | Out-Null
    } catch {
        Write-Host "Hmm... I couldn't turn it off. This can happen if Tamper Protection or policy is blocking changes." -ForegroundColor Red
        Write-Host "Tip: Try Windows Security > Virus & threat protection settings to toggle it, or temporarily disable Tamper Protection there." -ForegroundColor DarkGray
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Enable-RTP {
    <#
        Re-enables Defender real-time protection and removes the safety-net task if present.
    #>
    try {
        Write-Host "Re-enabling real-time protection... 🛡️✨" -ForegroundColor Green
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Remove-ReenableTask | Out-Null
        Write-Host "Shields up! Your PC is guarded again." -ForegroundColor Green
    } catch {
        Write-Host "Couldn't re-enable via PowerShell. Try the Windows Security app if this persists." -ForegroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Show-Menu {
    <#
        Displays the main menu.
    #>
    Write-Host ""
    Write-Host "What would you like to do?"
    Write-Host "  [1] Disable real-time protection (temporary)" -ForegroundColor Yellow
    Write-Host "  [2] Enable real-time protection" -ForegroundColor Green
    Write-Host "  [3] Check status"
    Write-Host "  [0] Exit"
    Write-Host ""
}

#endregion

#region Pre-flight checks

# Make sure Microsoft Defender cmdlets exist
if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Host "Microsoft Defender PowerShell cmdlets not found on this system." -ForegroundColor Red
    Write-Host "This script requires Windows 10/11 with Microsoft Defender." -ForegroundColor Yellow
    exit 1
}

# Check for Admin rights
if (-not (Test-IsAdmin)) {
    Write-Host "This script needs to run as Administrator to change Defender settings." -ForegroundColor Red
    Write-Host "Please relaunch PowerShell as Administrator and run the script again. I’ll wait right here. 😇" -ForegroundColor Yellow
    # Show status anyway (read-only)
    Show-Status
    exit 1
}

#endregion

#region Main

# Header and initial status
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Microsoft Defender Real-Time Protection Toggle " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Show-Status

# Menu loop
while ($true) {
    Show-Menu
    $choice = Read-Host "Select an option"

    switch ($choice) {
        '1' {
            Disable-RTP
            Start-Sleep -Milliseconds 600
            Show-Status
        }
        '2' {
            Enable-RTP
            Start-Sleep -Milliseconds 600
            Show-Status
        }
        '3' {
            Show-Status
        }
        '0' {
            Write-Host "Exiting. Stay safe out there! 👋" -ForegroundColor Cyan
            break
        }
        default {
            Write-Host "That’s not a valid choice. Try again. 🙂" -ForegroundColor Yellow
        }
    }
}

#endregion
