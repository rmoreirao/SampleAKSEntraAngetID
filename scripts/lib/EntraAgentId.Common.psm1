Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep Graph roots and every Agent ID URI centralized. Agent ID operations use
# v1.0; Agent 365 registration deliberately uses its documented preview API.
$script:Graph = @{
    V1 = 'https://graph.microsoft.com/v1.0'
    Beta = 'https://graph.microsoft.com/beta'
    Blueprints = 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint'
    BlueprintPrincipals = 'https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal'
    AgentIdentities = 'https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity'
    AgentRegistrations = 'https://graph.microsoft.com/beta/copilot/agentRegistrations'
    TokenExchangeAudience = 'api://AzureADTokenExchange'
}

$script:BlueprintDefinitions = @(
    @{
        Key = 'concierge'
        Slug = 'concierge'
        Label = 'Concierge'
        Description = 'Coordinates meal planning and grocery availability across the supermarket agent system.'
        Streaming = $true
        SkillId = 'meal-orchestration'
        SkillName = 'Meal orchestration'
        SkillDescription = 'Coordinates recipe planning and product availability checks.'
    }
    @{
        Key = 'mealPlanner'
        Slug = 'meal-planner'
        Label = 'Meal Planner'
        Description = 'Selects grounded recipes and scales ingredient quantities for the requested meal.'
        Streaming = $false
        SkillId = 'meal-planning'
        SkillName = 'Meal planning'
        SkillDescription = 'Selects and scales recipes based on user preferences and constraints.'
    }
    @{
        Key = 'availability'
        Slug = 'availability'
        Label = 'Availability'
        Description = 'Checks authoritative inventory and ranks grounded ingredient substitutions.'
        Streaming = $false
        SkillId = 'availability-check'
        SkillName = 'Availability checking'
        SkillDescription = 'Checks stock and proposes inventory-grounded substitutions.'
    }
)

$script:ApiDefinitions = @(
    @{ Key = 'mealPlanner'; Slug = 'meal-planner'; Label = 'Meal Planner'; Role = 'MealPlan.Request'; Caller = 'concierge' }
    @{ Key = 'availability'; Slug = 'availability'; Label = 'Availability'; Role = 'Availability.Request'; Caller = 'concierge' }
    @{ Key = 'inventory'; Slug = 'inventory'; Label = 'Inventory'; Role = 'Inventory.Read'; Caller = 'availability' }
)

function Get-AgentBlueprintDefinitions { return $script:BlueprintDefinitions }
function Get-AgentApiDefinitions { return $script:ApiDefinitions }
function Get-AgentGraphUris { return $script:Graph }

function New-Agent365RegistrationBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)]$Agent,
        [Parameter(Mandatory)]$Outputs
    )

    return [ordered]@{
        displayName = $Agent.displayName
        description = $Definition.Description
        ownerIds = @($Outputs.ownerObjectId)
        createdBy = $Outputs.ownerObjectId
        sourceCreatedDateTime = $Outputs.generatedAtUtc
        sourceLastModifiedDateTime = $Outputs.generatedAtUtc
        sourceAgentId = $Agent.appId
        originatingStore = 'SampleAKSEntraAgentID'
        agentIdentityId = $Agent.appId
        agentIdentityBlueprintId = $Agent.blueprint.appId
        agentCard = [ordered]@{
            name = $Agent.displayName
            version = '1.0.0'
            description = $Definition.Description
            capabilities = [ordered]@{
                streaming = [bool]$Definition.Streaming
                pushNotifications = $false
            }
            defaultInputModes = @('text')
            defaultOutputModes = @('text')
            skills = @(
                [ordered]@{
                    id = $Definition.SkillId
                    name = $Definition.SkillName
                    description = $Definition.SkillDescription
                }
            )
        }
    }
}

function Get-Agent365Registration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistrationId)

    return Invoke-AgentGraph GET "$($script:Graph.AgentRegistrations)/$RegistrationId" -IgnoreStatus 404 -MaxAttempts 3
}

function Assert-Agent365Registration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Registration,
        [Parameter(Mandatory)]$ExpectedAgent,
        [Parameter(Mandatory)][string]$ExpectedRegistrationId
    )

    if (
        $Registration.id -ne $ExpectedRegistrationId -or
        $Registration.displayName -cne $ExpectedAgent.displayName -or
        $Registration.sourceAgentId -ne $ExpectedAgent.appId -or
        $Registration.agentIdentityId -ne $ExpectedAgent.appId -or
        $Registration.agentIdentityBlueprintId -ne $ExpectedAgent.blueprint.appId
    ) {
        throw "Agent 365 registration '$ExpectedRegistrationId' no longer matches its immutable provisioning record."
    }
}

function Write-JsonFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporaryPath = Join-Path $directory ".$([System.IO.Path]::GetFileName($resolvedPath)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
        [System.IO.File]::Move($temporaryPath, $resolvedPath, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function ConvertTo-ODataLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-GraphStatusCode {
    param([Parameter(Mandatory)]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    $response = Get-PropertyValue $exception 'Response'
    $candidates = @(
        (Get-PropertyValue $exception 'ResponseStatusCode'),
        $(if ($response) { Get-PropertyValue $response 'StatusCode' }),
        (Get-PropertyValue $exception 'StatusCode')
    )
    foreach ($candidate in $candidates) {
        if ($null -ne $candidate) {
            try { return [int]$candidate } catch { }
        }
    }

    $errorDetails = Get-PropertyValue $ErrorRecord 'ErrorDetails'
    $detailMessage = if ($errorDetails) { Get-PropertyValue $errorDetails 'Message' } else { $null }
    if ($detailMessage) {
        try {
            $details = $detailMessage | ConvertFrom-Json
            if ($details.error.code -match 'Request_ResourceNotFound|ResourceNotFound') { return 404 }
        } catch { }
    }
    return $null
}

function Invoke-AgentGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body,
        [hashtable]$Headers,
        [int[]]$IgnoreStatus = @(),
        [int]$MaxAttempts = 1
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $arguments = @{
                Method = $Method
                Uri = $Uri
                ErrorAction = 'Stop'
                ContentType = 'application/json'
            }
            if ($null -ne $Body) {
                $arguments.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
            }
            if ($Headers) { $arguments.Headers = $Headers }
            return Invoke-MgGraphRequest @arguments
        } catch {
            $status = Get-GraphStatusCode -ErrorRecord $_
            if ($status -in $IgnoreStatus) { return $null }
            if ($attempt -lt $MaxAttempts -and $status -in @(404, 408, 429, 500, 502, 503, 504)) {
                Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 10))
                continue
            }
            $statusText = if ($null -eq $status) { 'unknown HTTP status' } else { "HTTP $status" }
            throw "Microsoft Graph $Method $Uri failed ($statusText): $($_.Exception.Message)"
        }
    }
}

function Assert-AgentGraphContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string[]]$RequiredScopes,
        [switch]$AllowAppOnly
    )

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication is required. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw "Connect first: Connect-MgGraph -TenantId '$TenantId' -Scopes '$($RequiredScopes -join "','")'"
    }
    if ($context.TenantId -ne $TenantId) {
        throw "Connected Graph tenant '$($context.TenantId)' does not match requested tenant '$TenantId'."
    }
    if (-not $AllowAppOnly -and $context.AuthType -eq 'AppOnly') {
        throw 'This script expects delegated authentication because sponsor/owner setup and Agent ID role checks are operator-account operations.'
    }
    if ($context.AuthType -ne 'AppOnly') {
        $missing = @($RequiredScopes | Where-Object { $_ -notin $context.Scopes })
        if ($missing.Count -gt 0) {
            throw "The Graph connection lacks delegated scopes: $($missing -join ', '). Reconnect and obtain tenant admin consent where required."
        }
    }
}

function Resolve-DirectoryObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string[]]$AllowedTypes = @()
    )

    if ($Identity -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $object = Invoke-AgentGraph GET "$($script:Graph.V1)/directoryObjects/${Identity}?`$select=id"
        if ($AllowedTypes.Count -gt 0) {
            $objectType = Get-PropertyValue $object '@odata.type'
            if (-not $objectType -or $objectType -notin $AllowedTypes) {
                throw "Directory object '$Identity' has unsupported type '$objectType'. Allowed: $($AllowedTypes -join ', ')."
            }
            if ($objectType -eq '#microsoft.graph.group') {
                $group = Invoke-AgentGraph GET "$($script:Graph.V1)/groups/${Identity}?`$select=id,groupTypes,membershipRule,isAssignableToRole"
                $isDynamic = -not [string]::IsNullOrWhiteSpace([string]$group.membershipRule)
                $isMicrosoft365 = 'Unified' -in @($group.groupTypes)
                if ($group.isAssignableToRole -or (-not $isDynamic -and -not $isMicrosoft365)) {
                    throw "Sponsor group '$Identity' must be a non-role-assignable dynamic or Microsoft 365 group."
                }
            }
        }
        return $object.id
    }
    $escaped = [Uri]::EscapeDataString($Identity)
    $user = Invoke-AgentGraph GET "$($script:Graph.V1)/users/${escaped}?`$select=id,userPrincipalName"
    if ($AllowedTypes.Count -gt 0 -and '#microsoft.graph.user' -notin $AllowedTypes) {
        throw "User principal name '$Identity' is not an allowed directory object type."
    }
    return $user.id
}

function Get-ExactCollectionItem {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$DisplayName,
        [string[]]$Select = @('id', 'appId', 'displayName')
    )
    $literal = ConvertTo-ODataLiteral $DisplayName
    $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
    $response = Invoke-AgentGraph GET "$Uri${separator}`$filter=displayName eq '$literal'&`$select=$($Select -join ',')"
    $matches = @($response.value | Where-Object displayName -CEQ $DisplayName)
    if ($matches.Count -gt 1) { throw "More than one object has deterministic display name '$DisplayName'; refusing to choose." }
    return $matches | Select-Object -First 1
}

function Add-DirectoryReference {
    param(
        [Parameter(Mandatory)][string]$ListUri,
        [Parameter(Mandatory)][string]$ObjectId
    )
    $existing = Invoke-AgentGraph GET $ListUri
    $items = @(Get-PropertyValue $existing 'value') | Where-Object { $null -ne $_ }
    $existingIds = @($items | ForEach-Object { Get-PropertyValue $_ 'id' } | Where-Object { $_ })
    if ($ObjectId -in $existingIds) { return }
    Invoke-AgentGraph POST "$ListUri/`$ref" @{
        '@odata.id' = "$($script:Graph.V1)/directoryObjects/$ObjectId"
    } | Out-Null
}

function New-DeterministicGuid {
    param([Parameter(Mandatory)][string]$Value)
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))
    $bytes = [byte[]]::new(16)
    [Array]::Copy($hash, $bytes, 16)
    $bytes[7] = ($bytes[7] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    return [Guid]::new($bytes).ToString()
}

function Get-JsonValue {
    param([Parameter(Mandatory)]$Value)
    $wrapped = Get-PropertyValue $Value 'value'
    if ($null -ne $wrapped) { return $wrapped }
    return $Value
}

function Get-InfraIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Infrastructure,
        [Parameter(Mandatory)][string]$Key
    )
    $root = Get-JsonValue $Infrastructure
    $identitiesValue = Get-PropertyValue $root 'identities'
    if ($null -eq $identitiesValue) {
        $identitiesValue = Get-PropertyValue $root 'workloadIdentities'
    }
    $workloads = if ($null -ne $identitiesValue) { Get-JsonValue $identitiesValue } else { $root }
    $identityValue = Get-PropertyValue $workloads $Key
    if ($null -eq $identityValue) {
        throw "Infrastructure outputs do not contain workload identity '$Key'."
    }
    $identity = Get-JsonValue $identityValue
    $nestedProperties = Get-PropertyValue $identity 'properties'
    $properties = if ($nestedProperties) { $nestedProperties } else { $identity }
    $principalId = @(
        (Get-PropertyValue $identity 'principalId'),
        (Get-PropertyValue $properties 'principalId')
    ) | Where-Object { $_ } | Select-Object -First 1
    $clientId = @(
        (Get-PropertyValue $identity 'clientId'),
        (Get-PropertyValue $properties 'clientId')
    ) | Where-Object { $_ } | Select-Object -First 1
    $resourceId = @(
        (Get-PropertyValue $identity 'resourceId'),
        (Get-PropertyValue $properties 'resourceId'),
        (Get-PropertyValue $identity 'id')
    ) | Where-Object { $_ } | Select-Object -First 1
    if (-not $principalId -or -not $clientId) {
        throw "Infrastructure workload identity '$Key' must expose non-secret principalId and clientId values."
    }
    return [ordered]@{
        principalId = "$principalId"
        clientId = "$clientId"
        resourceId = if ($resourceId) { "$resourceId" } else { $null }
    }
}

function Get-InfraOutputValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Infrastructure,
        [Parameter(Mandatory)][string[]]$Names
    )
    $root = Get-JsonValue $Infrastructure
    foreach ($name in $Names) {
        $value = Get-PropertyValue $root $name
        if ($null -ne $value) { return Get-JsonValue $value }
    }
    return $null
}

function Ensure-Blueprint {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$SponsorId,
        [Parameter(Mandatory)][string]$OwnerId
    )
    $blueprint = Get-ExactCollectionItem $script:Graph.Blueprints $DisplayName
    if (-not $blueprint) {
        $blueprint = Invoke-AgentGraph POST $script:Graph.Blueprints @{
            displayName = $DisplayName
            'sponsors@odata.bind' = @("$($script:Graph.V1)/directoryObjects/$SponsorId")
            'owners@odata.bind' = @("$($script:Graph.V1)/directoryObjects/$OwnerId")
        }
    }
    Add-DirectoryReference "$($script:Graph.V1)/applications/$($blueprint.id)/microsoft.graph.agentIdentityBlueprint/sponsors" $SponsorId
    Add-DirectoryReference "$($script:Graph.V1)/applications/$($blueprint.id)/microsoft.graph.agentIdentityBlueprint/owners" $OwnerId
    return $blueprint
}

function Ensure-BlueprintPrincipal {
    param(
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)][string]$OwnerId
    )
    $result = Invoke-AgentGraph GET "$($script:Graph.V1)/servicePrincipals?`$filter=appId eq '$($Blueprint.appId)'&`$select=id,appId,displayName"
    $principal = @($result.value) | Select-Object -First 1
    if (-not $principal) {
        $principal = Invoke-AgentGraph POST $script:Graph.BlueprintPrincipals @{ appId = $Blueprint.appId } -MaxAttempts 5
    }
    Add-DirectoryReference "$($script:Graph.V1)/servicePrincipals/$($principal.id)/owners" $OwnerId
    return $principal
}

function Ensure-ManagedIdentityFederation {
    param(
        [Parameter(Mandatory)][string]$BlueprintObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ManagedIdentityPrincipalId
    )
    $uri = "$($script:Graph.V1)/applications/$BlueprintObjectId/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials"
    $list = Invoke-AgentGraph GET $uri
    $existing = @($list.value | Where-Object name -CEQ $Name) | Select-Object -First 1
    $desired = @{
        name = $Name
        issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
        subject = $ManagedIdentityPrincipalId
        audiences = @($script:Graph.TokenExchangeAudience)
        description = 'Trust the Azure user-assigned managed identity as a credential.'
    }
    if (-not $existing) {
        return Invoke-AgentGraph POST $uri $desired
    }
    if ($existing.issuer -ne $desired.issuer -or $existing.subject -ne $desired.subject -or
        @($existing.audiences)[0] -ne $script:Graph.TokenExchangeAudience) {
        $update = @{
            issuer = $desired.issuer
            subject = $desired.subject
            audiences = $desired.audiences
            description = $desired.description
        }
        Invoke-AgentGraph PATCH "$uri/$($existing.id)" $update | Out-Null
        return Invoke-AgentGraph GET "$uri/$($existing.id)"
    }
    return $existing
}

function Ensure-AksServiceAccountFederation {
    param(
        [Parameter(Mandatory)][string]$BlueprintObjectId,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ServiceAccount
    )
    $uri = "$($script:Graph.V1)/applications/$BlueprintObjectId/microsoft.graph.agentIdentityBlueprint/federatedIdentityCredentials"
    $list = Invoke-AgentGraph GET $uri
    $existing = @($list.value | Where-Object name -CEQ $Name) | Select-Object -First 1
    $desired = @{
        name = $Name
        issuer = $Issuer
        subject = "system:serviceaccount:${Namespace}:${ServiceAccount}"
        audiences = @($script:Graph.TokenExchangeAudience)
        description = 'Trust the projected AKS ServiceAccount assertion for the Auth SDK sidecar.'
    }
    if (-not $existing) {
        return Invoke-AgentGraph POST $uri $desired
    }
    if ($existing.issuer -ne $desired.issuer -or $existing.subject -ne $desired.subject -or
        @($existing.audiences)[0] -ne $script:Graph.TokenExchangeAudience) {
        $update = @{
            issuer = $desired.issuer
            subject = $desired.subject
            audiences = $desired.audiences
            description = $desired.description
        }
        Invoke-AgentGraph PATCH "$uri/$($existing.id)" $update | Out-Null
        return Invoke-AgentGraph GET "$uri/$($existing.id)"
    }
    return $existing
}

function Ensure-AgentIdentity {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)]$Blueprint,
        [Parameter(Mandatory)][string]$SponsorId,
        [Parameter(Mandatory)][string]$OwnerId
    )
    $agent = Get-ExactCollectionItem $script:Graph.AgentIdentities $DisplayName @(
        'id', 'appId', 'displayName', 'agentIdentityBlueprintId', 'servicePrincipalType'
    )
    if ($agent -and $agent.agentIdentityBlueprintId -ne $Blueprint.appId) {
        throw "Agent identity '$DisplayName' belongs to a different blueprint; refusing to mutate it."
    }
    if (-not $agent) {
        $agent = Invoke-AgentGraph POST $script:Graph.AgentIdentities @{
            displayName = $DisplayName
            agentIdentityBlueprintId = $Blueprint.appId
            'sponsors@odata.bind' = @("$($script:Graph.V1)/directoryObjects/$SponsorId")
        } -MaxAttempts 5
    }
    $base = "$($script:Graph.V1)/servicePrincipals/$($agent.id)/microsoft.graph.agentIdentity"
    Add-DirectoryReference "$base/sponsors" $SponsorId
    Add-DirectoryReference "$base/owners" $OwnerId
    return $agent
}

function Ensure-ProtectedApi {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$RoleValue,
        [Parameter(Mandatory)][string]$OwnerId,
        [Parameter(Mandatory)][string]$RoleSeed
    )
    $application = Get-ExactCollectionItem "$($script:Graph.V1)/applications" $DisplayName @(
        'id', 'appId', 'displayName', 'appRoles', 'identifierUris'
    )
    $roleId = New-DeterministicGuid $RoleSeed
    $role = @{
        id = $roleId
        allowedMemberTypes = @('Application')
        description = "Allows an agent identity to invoke $RoleValue."
        displayName = $RoleValue
        isEnabled = $true
        value = $RoleValue
    }
    if (-not $application) {
        $application = Invoke-AgentGraph POST "$($script:Graph.V1)/applications" @{
            displayName = $DisplayName
            signInAudience = 'AzureADMyOrg'
            appRoles = @($role)
        }
    } else {
        $currentRoles = @(Get-PropertyValue $application 'appRoles')
        $matchingRole = @($currentRoles | Where-Object value -CEQ $RoleValue)
        if ($matchingRole.Count -gt 1) { throw "API '$DisplayName' has duplicate app role '$RoleValue'." }
        if ($matchingRole.Count -eq 0) {
            $roles = $currentRoles + @($role)
            Invoke-AgentGraph PATCH "$($script:Graph.V1)/applications/$($application.id)" @{ appRoles = $roles } | Out-Null
        } elseif ($matchingRole[0].id -ne $roleId) {
            throw "API '$DisplayName' already has '$RoleValue' with a non-deterministic ID; refusing to replace assignments."
        }
    }
    $identifierUri = "api://$($application.appId)"
    if ($identifierUri -notin @(Get-PropertyValue $application 'identifierUris')) {
        Invoke-AgentGraph PATCH "$($script:Graph.V1)/applications/$($application.id)" @{
            identifierUris = @($identifierUri)
        } | Out-Null
    }
    Add-DirectoryReference "$($script:Graph.V1)/applications/$($application.id)/owners" $OwnerId

    $spResult = Invoke-AgentGraph GET "$($script:Graph.V1)/servicePrincipals?`$filter=appId eq '$($application.appId)'&`$select=id,appId,displayName,appRoles"
    $servicePrincipal = @($spResult.value) | Select-Object -First 1
    if (-not $servicePrincipal) {
        $servicePrincipal = Invoke-AgentGraph POST "$($script:Graph.V1)/servicePrincipals" @{ appId = $application.appId } -MaxAttempts 5
    }
    Add-DirectoryReference "$($script:Graph.V1)/servicePrincipals/$($servicePrincipal.id)/owners" $OwnerId
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $servicePrincipal = Invoke-AgentGraph GET "$($script:Graph.V1)/servicePrincipals/$($servicePrincipal.id)?`$select=id,appId,displayName,appRoles"
        if ($roleId -in @($servicePrincipal.appRoles.id)) { break }
        if ($attempt -eq 5) {
            throw "App role '$RoleValue' did not propagate to service principal '$($servicePrincipal.id)'. Rerun the idempotent script."
        }
        Start-Sleep -Seconds (2 * $attempt)
    }
    return [ordered]@{
        application = $application
        servicePrincipal = $servicePrincipal
        appRoleId = $roleId
        appRoleValue = $RoleValue
        identifierUri = $identifierUri
    }
}

function Read-EntraOutputs {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Outputs file '$Path' does not exist." }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

Export-ModuleMember -Function *
