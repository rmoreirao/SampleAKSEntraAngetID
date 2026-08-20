<#
.SYNOPSIS
Registers the sample's existing Agent IDs in the Microsoft Agent 365 registry.
.DESCRIPTION
Creates governance and discovery records for the three blueprint-backed agents
using the preview Microsoft Graph Agent Registration API. Successful
registration IDs are checkpointed immediately in the non-secret Entra outputs
file so reruns can verify and reuse them without creating duplicates.
.PARAMETER EntraOutputsPath
Non-secret output written by New-EntraAgentIdResources.ps1.
.PARAMETER TenantId
Microsoft Entra tenant ID.
.EXAMPLE
Connect-MgGraph -TenantId $tenant -Scopes 'AgentRegistration.ReadWrite.All'
.\scripts\Register-Agent365Resources.ps1 -EntraOutputsPath .\entra-outputs.json -TenantId $tenant
.NOTES
The Agent Registration API is a preview /beta API and isn't supported for
production applications.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$EntraOutputsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\EntraAgentId.Common.psm1') -Force -DisableNameChecking
Assert-AgentGraphContext -TenantId $TenantId -RequiredScopes @('AgentRegistration.ReadWrite.All')

$outputs = Read-EntraOutputs $EntraOutputsPath
if ($outputs.tenantId -ne $TenantId) {
    throw "Outputs tenant '$($outputs.tenantId)' does not match requested tenant '$TenantId'."
}
if (-not $outputs.ownerObjectId -or -not $outputs.generatedAtUtc) {
    throw 'Entra outputs are missing ownerObjectId or generatedAtUtc required for Agent 365 registration.'
}

$agent365 = Get-PropertyValue $outputs 'agent365'
if (-not $agent365) {
    $agent365 = [pscustomobject][ordered]@{
        apiVersion = 'beta'
        registrations = [pscustomobject][ordered]@{}
    }
    $outputs | Add-Member -MemberType NoteProperty -Name agent365 -Value $agent365
}
$registrations = Get-PropertyValue $agent365 'registrations'
if (-not $registrations) {
    $registrations = [pscustomobject][ordered]@{}
    if ($agent365.PSObject.Properties['registrations']) {
        $agent365.registrations = $registrations
    } else {
        $agent365 | Add-Member -MemberType NoteProperty -Name registrations -Value $registrations
    }
}

foreach ($definition in Get-AgentBlueprintDefinitions) {
    $agent = Get-PropertyValue $outputs.agentIdentities $definition.Key
    if (-not $agent -or -not $agent.appId -or -not $agent.blueprint.appId) {
        throw "Entra outputs are missing Agent ID or blueprint identifiers for '$($definition.Key)'."
    }

    $recorded = Get-PropertyValue $registrations $definition.Key
    if ($recorded) {
        if (-not $recorded.id) {
            throw "Recorded Agent 365 registration '$($definition.Key)' has no registration ID."
        }
        $existing = Get-Agent365Registration $recorded.id
        if (-not $existing) {
            throw "Recorded Agent 365 registration '$($recorded.id)' no longer exists; refusing to create a possible duplicate."
        }
        Assert-Agent365Registration -Registration $existing -ExpectedAgent $agent -ExpectedRegistrationId $recorded.id
        Write-Host "Reused verified Agent 365 registration '$($recorded.id)' for '$($agent.displayName)'."
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($agent.displayName, 'Create Agent 365 registry entry')) { continue }
    $body = New-Agent365RegistrationBody -Definition $definition -Agent $agent -Outputs $outputs
    # Don't retry an ambiguous POST response because the API has no idempotency key.
    $created = Invoke-AgentGraph POST (Get-AgentGraphUris).AgentRegistrations -Body $body
    if (-not $created.id) {
        throw "Agent 365 did not return a registration ID for '$($agent.displayName)'."
    }

    $registration = Get-Agent365Registration $created.id
    if (-not $registration) {
        throw "Agent 365 registration '$($created.id)' could not be read back after creation."
    }
    Assert-Agent365Registration -Registration $registration -ExpectedAgent $agent -ExpectedRegistrationId $created.id

    $record = [pscustomobject][ordered]@{
        id = $created.id
        displayName = $agent.displayName
        sourceAgentId = $agent.appId
        agentIdentityId = $agent.appId
        agentIdentityBlueprintId = $agent.blueprint.appId
        registeredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $registrations | Add-Member -MemberType NoteProperty -Name $definition.Key -Value $record
    $outputs.schemaVersion = [Math]::Max([int]$outputs.schemaVersion, 2)
    $dependencies = @(Get-PropertyValue $outputs 'betaGraphDependencies')
    if ('copilot/agentRegistrations' -notin $dependencies) {
        $updatedDependencies = @($dependencies + 'copilot/agentRegistrations')
        if ($outputs.PSObject.Properties['betaGraphDependencies']) {
            $outputs.betaGraphDependencies = $updatedDependencies
        } else {
            $outputs | Add-Member -MemberType NoteProperty -Name betaGraphDependencies -Value $updatedDependencies
        }
    }
    Write-JsonFileAtomic -Value $outputs -Path $EntraOutputsPath
    Write-Host "Registered '$($agent.displayName)' as '$($created.id)' and updated '$EntraOutputsPath'."
}
