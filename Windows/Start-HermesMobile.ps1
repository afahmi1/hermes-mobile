param(
    [Parameter(Mandatory)][ValidateSet('Bridge','Status')][string]$Service,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $env:HERMES_HOME) { $env:HERMES_HOME = Join-Path $env:LOCALAPPDATA 'hermes' }
$runtime = Join-Path $env:HERMES_HOME 'hermes-agent'

# Hermes's package manager keeps its dependencies in a committed environment that moves on every update; the
# in-tree .venv/venv predates it and goes stale. Ask Hermes which one is current, every start.
function Resolve-HermesPython {
    if ($env:HERMES_PYTHON -and (Test-Path $env:HERMES_PYTHON)) { return $env:HERMES_PYTHON }
    $boots = @(Get-ChildItem (Join-Path $env:HERMES_HOME 'tools') -Directory -Filter 'python-*' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' } | Where-Object { Test-Path $_ })
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    $boots += @($(if ($py) { $py.Source }))
    # No double quotes in this argument: Windows PowerShell 5.1 (what the scheduled tasks run) strips them when it
    # passes a string to a native program, the query then fails to parse, and the bridge silently falls back to
    # a legacy venv that may lack aiohttp.
    $query = 'import os, sys; sys.path.insert(0, os.curdir); from pathlib import Path; from pm.environments import committed_venv; e = committed_venv(Path(os.curdir).resolve()); print(e or str())'
    foreach ($boot in $boots) {
        Push-Location $runtime
        try { $envDir = (& $boot -I -c $query 2>$null | Select-Object -Last 1) } catch { $envDir = '' } finally { Pop-Location }
        if ($envDir) {
            $candidate = Join-Path $envDir 'Scripts/python.exe'
            if (Test-Path $candidate) { return $candidate }
        }
    }
    foreach ($legacy in '.venv/Scripts/python.exe', 'venv/Scripts/python.exe') {
        $candidate = Join-Path $runtime $legacy
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Couldn't find Hermes's Python under $env:HERMES_HOME. Set HERMES_PYTHON and run again."
}

$python = Resolve-HermesPython
$env:PYTHONPATH = $runtime
$env:PYTHONUTF8 = '1'
if (-not $env:HERMES_MOBILE_ADMISSIONS_DIR) {
    $env:HERMES_MOBILE_ADMISSIONS_DIR = [Environment]::GetEnvironmentVariable('HERMES_MOBILE_ADMISSIONS_DIR', 'User')
}
$env:HERMES_BIN = Join-Path $env:HERMES_HOME 'bin/hermes.exe'
$env:HERMES_STATUS_STATE = Join-Path $env:HERMES_HOME 'mobile/seen.json'
$env:HERMES_MOBILE_BIND = '127.0.0.1'
$env:HERMES_MOBILE_AUTO_KEYS = '0'
$script = if ($Service -eq 'Bridge') { 'Bridge/hermes_mobile_bridge.py' } else { 'Status/hermes_status_server.py' }
& $python (Join-Path $root $script) @Rest
exit $LASTEXITCODE
