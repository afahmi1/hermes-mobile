# Swap a staged Hermes Mobile build into place on this Windows machine once Hermes is idle, then restart and check.
# Usage: Update-HermesMobile.ps1 -Staged <dir with Bridge, Status, Windows>
# Run it as a one-shot scheduled task with LogonType S4U (Windows OpenSSH kills children when the session closes, and an
# Interactive task never logs). Always pass -Staged: it's mandatory, and a task without it hangs on a hidden prompt.
param([Parameter(Mandatory)][string]$Staged, [int]$WaitMinutes = 180)
$ErrorActionPreference = 'Stop'
$live = Join-Path $env:LOCALAPPDATA 'HermesMobileCompanion'
$state = Join-Path $env:LOCALAPPDATA 'hermes\gateway_state.json'
$log = Join-Path $env:LOCALAPPDATA 'hermes\mobile\update.log'
# UTF-8 always: a mixed-encoding log can't be searched (Select-String misses every new line).
function Say($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Tee-Object -FilePath $log -Append -Encoding utf8 }

Say "update staged from $Staged; waiting for Hermes to be idle (up to $WaitMinutes min)"
$idle = 0
$deadline = (Get-Date).AddMinutes($WaitMinutes)
while ((Get-Date) -lt $deadline) {
    try { $n = [int]((Get-Content $state -Raw | ConvertFrom-Json).active_agents) } catch { $n = 1 }
    if ($n -eq 0) { $idle++ } else { $idle = 0 }
    if ($idle -ge 3) { break }
    Start-Sleep -Seconds 10
}
if ($idle -lt 3) { Say "Hermes never went idle; nothing changed"; exit 1 }

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
Stop-ScheduledTask -TaskName HermesMobileBridge -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName HermesMobileStatus -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Rename-Item $live "$live.old-$stamp"
Copy-Item -Recurse $Staged $live
Start-ScheduledTask -TaskName HermesMobileBridge
Start-ScheduledTask -TaskName HermesMobileStatus
Say "swapped in; previous copy kept at $live.old-$stamp"

$ok = $false
foreach ($i in 1..15) {
    Start-Sleep -Seconds 2
    try { if ((Invoke-WebRequest -UseBasicParsing http://127.0.0.1:9131/m/ping -TimeoutSec 3).StatusCode -eq 200) { $ok = $true; break } } catch {}
}
if (-not $ok) {
    Say "new bridge did not answer; rolling back"
    Stop-ScheduledTask -TaskName HermesMobileBridge -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $live
    Rename-Item "$live.old-$stamp" $live
    Start-ScheduledTask -TaskName HermesMobileBridge
    exit 1
}
Say "bridge answers; doctor:"
& (Join-Path $live 'Windows\Start-HermesMobile.ps1') -Service Bridge --doctor 2>&1 | Out-String | Tee-Object -FilePath $log -Append -Encoding utf8
# Keep the two newest old copies.
Get-ChildItem (Split-Path $live) -Directory -Filter 'HermesMobileCompanion.old-*' | Sort-Object Name -Descending |
    Select-Object -Skip 2 | Remove-Item -Recurse -Force
Say "done"
