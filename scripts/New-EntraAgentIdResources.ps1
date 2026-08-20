<#
.SYNOPSIS
Creates the sample's Microsoft Entra Agent ID and protected API resources.
.DESCRIPTION
Idempotently creates three Agent ID blueprints, blueprint principals and agent
identities, configures sponsor/owner relationships, trusts the corresponding
Azure UAMI through federated credentials, and creates three protected APIs.

Agent ID operations use the currently documented Microsoft Graph v1.0
endpoints. Preview roots remain isolated in the helper module and are not used
implicitly. No secret is read or written. App-role grants are admin-consent
operations and run only when -GrantAdminConsent is supplied.
.PARAMETER InfrastructureOutputsPath
Path to non-secret deployment outputs. The preferred contract contains
tenantId and an identities object keyed concierge, mealPlanner, availability,
and inventoryMcp with clientId, principalId, and resourceId.
The earlier workloadIdentities wrapper remains accepted.
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER Sponsor
Sponsor user object ID or user principal name.
.PARAMETER Owner
Owner directory object ID or user principal name.
.PARAMETER Prefix
Deterministic sample prefix. Cleanup only targets exact names derived from it.
.PARAMETER OutputPath
Path for the generated non-secret Entra outputs JSON.
.PARAMETER GrantAdminConsent
Explicitly authorizes creation of app-role assignments.
.PARAMETER RegisterWithAgent365
Registers all three agents in the preview Microsoft Agent 365 registry after
the Entra output has been written.
.EXAMPLE
Connect-MgGraph -TenantId $tenant -Scopes 'AgentIdentityBlueprint.Read.All','AgentIdentityBlueprint.Create','AgentIdentityBlueprintPrincipal.Create','AgentIdentityBlueprint.AddRemoveCreds.All','AgentIdentity.Read.All','AgentIdentity.Create.All','AgentIdentity.ReadWrite.All','Application.ReadWrite.All','Directory.Read.All','AppRoleAssignment.ReadWrite.All'
.\scripts\New-EntraAgentIdResources.ps1 -InfrastructureOutputsPath .\infra-outputs.json -TenantId $tenant -Sponsor admin@contoso.com -Owner admin@contoso.com -Prefix mealagentpoc -GrantAdminConsent
.NOTES
The operator needs an Agent ID Administrator role (or other role documented for
each Agent ID operation) and an Application Administrator/Cloud Application
Administrator role for protected application ownership. Graph delegated scopes
also require tenant admin consent. Agent ID operations use v1.0; optional Agent
365 registration uses its documented preview endpoint.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InfrastructureOutputsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Sponsor,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Owner,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{1,39}$')][string]$Prefix,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\entra-outputs.json'),
    [switch]$GrantAdminConsent,
    [switch]$RegisterWithAgent365
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\EntraAgentId.Common.psm1') -Force -DisableNameChecking

$scopes = @(
    'AgentIdentityBlueprint.Read.All',
    'AgentIdentityBlueprint.Create',
    'AgentIdentityBlueprint.ReadWrite.All',
    'AgentIdentityBlueprintPrincipal.Create',
    'AgentIdentityBlueprintPrincipal.ReadWrite.All',
    'AgentIdentityBlueprint.AddRemoveCreds.All',
    'AgentIdentity.Read.All',
    'AgentIdentity.Create.All',
    'AgentIdentity.ReadWrite.All',
    'Application.Read.All',
    'Application.ReadWrite.All',
    'Directory.Read.All'
)
if ($GrantAdminConsent) { $scopes += 'AppRoleAssignment.ReadWrite.All' }
if ($RegisterWithAgent365) { $scopes += 'AgentRegistration.ReadWrite.All' }
Assert-AgentGraphContext -TenantId $TenantId -RequiredScopes $scopes

$infra = Get-Content -LiteralPath $InfrastructureOutputsPath -Raw | ConvertFrom-Json
$infrastructureTenantId = Get-InfraOutputValue $infra @('tenantId')
if ($infrastructureTenantId -and "$infrastructureTenantId" -ne $TenantId) {
    throw "Infrastructure outputs tenant '$infrastructureTenantId' does not match -TenantId '$TenantId'."
}
$sponsorId = Resolve-DirectoryObject $Sponsor -AllowedTypes @('#microsoft.graph.user', '#microsoft.graph.group')
$ownerId = Resolve-DirectoryObject $Owner
$aksOidcIssuer = [string](Get-InfraOutputValue $infra @('aksOidcIssuer'))
$workloadNamespace = [string](Get-InfraOutputValue $infra @('workloadNamespace'))
if (-not $workloadNamespace) { $workloadNamespace = 'apps' }
$agents = [ordered]@{}

foreach ($definition in Get-AgentBlueprintDefinitions) {
    $uami = Get-InfraIdentity -Infrastructure $infra -Key $definition.Key
    $blueprintName = "$Prefix-agent-$($definition.Slug)-blueprint"
    $agentName = "$Prefix-agent-$($definition.Slug)"
    if (-not $PSCmdlet.ShouldProcess($blueprintName, 'Provision Agent ID resources')) { continue }

    $blueprint = Ensure-Blueprint $blueprintName $sponsorId $ownerId
    $principal = Ensure-BlueprintPrincipal $blueprint $ownerId
    $fic = Ensure-ManagedIdentityFederation $blueprint.id $TenantId "$($definition.Slug)-uami" $uami.principalId
    $sidecarFic = $null
    $sidecarServiceAccounts = @{
        concierge = 'concierge'
        availability = 'availability'
    }
    if ($sidecarServiceAccounts.ContainsKey($definition.Key)) {
        if (-not $aksOidcIssuer) {
            throw 'Infrastructure outputs are missing aksOidcIssuer required by the Auth SDK sidecar.'
        }
        $sidecarFic = Ensure-AksServiceAccountFederation `
            $blueprint.id $aksOidcIssuer "$($definition.Slug)-aks-sidecar" `
            $workloadNamespace $sidecarServiceAccounts[$definition.Key]
    }
    $agent = Ensure-AgentIdentity $agentName $blueprint $sponsorId $ownerId
    $agents[$definition.Key] = [ordered]@{
        displayName = $agent.displayName
        appId = $agent.appId
        servicePrincipalId = $agent.id
        blueprint = [ordered]@{
            displayName = $blueprint.displayName
            appId = $blueprint.appId
            objectId = $blueprint.id
            principalId = $principal.id
        }
        workloadIdentity = $uami
        federatedCredential = [ordered]@{
            id = $fic.id
            name = $fic.name
            issuer = $fic.issuer
            subject = $fic.subject
            audiences = @($fic.audiences)
        }
        sidecarFederatedCredential = if ($sidecarFic) {
            [ordered]@{
                id = $sidecarFic.id
                name = $sidecarFic.name
                issuer = $sidecarFic.issuer
                subject = $sidecarFic.subject
                audiences = @($sidecarFic.audiences)
            }
        } else { $null }
    }
}

$apis = [ordered]@{}
foreach ($definition in Get-AgentApiDefinitions) {
    $displayName = "$Prefix-api-$($definition.Slug)"
    if (-not $PSCmdlet.ShouldProcess($displayName, 'Provision protected API')) { continue }
    $api = Ensure-ProtectedApi $displayName $definition.Role $ownerId "$TenantId|$Prefix|$($definition.Role)"
    $apis[$definition.Key] = [ordered]@{
        displayName = $displayName
        appId = $api.application.appId
        applicationObjectId = $api.application.id
        servicePrincipalId = $api.servicePrincipal.id
        identifierUri = $api.identifierUri
        audience = $api.identifierUri
        appRoleId = $api.appRoleId
        appRole = [ordered]@{ id = $api.appRoleId; value = $api.appRoleValue }
    }
}

$output = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    tenantId = $TenantId
    prefix = $Prefix
    sponsorObjectId = $sponsorId
    ownerObjectId = $ownerId
    graphApiVersion = 'v1.0'
    betaGraphDependencies = @()
    agentIdentities = $agents
    protectedApis = $apis
    adminConsent = [ordered]@{ appRoleAssignmentsGranted = $false }
}

$previousOutputs = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
    Read-EntraOutputs $OutputPath
} else {
    $null
}
if ($agents.Count -gt 0 -and $agents.Count -ne (Get-AgentBlueprintDefinitions).Count) {
    throw 'Agent provisioning was incomplete; refusing to write a partial output contract.'
}
if ($agents.Count -gt 0 -and $previousOutputs -and (Get-PropertyValue $previousOutputs 'agent365')) {
    if ($previousOutputs.tenantId -ne $TenantId -or $previousOutputs.prefix -cne $Prefix) {
        throw 'Existing Agent 365 registration records belong to a different tenant or prefix; refusing to overwrite them.'
    }
    foreach ($definition in Get-AgentBlueprintDefinitions) {
        $previousAgent = Get-PropertyValue $previousOutputs.agentIdentities $definition.Key
        $currentAgent = Get-PropertyValue $agents $definition.Key
        if (
            -not $previousAgent -or
            $previousAgent.appId -ne $currentAgent.appId -or
            $previousAgent.blueprint.appId -ne $currentAgent.blueprint.appId
        ) {
            throw "Existing Agent 365 registration '$($definition.Key)' belongs to different Agent ID resources; clean it up before reprovisioning."
        }
    }
    $output.schemaVersion = [Math]::Max([int]$output.schemaVersion, [int]$previousOutputs.schemaVersion)
    $output.betaGraphDependencies = @($previousOutputs.betaGraphDependencies)
    $output.agent365 = $previousOutputs.agent365
}

$outputDirectory = Split-Path -Parent $OutputPath
$outputWritten = $false
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write non-secret Entra outputs JSON')) {
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $output | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    $outputWritten = $true
}

if ($GrantAdminConsent -and $outputWritten) {
    & (Join-Path $PSScriptRoot 'Set-AgentRoleAssignments.ps1') -EntraOutputsPath $OutputPath -TenantId $TenantId -ConfirmAdminConsent
}
if ($RegisterWithAgent365 -and $outputWritten) {
    & (Join-Path $PSScriptRoot 'Register-Agent365Resources.ps1') `
        -EntraOutputsPath $OutputPath -TenantId $TenantId -Confirm:$false
}
if ($outputWritten) { Write-Host "Non-secret Entra outputs written to '$OutputPath'." }
