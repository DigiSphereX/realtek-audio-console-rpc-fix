#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only diagnostic for the Realtek Audio Console RPC chain.

.DESCRIPTION
    Thin wrapper around Fix-RealtekAudioConsole.ps1 -Action Diagnose.
    Prints the state of the service, the logon task, the per-user helper,
    Windows Audio, the app package and the Realtek endpoints.

.EXAMPLE
    .\Diagnose-RealtekAudioConsole.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoRelaunch,
    [string]$LogPath
)

$main = Join-Path $PSScriptRoot 'Fix-RealtekAudioConsole.ps1'
if (-not (Test-Path $main)) {
    Write-Error "Fix-RealtekAudioConsole.ps1 not found next to this script."
    exit 2
}

$argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $main, '-Action', 'Diagnose')
if ($NoRelaunch) { $argsList += '-NoRelaunch' }
if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $argsList += @('-LogPath', ('"{0}"' -f $LogPath)) }

& powershell.exe @argsList
exit $LASTEXITCODE
