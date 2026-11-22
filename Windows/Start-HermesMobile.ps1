param([Parameter(Mandatory)][ValidateSet('Bridge','Status')][string]$Service)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $env:HERMES_HOME) { $env:HERMES_HOME = Join-Path $env:LOCALAPPDATA 'hermes' }
$runtime = Join-Path $env:HERMES_HOME 'hermes-agent'
$python = Join-Path $runtime '.venv/Scripts/python.exe'
$env:PYTHONPATH = $runtime
$env:PYTHONUTF8 = '1'
$env:HERMES_BIN = Join-Path $env:HERMES_HOME 'bin/hermes.exe'
$env:HERMES_STATUS_STATE = Join-Path $env:HERMES_HOME 'mobile/seen.json'
$env:HERMES_MOBILE_BIND = '127.0.0.1'
$env:HERMES_MOBILE_AUTO_KEYS = '0'
$script = if ($Service -eq 'Bridge') { 'Bridge/hermes_mobile_bridge.py' } else { 'Status/hermes_status_server.py' }
& $python (Join-Path $root $script)
exit $LASTEXITCODE
