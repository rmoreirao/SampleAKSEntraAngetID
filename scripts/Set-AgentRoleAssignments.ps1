<#
.SYNOPSIS
Grants the sample's application permissions to its Agent Identities.
.DESCRIPTION
Idempotently grants Concierge -> MealPlan.Request, Concierge ->
Availability.Request, and Availability -> Inventory.Read. These app-role
assignments are tenant-wide application-permission/admin-consent records.
.PARAMETER EntraOutputsPath
Path to JSON emitted by New-EntraAgentIdResources.ps1.
.PARAMETER TenantId
Microsoft Entra tenant ID.
.PARAMETER ConfirmAdminConsent
Required acknowledgement that the operator intends to create admin-consent
app-role assignments.
.EXAMPLE
Connect-MgGraph -TenantId $tenant -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
.\scripts\Set-AgentRoleAssignments.ps1 -EntraOutputsPath .\entra-outputs.json -TenantId $tenant -ConfirmAdminConsent
.NOTES
The delegated scopes require tenant admin consent. For assignments whose
principal is an Agent Identity, use a directory role supported by Microsoft
Graph, such as Agent ID Administrator.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$EntraOutputsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId,
    [Parameter(Mandatory)][switch]$ConfirmAdminConsent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\EntraAgentId.Common.psm1') -Force -DisableNameChecking
if (-not $ConfirmAdminConsent) { throw 'Pass -ConfirmAdminConsent to acknowledge tenant-wide application permission grants.' }
Assert-AgentGraphContext -TenantId $TenantId -RequiredScopes @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All')

$outputs = Read-EntraOutputs $EntraOutputsPath
if ($outputs.tenantId -ne $TenantId) { throw 'The Entra outputs tenant does not match -TenantId.' }

$allGranted = $true
foreach ($definition in Get-AgentApiDefinitions) {
    $caller = $outputs.agentIdentities.($definition.Caller)
    $resource = $outputs.protectedApis.($definition.Key)
    if (-not $caller -or -not $resource) { throw "Outputs are missing the '$($definition.Role)' caller or resource." }

    $graphUris = Get-AgentGraphUris
    $assignmentsUri = "$($graphUris.V1)/servicePrincipals/$($caller.servicePrincipalId)/appRoleAssignments"
    $existing = Invoke-AgentGraph GET $assignmentsUri
    $match = @($existing.value | Where-Object {
        $_.resourceId -eq $resource.servicePrincipalId -and $_.appRoleId -eq $resource.appRole.id
    })
    if ($match.Count -gt 0) {
        Write-Host "$($caller.displayName) already has $($definition.Role)."
        continue
    }
    if ($PSCmdlet.ShouldProcess($caller.displayName, "Grant admin consent for $($definition.Role)")) {
        Invoke-AgentGraph POST $assignmentsUri @{
            principalId = $caller.servicePrincipalId
            resourceId = $resource.servicePrincipalId
            appRoleId = $resource.appRole.id
        } | Out-Null
    } else {
        $allGranted = $false
    }
}

if (-not $WhatIfPreference -and $allGranted) {
    $outputs.adminConsent.appRoleAssignmentsGranted = $true
    $outputs.adminConsent | Add-Member -NotePropertyName grantedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $outputs | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EntraOutputsPath -Encoding utf8NoBOM
}
