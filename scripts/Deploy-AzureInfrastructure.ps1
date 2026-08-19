<#
.SYNOPSIS
Deploys the Bicep baseline and writes its non-secret outputs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$Location,
    [string]$AksLocation,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]{3,12}$')][string]$Prefix,
    [string]$DeploymentName = "aks-agent-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))",
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\infra-outputs.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$template = Join-Path $root 'infra\main.bicep'
if (-not $AksLocation) { $AksLocation = $Location }

az account show --only-show-errors | Out-Null
az group create --name $ResourceGroupName --location $Location --only-show-errors --output none
$raw = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --template-file $template `
    --parameters "prefix=$Prefix" "location=$Location" "aksLocation=$AksLocation" `
    --only-show-errors --output json
if ($LASTEXITCODE -ne 0) { throw 'Azure infrastructure deployment failed.' }

$deployment = $raw | ConvertFrom-Json
$flattened = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
}
foreach ($property in $deployment.properties.outputs.PSObject.Properties) {
    $flattened[$property.Name] = $property.Value.value
}
$directory = Split-Path -Parent $OutputPath
if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$flattened | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "Infrastructure outputs written to '$OutputPath'."
