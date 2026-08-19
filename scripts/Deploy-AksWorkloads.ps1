<#
.SYNOPSIS
Renders and deploys the AKS workload manifests.
.DESCRIPTION
Deploys all-sidecar, all-direct, or mixed authentication using the documented
Microsoft Entra Agent ID autonomous-agent contracts. Direct mode remains
experimental and nonproduction.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('sidecar', 'direct', 'mixed')][string]$AuthMode,
    [Parameter(Mandatory)][string]$ImageTag,
    [string]$InfrastructureOutputsPath = (Join-Path $PSScriptRoot '..\infra-outputs.json'),
    [string]$EntraOutputsPath = (Join-Path $PSScriptRoot '..\entra-outputs.json'),
    [string]$SearchIndex = 'recipes',
    [string]$AuthSdkImage = 'mcr.microsoft.com/entra-sdk/auth-sidecar@sha256:05f77ddaf35a0763950d24493044867be9f9a258d113eeff57cecb5cc9cecc78',
    [switch]$SkipClusterCredentials,
    [switch]$RenderOnly,
    [string]$RenderedPath = (Join-Path $PSScriptRoot '..\deploy\rendered.yaml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$infra = Get-Content -LiteralPath $InfrastructureOutputsPath -Raw | ConvertFrom-Json
$entra = Get-Content -LiteralPath $EntraOutputsPath -Raw | ConvertFrom-Json

if ($AuthMode -in @('sidecar', 'mixed')) {
    if ($AuthSdkImage -notmatch '@sha256:[0-9a-fA-F]{64}$') { throw 'AuthSdkImage must be pinned by sha256 digest.' }
}

$roles = @{
    mealPlanner = @{ Expected = 'MealPlan.Request'; Api = $entra.protectedApis.mealPlanner }
    availability = @{ Expected = 'Availability.Request'; Api = $entra.protectedApis.availability }
    inventory = @{ Expected = 'Inventory.Read'; Api = $entra.protectedApis.inventory }
}
foreach ($entry in $roles.GetEnumerator()) {
    if ([string]$entry.Value.Api.appRole.value -ne $entry.Value.Expected -or -not [string]$entry.Value.Api.audience) {
        throw "entra-outputs.json has an invalid $($entry.Key) audience/role contract."
    }
}
if ($entra.adminConsent.appRoleAssignmentsGranted -ne $true) {
    throw 'Entra app-role assignments are not confirmed; run Set-AgentRoleAssignments.ps1 first.'
}
$tenantId = [string]$entra.tenantId
if (-not $tenantId -or $tenantId -ne [string]$infra.tenantId) { throw 'Tenant IDs in the output files do not match.' }
$identityMappings = @{
    concierge = 'concierge'
    mealPlanner = 'mealPlanner'
    availability = 'availability'
}
foreach ($mapping in $identityMappings.GetEnumerator()) {
    $infraClientId = [string]$infra.identities.($mapping.Value).clientId
    $agentClientId = [string]$entra.agentIdentities.($mapping.Key).workloadIdentity.clientId
    if (-not $infraClientId -or $infraClientId -ne $agentClientId) {
        throw "The $($mapping.Key) Agent ID is not mapped to the expected infrastructure UAMI."
    }
}
$chatModels = @($infra.foundryModelDeployments.chat)
if (-not $chatModels.Count) { throw 'infra-outputs.json contains no Foundry chat deployment.' }

$values = @{
    '__ACR_LOGIN_SERVER__' = [string]$infra.acrLoginServer
    '__IMAGE_TAG__' = $ImageTag
    '__CONCIERGE_CLIENT_ID__' = [string]$infra.identities.concierge.clientId
    '__MEAL_PLANNER_CLIENT_ID__' = [string]$infra.identities.mealPlanner.clientId
    '__AVAILABILITY_CLIENT_ID__' = [string]$infra.identities.availability.clientId
    '__INVENTORY_MCP_CLIENT_ID__' = [string]$infra.identities.inventoryMcp.clientId
    '__TENANT_ID__' = $tenantId
    '__JWT_ISSUER__' = "https://sts.windows.net/$tenantId/"
    '__JWT_JWKS_URL__' = "https://login.microsoftonline.com/$tenantId/discovery/v2.0/keys"
    '__FOUNDRY_ENDPOINT__' = [string]$infra.foundryEndpoint
    '__FOUNDRY_MODEL__' = [string]$chatModels[0]
    '__SEARCH_ENDPOINT__' = [string]$infra.searchEndpoint
    '__SEARCH_INDEX__' = $SearchIndex
    '__APPINSIGHTS_CONNECTION_STRING__' = [string]$infra.applicationInsightsConnectionString
    '__MEAL_PLANNER_AUDIENCE__' = [string]$roles.mealPlanner.Api.audience
    '__AVAILABILITY_AUDIENCE__' = [string]$roles.availability.Api.audience
    '__INVENTORY_AUDIENCE__' = [string]$roles.inventory.Api.audience
    '__CONCIERGE_AGENT_ID__' = [string]$entra.agentIdentities.concierge.appId
    '__CONCIERGE_BLUEPRINT_ID__' = [string]$entra.agentIdentities.concierge.blueprint.appId
    '__AVAILABILITY_AGENT_ID__' = [string]$entra.agentIdentities.availability.appId
    '__AVAILABILITY_BLUEPRINT_ID__' = [string]$entra.agentIdentities.availability.blueprint.appId
    '__AUTH_SDK_IMAGE__' = [string]$AuthSdkImage
}
foreach ($key in @('__ACR_LOGIN_SERVER__','__CONCIERGE_CLIENT_ID__','__MEAL_PLANNER_CLIENT_ID__',
    '__AVAILABILITY_CLIENT_ID__','__INVENTORY_MCP_CLIENT_ID__','__FOUNDRY_ENDPOINT__',
    '__SEARCH_ENDPOINT__','__APPINSIGHTS_CONNECTION_STRING__','__CONCIERGE_AGENT_ID__',
    '__CONCIERGE_BLUEPRINT_ID__','__AVAILABILITY_AGENT_ID__','__AVAILABILITY_BLUEPRINT_ID__')) {
    if (-not $values[$key]) { throw "Required infrastructure value $key is empty." }
}

$generated = Join-Path $root 'deploy\.generated'
if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Recurse -Force }
New-Item -ItemType Directory -Path $generated -Force | Out-Null
Copy-Item -Path (Join-Path $root 'deploy\base') -Destination $generated -Recurse
New-Item -ItemType Directory -Path (Join-Path $generated 'overlays') -Force | Out-Null
Copy-Item -Path (Join-Path $root "deploy\overlays\$AuthMode") -Destination (Join-Path $generated 'overlays') -Recurse
Get-ChildItem -Path $generated -Filter *.yaml -Recurse | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    foreach ($pair in $values.GetEnumerator()) { $content = $content.Replace($pair.Key, $pair.Value) }
    Set-Content -LiteralPath $_.FullName -Value $content -Encoding utf8NoBOM
}
$overlay = Join-Path $generated "overlays\$AuthMode"
try {
    $manifest = & kubectl kustomize $overlay
    if ($LASTEXITCODE -ne 0) { throw 'kubectl kustomize failed.' }
    $unresolved = @([regex]::Matches(($manifest -join "`n"), '__[A-Z][A-Z0-9_]*__') | ForEach-Object Value | Sort-Object -Unique)
    if ($unresolved.Count -gt 0) {
        throw "Rendered manifest contains unresolved placeholders: $($unresolved -join ', ')."
    }
    $renderedDirectory = Split-Path -Parent $RenderedPath
    if ($renderedDirectory) { New-Item -ItemType Directory -Path $renderedDirectory -Force | Out-Null }
    $manifest | Set-Content -LiteralPath $RenderedPath -Encoding utf8NoBOM
    if ($RenderOnly) { Write-Host "Rendered manifest written to '$RenderedPath'."; return }
    if (-not $SkipClusterCredentials) {
        az aks get-credentials --resource-group ([string]$infra.resourceGroupName) --name ([string]$infra.aksName) --overwrite-existing --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Could not acquire AKS credentials.' }
    }
    & kubectl apply -f $RenderedPath
    if ($LASTEXITCODE -ne 0) { throw 'kubectl apply failed.' }
    foreach ($deployment in @('web','web-api','meal-planner','availability','inventory-mcp')) {
        & kubectl rollout status "deployment/$deployment" -n apps --timeout=5m
        if ($LASTEXITCODE -ne 0) { throw "Rollout failed for $deployment." }
    }
} finally {
    if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Recurse -Force }
}
