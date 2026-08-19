<#
.SYNOPSIS
Removes only deterministic, sample-prefixed Entra objects.
.DESCRIPTION
Deletes only the Agent Identities, protected API applications, and Agent ID
blueprints whose immutable IDs and relationships match the provisioning output.
It does not delete Azure managed identities. All Agent ID calls use documented
Microsoft Graph v1.0 typed endpoints; no implicit beta fallback is performed.
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER Prefix
The same deterministic prefix used during provisioning.
.PARAMETER EntraOutputsPath
Required non-secret provisioning output. Tenant, prefix, immutable object IDs,
display names, application IDs, types, and blueprint relationships are verified
before any deletion.
.EXAMPLE
Connect-MgGraph -TenantId $tenant -Scopes 'AgentIdentity.Read.All','AgentIdentity.DeleteRestore.All','AgentIdentityBlueprint.Read.All','AgentIdentityBlueprint.DeleteRestore.All','Application.ReadWrite.All'
.\scripts\Remove-EntraAgentIdResources.ps1 -TenantId $tenant -Prefix mealagentpoc -EntraOutputsPath .\entra-outputs.json
.NOTES
Agent Identity deletion requires a supported directory role, normally Agent ID
Administrator, in addition to the listed admin-consented delegated scopes.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{1,39}$')][string]$Prefix,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$EntraOutputsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\EntraAgentId.Common.psm1') -Force -DisableNameChecking
Assert-AgentGraphContext -TenantId $TenantId -RequiredScopes @(
    'AgentIdentity.Read.All',
    'AgentIdentity.DeleteRestore.All',
    'AgentIdentityBlueprint.Read.All',
    'AgentIdentityBlueprint.DeleteRestore.All',
    'Application.ReadWrite.All'
)

$outputs = Read-EntraOutputs $EntraOutputsPath
if ($outputs.tenantId -ne $TenantId -or $outputs.prefix -cne $Prefix) {
    throw 'Outputs tenant/prefix do not exactly match the cleanup request.'
}

$uris = Get-AgentGraphUris
foreach ($definition in Get-AgentBlueprintDefinitions) {
    $expected = Get-PropertyValue $outputs.agentIdentities $definition.Key
    if (-not $expected) { throw "Provisioning output is missing agent '$($definition.Key)'." }
    $agent = Invoke-AgentGraph GET "$($uris.V1)/servicePrincipals/$($expected.servicePrincipalId)/microsoft.graph.agentIdentity?`$select=id,appId,displayName,agentIdentityBlueprintId,servicePrincipalType" -IgnoreStatus 404
    $expectedName = "$Prefix-agent-$($definition.Slug)"
    if (-not $agent) { continue }
    if (
        $agent.id -ne $expected.servicePrincipalId -or
        $agent.appId -ne $expected.appId -or
        $agent.displayName -cne $expectedName -or
        $agent.agentIdentityBlueprintId -ne $expected.blueprint.appId -or
        $agent.servicePrincipalType -ne 'ServiceIdentity'
    ) {
        throw "Agent '$expectedName' no longer matches its immutable provisioning record; refusing to delete it."
    }
    if ($PSCmdlet.ShouldProcess("$expectedName [$($agent.id)]", 'Delete verified Agent Identity')) {
        Invoke-AgentGraph DELETE "$($uris.V1)/servicePrincipals/$($agent.id)/microsoft.graph.agentIdentity" -IgnoreStatus 404 | Out-Null
    }
}

foreach ($definition in Get-AgentApiDefinitions) {
    $expected = Get-PropertyValue $outputs.protectedApis $definition.Key
    if (-not $expected) { throw "Provisioning output is missing protected API '$($definition.Key)'." }
    $application = Invoke-AgentGraph GET "$($uris.V1)/applications/$($expected.applicationObjectId)?`$select=id,appId,displayName,appRoles" -IgnoreStatus 404
    $expectedName = "$Prefix-api-$($definition.Slug)"
    if (-not $application) { continue }
    $expectedRoleId = New-DeterministicGuid "$TenantId|$Prefix|$($definition.Role)"
    if (
        $application.id -ne $expected.applicationObjectId -or
        $application.appId -ne $expected.appId -or
        $application.displayName -cne $expectedName -or
        $expectedRoleId -notin @($application.appRoles.id)
    ) {
        throw "Protected API '$expectedName' no longer matches its immutable provisioning record; refusing to delete it."
    }
    if ($PSCmdlet.ShouldProcess("$expectedName [$($application.id)]", 'Delete verified protected API application')) {
        Invoke-AgentGraph DELETE "$($uris.V1)/applications/$($application.id)" -IgnoreStatus 404 | Out-Null
    }
}

foreach ($definition in Get-AgentBlueprintDefinitions) {
    $expectedAgent = Get-PropertyValue $outputs.agentIdentities $definition.Key
    $expected = $expectedAgent.blueprint
    $blueprint = Invoke-AgentGraph GET "$($uris.V1)/applications/$($expected.objectId)/microsoft.graph.agentIdentityBlueprint?`$select=id,appId,displayName" -IgnoreStatus 404
    $expectedName = "$Prefix-agent-$($definition.Slug)-blueprint"
    if (-not $blueprint) { continue }
    if (
        $blueprint.id -ne $expected.objectId -or
        $blueprint.appId -ne $expected.appId -or
        $blueprint.displayName -cne $expectedName
    ) {
        throw "Blueprint '$expectedName' no longer matches its immutable provisioning record; refusing to delete it."
    }
    if ($PSCmdlet.ShouldProcess("$expectedName [$($blueprint.id)]", 'Delete verified Agent ID blueprint')) {
        Invoke-AgentGraph DELETE "$($uris.V1)/applications/$($blueprint.id)/microsoft.graph.agentIdentityBlueprint" -IgnoreStatus 404 | Out-Null
    }
}
