$ErrorActionPreference = 'Stop'
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$hermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA 'hermes' }
& (Join-Path $PSScriptRoot 'Protect-HermesMobileStore.ps1') -Path (Join-Path $hermesHome 'mobile')
$admissions = [Environment]::GetEnvironmentVariable('HERMES_MOBILE_ADMISSIONS_DIR', 'User')
if ($admissions -and -not [IO.Directory]::Exists($admissions)) {
    & (Join-Path $PSScriptRoot 'Protect-HermesMobileStore.ps1') -Path $admissions
}
$launcher = Join-Path $PSScriptRoot 'Start-HermesMobile.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
foreach ($service in 'Bridge','Status') {
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}" -Service {1}' -f $launcher,$service
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $existing = Get-ScheduledTask -TaskName "HermesMobile$service" -ErrorAction SilentlyContinue
    if ($existing -and $existing.Actions[0].Arguments -ne $arguments) {
        throw "HermesMobile$service already exists with a different launcher."
    }
    Register-ScheduledTask -Force -TaskName "HermesMobile$service" -Action $action -Trigger $trigger -Settings $settings -User $user | Out-Null
    Start-ScheduledTask -TaskName "HermesMobile$service"
}
