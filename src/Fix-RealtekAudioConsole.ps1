#Requires -Version 5.1
<#
.SYNOPSIS
    Fixes the Realtek Audio Console "Can not connect to RPC service" error on Windows 10/11.

.DESCRIPTION
    Realtek Audio Console is a UWP application that talks to a per-user RPC helper
    (RtkAudUService64.exe -background). That helper is normally started at logon by the
    scheduled task "RtkAudUService64_BG". If the task is disabled, missing, or blocked,
    the console still opens but displays:

        Can not connect to RPC service.

    This script diagnoses the whole RPC chain, re-enables (or recreates) the logon task,
    starts the helper immediately, and verifies the result. It does not touch audio
    drivers, Windows Audio settings, or any unrelated service.

.PARAMETER Action
    Diagnose  Read-only report of the RPC chain.
    Fix       Repair the chain (default).
    Restore   Undo the changes made by Fix (disable the task, stop the helper).

.PARAMETER ResetApp
    Also reset the Realtek Audio Console app package (clears its local state) before
    launching it. Useful when the app window itself is stuck.

.PARAMETER LaunchApp
    Open Realtek Audio Console after a successful Fix.

.PARAMETER NoRelaunch
    Do not self-elevate. Use when the caller is already elevated.

.PARAMETER LogPath
    Custom log file path. Default: %ProgramData%\RealtekAudioConsoleRpcFix\fix.log
    (falls back to %TEMP% when the script is not elevated).

.EXAMPLE
    .\Fix-RealtekAudioConsole.ps1 -Action Diagnose

.EXAMPLE
    .\Fix-RealtekAudioConsole.ps1 -Action Fix -LaunchApp

.EXAMPLE
    .\Fix-RealtekAudioConsole.ps1 -Action Restore

.NOTES
    Version: 1.0.0
    Author : DigiSphereX
    License: MIT
    Tested : Windows 11 build 26200 (25H2), Realtek Audio Universal Service 1.0.0.207
#>
[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Fix', 'Restore')]
    [string]$Action = 'Fix',

    [switch]$ResetApp,
    [switch]$LaunchApp,
    [switch]$NoRelaunch,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Constants
# ---------------------------------------------------------------------------
$VendorTaskName   = 'RtkAudUService64_BG'
$FallbackTaskName = 'RealtekAudioConsoleRpcHelper'
$ServiceName      = 'RtkAudioUniversalService'
$HelperExe        = Join-Path $env:SystemRoot 'System32\RtkAudUService64.exe'
$AppAumid         = 'RealtekSemiconductorCorp.RealtekAudioControl_dt26b99r8h8gj!App'
$AudioServices    = @('Audiosrv', 'AudioEndpointBuilder')

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------
function Initialize-Log {
    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        if (Test-Admin) {
            $script:LogPath = Join-Path $env:ProgramData 'RealtekAudioConsoleRpcFix\fix.log'
        }
        else {
            $script:LogPath = Join-Path $env:TEMP 'RealtekAudioConsoleRpcFix\fix.log'
        }
    }
    $dir = Split-Path -Parent $script:LogPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')]
        [string]$Level = 'Info'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"

    switch ($Level) {
        'Ok'    { Write-Host $Message -ForegroundColor Green }
        'Warn'  { Write-Host $Message -ForegroundColor Yellow }
        'Error' { Write-Host $Message -ForegroundColor Red }
        'Step'  { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message }
    }

    if ($script:LogPath) {
        try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    return [PSCustomObject]@{
        Caption = $os.Caption
        Version = $os.Version
        Build   = $os.BuildNumber
    }
}

function Get-RealtekDriver {
    $all = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName -match '(?i)realtek' }

    # Prefer the real MEDIA-class audio driver over Realtek software components.
    $media = $all | Where-Object { $_.DeviceClass -eq 'MEDIA' } | Select-Object -First 1
    if ($media) {
        return $media | Select-Object DeviceName, DriverVersion, DriverDate
    }
    return $all | Where-Object { $_.DeviceName -match '(?i)audio' } |
        Select-Object -First 1 DeviceName, DriverVersion, DriverDate
}

function Get-RealtekService {
    Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
}

function Get-VendorTask {
    Get-ScheduledTask -TaskName $VendorTaskName -ErrorAction SilentlyContinue
}

function Get-FallbackTask {
    Get-ScheduledTask -TaskName $FallbackTaskName -ErrorAction SilentlyContinue
}

function Get-HelperProcesses {
    Get-Process -Name 'RtkAudUService64' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -ne 0 }
}

function Get-ConsolePackage {
    Get-AppxPackage -Name '*RealtekAudioControl*' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-RealtekEndpoints {
    Get-PnpDevice -Class AudioEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match '(?i)realtek' }
}

function Format-Status {
    param([bool]$Ok)
    if ($Ok) { return 'OK' } else { return 'PROBLEM' }
}

# ---------------------------------------------------------------------------
#  Elevation
# ---------------------------------------------------------------------------
function Invoke-Elevated {
    $exe = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($exe)) {
        throw 'Cannot determine the script path for elevation. Re-run from a saved .ps1 file.'
    }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $exe),
        '-Action', $Action,
        '-NoRelaunch'
    )
    if ($ResetApp) { $argList += '-ResetApp' }
    if ($LaunchApp) { $argList += '-LaunchApp' }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $argList += @('-LogPath', ('"{0}"' -f $LogPath)) }

    Write-Host 'Administrator rights are required. Requesting elevation...' -ForegroundColor Yellow
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

# ---------------------------------------------------------------------------
#  Diagnose
# ---------------------------------------------------------------------------
function Invoke-Diagnose {
    Write-Log 'Realtek Audio Console RPC chain - diagnostic report' -Level Step
    Write-Log ''

    $os = Get-OsInfo
    Write-Log ("OS              : {0} (build {1})" -f $os.Caption, $os.Build)

    $drv = Get-RealtekDriver
    if ($drv) {
        Write-Log ("Realtek driver  : {0}  v{1}" -f $drv.DeviceName, $drv.DriverVersion)
    }
    else {
        Write-Log 'Realtek driver  : not detected' -Level Warn
    }

    $svc = Get-RealtekService
    $vendorTask = Get-VendorTask
    $fallbackTask = Get-FallbackTask
    $helper = @(Get-HelperProcesses)
    $pkg = Get-ConsolePackage
    $endpoints = @(Get-RealtekEndpoints)

    $checks = New-Object System.Collections.ArrayList

    # 1. Realtek service
    $svcOk = $svc -and $svc.State -eq 'Running'
    [void]$checks.Add([PSCustomObject]@{
        Check  = 'RtkAudioUniversalService'
        Status = Format-Status ([bool]$svcOk)
        Detail = if ($svc) { "$($svc.State) / $($svc.StartMode)" } else { 'service not installed' }
    })

    # 2. Vendor logon task
    $taskOk = $vendorTask -and $vendorTask.Settings.Enabled
    [void]$checks.Add([PSCustomObject]@{
        Check  = "$VendorTaskName (logon task)"
        Status = Format-Status ([bool]$taskOk)
        Detail = if ($vendorTask) { "State=$($vendorTask.State) Enabled=$($vendorTask.Settings.Enabled)" } else { 'task not found' }
    })

    # 3. Fallback task (only relevant when the vendor task is missing)
    if (-not $vendorTask) {
        $fbOk = $fallbackTask -and $fallbackTask.Settings.Enabled
        [void]$checks.Add([PSCustomObject]@{
            Check  = "$FallbackTaskName (fallback)"
            Status = Format-Status ([bool]$fbOk)
            Detail = if ($fallbackTask) { "State=$($fallbackTask.State) Enabled=$($fallbackTask.Settings.Enabled)" } else { 'not created' }
        })
    }

    # 4. Per-user RPC helper
    $helperOk = $helper.Count -gt 0
    [void]$checks.Add([PSCustomObject]@{
        Check  = 'RPC helper in user session'
        Status = Format-Status $helperOk
        Detail = if ($helperOk) { ($helper | ForEach-Object { "PID $($_.Id) (session $($_.SessionId))" }) -join ', ' } else { 'not running' }
    })

    # 5. Windows Audio
    $audioOk = $true
    $audioDetail = @()
    foreach ($name in $AudioServices) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -ne 'Running') { $audioOk = $false }
        $audioDetail += if ($s) { "$name=$($s.Status)" } else { "$name=missing" }
    }
    [void]$checks.Add([PSCustomObject]@{
        Check  = 'Windows Audio services'
        Status = Format-Status $audioOk
        Detail = $audioDetail -join ', '
    })

    # 6. Console app package
    $pkgOk = $pkg -and $pkg.Status -eq 'Ok'
    [void]$checks.Add([PSCustomObject]@{
        Check  = 'Realtek Audio Console package'
        Status = Format-Status ([bool]$pkgOk)
        Detail = if ($pkg) { "v$($pkg.Version) / $($pkg.Status)" } else { 'not installed' }
    })

    # 7. Realtek audio endpoints
    $epOk = $endpoints.Count -gt 0
    [void]$checks.Add([PSCustomObject]@{
        Check  = 'Realtek audio endpoints'
        Status = Format-Status $epOk
        Detail = if ($epOk) { ($endpoints | ForEach-Object { "$($_.FriendlyName)=$($_.Status)" }) -join '; ' } else { 'none found' }
    })

    Write-Log ''
    $checks | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $problems = @($checks | Where-Object { $_.Status -eq 'PROBLEM' })
    Write-Log ''
    if ($problems.Count -eq 0) {
        Write-Log 'Result: the RPC chain looks healthy.' -Level Ok
        return 0
    }

    Write-Log ("Result: {0} problem(s) found. Run with -Action Fix to repair." -f $problems.Count) -Level Warn
    return 1
}

# ---------------------------------------------------------------------------
#  Fix
# ---------------------------------------------------------------------------
function Invoke-Fix {
    Write-Log 'Realtek Audio Console RPC repair' -Level Step
    Write-Log ''

    $os = Get-OsInfo
    if ([int]$os.Build -lt 10240) {
        Write-Log ("Unsupported OS: {0} (build {1}). Windows 10 or later is required." -f $os.Caption, $os.Build) -Level Error
        return 2
    }

    $svc = Get-RealtekService
    if (-not $svc) {
        Write-Log "Service '$ServiceName' is not installed. Install the Realtek audio driver first." -Level Error
        return 2
    }

    # 1. Windows Audio must be running.
    foreach ($name in $AudioServices) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        if ($s.Status -ne 'Running') {
            Write-Log "Starting $name..." -Level Step
            Start-Service -Name $name -ErrorAction SilentlyContinue
        }
    }

    # 2. Realtek service: Automatic + Running.
    if ($svc.StartMode -eq 'Disabled') {
        Write-Log "Setting $ServiceName startup type to Automatic..." -Level Step
        Set-Service -Name $ServiceName -StartupType Automatic
    }
    $svc = Get-RealtekService
    if ($svc.State -ne 'Running') {
        Write-Log "Starting $ServiceName..." -Level Step
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # 3. Vendor logon task: enable it (or create a fallback).
    $vendorTask = Get-VendorTask
    if ($vendorTask) {
        Write-Log "Enabling scheduled task '$VendorTaskName'..." -Level Step
        Enable-ScheduledTask -TaskName $VendorTaskName | Out-Null

        $t = Get-ScheduledTask -TaskName $VendorTaskName
        $changed = $false
        if ($t.Settings.DisallowStartIfOnBatteries) { $t.Settings.DisallowStartIfOnBatteries = $false; $changed = $true }
        if ($t.Settings.StopIfGoingOnBatteries)    { $t.Settings.StopIfGoingOnBatteries = $false; $changed = $true }
        if ($t.Settings.ExecutionTimeLimit -and $t.Settings.ExecutionTimeLimit -ne 'PT0S') {
            $t.Settings.ExecutionTimeLimit = 'PT0S'
            $changed = $true
        }
        if ($changed) {
            Write-Log 'Adjusting task settings (battery / time limit)...' -Level Step
            Set-ScheduledTask -TaskName $VendorTaskName -Settings $t.Settings | Out-Null
        }
    }
    else {
        Write-Log "Task '$VendorTaskName' was not found. Creating a fallback logon task..." -Level Step
        $taskAction = New-ScheduledTaskAction -Execute $HelperExe -Argument '-background'
        $trigger    = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $FallbackTaskName -Action $taskAction -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Starts the Realtek Audio Console RPC helper at logon.' | Out-Null
    }

    # 4. Start the per-user helper now (no logoff needed).
    $helper = @(Get-HelperProcesses)
    if ($helper.Count -eq 0) {
        Write-Log 'Starting the RPC helper in the current user session...' -Level Step
        if (Get-VendorTask) {
            Start-ScheduledTask -TaskName $VendorTaskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        if (@(Get-HelperProcesses).Count -eq 0) {
            if (Test-Path $HelperExe) {
                Start-Process -FilePath $HelperExe -ArgumentList '-background' -WindowStyle Hidden
                Start-Sleep -Seconds 3
            }
            else {
                Write-Log "Helper binary not found: $HelperExe" -Level Error
            }
        }
    }

    # 5. Optional: reset the app package.
    if ($ResetApp) {
        $pkg = Get-ConsolePackage
        if ($pkg) {
            Write-Log 'Resetting Realtek Audio Console app state...' -Level Step
            try {
                Get-Process -Name 'RtkUWP' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                Reset-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                Write-Log 'App package reset.' -Level Ok
            }
            catch {
                Write-Log ("App reset skipped: {0}" -f $_.Exception.Message) -Level Warn
            }
        }
    }

    # 6. Verify.
    Start-Sleep -Seconds 1
    $helper   = @(Get-HelperProcesses)
    $svcNow   = Get-RealtekService
    $taskNow  = Get-VendorTask
    if (-not $taskNow) { $taskNow = Get-FallbackTask }
    $taskOn   = $taskNow -and $taskNow.Settings.Enabled

    Write-Log ''
    Write-Log 'Verification' -Level Step
    Write-Log ("  Service  : {0} / {1}" -f $svcNow.State, $svcNow.StartMode)
    Write-Log ("  Logon task: {0} (Enabled={1})" -f $taskNow.TaskName, $taskOn)
    if ($helper.Count -gt 0) {
        Write-Log ("  Helper   : {0}" -f (($helper | ForEach-Object { "PID $($_.Id) session $($_.SessionId)" }) -join ', '))
    }
    else {
        Write-Log '  Helper   : not running' -Level Warn
    }

    $ok = ($svcNow.State -eq 'Running') -and $taskOn -and ($helper.Count -gt 0)

    # 7. Optionally launch the console.
    if ($ok -and $LaunchApp) {
        Write-Log 'Opening Realtek Audio Console...' -Level Step
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\{0}' -f $AppAumid) -ErrorAction SilentlyContinue
    }

    Write-Log ''
    if ($ok) {
        Write-Log 'Repair complete. Realtek Audio Console should connect now.' -Level Ok
        Write-Log 'If the window was already open, close it and open it again.' -Level Info
        return 0
    }

    Write-Log 'Repair finished, but one or more checks still fail. See the verification block above.' -Level Warn
    return 1
}

# ---------------------------------------------------------------------------
#  Restore
# ---------------------------------------------------------------------------
function Invoke-Restore {
    Write-Log 'Restoring the pre-fix state' -Level Step
    Write-Log ''

    if (Get-VendorTask) {
        Write-Log "Disabling scheduled task '$VendorTaskName'..." -Level Step
        Disable-ScheduledTask -TaskName $VendorTaskName -ErrorAction SilentlyContinue | Out-Null
    }

    if (Get-FallbackTask) {
        Write-Log "Removing fallback task '$FallbackTaskName'..." -Level Step
        Unregister-ScheduledTask -TaskName $FallbackTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $helper = @(Get-HelperProcesses)
    if ($helper.Count -gt 0) {
        Write-Log 'Stopping the per-user RPC helper...' -Level Step
        $helper | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Log ''
    Write-Log 'Restore complete. The service was left running (Windows Audio still needs it).' -Level Ok
    return 0
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------
try {
    Initialize-Log

    if (-not (Test-Admin) -and $Action -ne 'Diagnose' -and -not $NoRelaunch) {
        Invoke-Elevated
    }

    Write-Log ("Realtek Audio Console RPC Fix - action: {0}" -f $Action)
    Write-Log ("Log: {0}" -f $LogPath)

    switch ($Action) {
        'Diagnose' { $code = Invoke-Diagnose }
        'Fix'      { $code = Invoke-Fix }
        'Restore'  { $code = Invoke-Restore }
    }
}
catch {
    Write-Log ("Unhandled error: {0}" -f $_.Exception.Message) -Level Error
    Write-Log ($_.ScriptStackTrace) -Level Error
    $code = 1
}

exit $code
