<#
.SYNOPSIS
Starts or stops the no-secret local development demo.
#>
[CmdletBinding()]
param([switch]$Stop)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $root '.local-demo-processes.json'
if ($Stop) {
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        foreach ($id in @($state.processIds)) {
            $process = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($process) { Stop-Process -Id $id }
        }
        Remove-Item -LiteralPath $statePath -Force
    }
    Write-Host 'Local demo stopped.'
    return
}
if (Test-Path -LiteralPath $statePath) { throw "Local demo state already exists. Run with -Stop first." }

$python = Join-Path $root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Run "uv sync --frozen" before starting the local demo.' }
$common = @{
    APP_DEVELOPMENT_MODE = 'true'
    APP_AUTH_LOCAL_DEV_BYPASS = 'true'
    APP_RETRIEVAL_MODE = 'local'
    APP_DATA_DIRECTORY = (Join-Path $root 'data')
    APP_FOUNDRY_ENABLED = 'false'
    APP_AGENT_TRANSPORT = 'local'
}
$commands = @(
    @{ Name = 'web-api'; Module = 'aks_agents.web_api'; Port = 8000 },
    @{ Name = 'meal-planner'; Module = 'aks_agents.meal_planner_agent'; Port = 8002 },
    @{ Name = 'availability'; Module = 'aks_agents.availability_agent'; Port = 8003 },
    @{ Name = 'inventory-mcp'; Module = 'aks_agents.inventory_mcp'; Port = 8004 }
)
$processes = @()
foreach ($service in $commands) {
    $envPairs = @($common.GetEnumerator() | ForEach-Object { "`$env:$($_.Key)='$($_.Value.Replace("'","''"))'" })
    $script = ($envPairs + @("`$env:APP_PORT='$($service.Port)'", "& '$python' -m $($service.Module)")) -join '; '
    $processes += Start-Process pwsh -ArgumentList @('-NoLogo','-NoProfile','-Command',$script) -WorkingDirectory $root -PassThru
}
$webScript = "npm run dev -- --host=127.0.0.1"
$processes += Start-Process pwsh -ArgumentList @('-NoLogo','-NoProfile','-Command',$webScript) -WorkingDirectory (Join-Path $root 'web') -PassThru
@{ processIds = @($processes.Id); startedAtUtc = [DateTime]::UtcNow.ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
Write-Host 'Local demo starting at http://127.0.0.1:5173 (API ports 8000, 8002, 8003, 8004).'
