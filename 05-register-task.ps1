# Phase 8c - Register the Windows Scheduled Task (startup + every 5 minutes).
# Run only AFTER the manual tests (06-selfhealing-test.ps1) passed.
$ProjectRoot = $PSScriptRoot
$ScriptPath  = Join-Path $ProjectRoot 'scripts\SelfHealing.ps1'
$TaskName    = 'Cinema-SelfHealing-Monitor'

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Not found: $ScriptPath" }

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
    -WorkingDirectory $ProjectRoot

$StartupTrigger = New-ScheduledTaskTrigger -AtStartup
$RepeatTrigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$Settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

# SYSTEM + highest privileges: needed here for wbadmin and for C:\CinemaData (lab environment).
$Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName `
    -Action $Action `
    -Trigger @($StartupTrigger, $RepeatTrigger) `
    -Settings $Settings `
    -Principal $Principal `
    -Description 'Checks monitored Cinema files every 5 minutes and restores them safely.' `
    -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State, Description
(Get-ScheduledTask -TaskName $TaskName).Triggers | Format-List
Get-ScheduledTaskInfo -TaskName $TaskName
