<#
.SYNOPSIS
Creates the Azure AI Search recipes index and uploads the sample recipes.
.NOTES
The signed-in operator needs Search Service Contributor and Search Index Data Contributor.
#>
[CmdletBinding()]
param(
    [string]$InfrastructureOutputsPath = (Join-Path $PSScriptRoot '..\infra-outputs.json'),
    [string]$IndexName = 'recipes',
    [string]$RecipesPath = (Join-Path $PSScriptRoot '..\data\recipes.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$infra = Get-Content -LiteralPath $InfrastructureOutputsPath -Raw | ConvertFrom-Json
$endpoint = ([string]$infra.searchEndpoint).TrimEnd('/')
if (-not $endpoint) { throw 'infra-outputs.json is missing searchEndpoint.' }
$recipes = @(Get-Content -LiteralPath $RecipesPath -Raw | ConvertFrom-Json)
$token = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire an Azure AI Search token.' }
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$apiVersion = '2024-07-01'

$index = @{
    name = $IndexName
    fields = @(
        @{ name = 'id'; type = 'Edm.String'; key = $true; searchable = $false; filterable = $true },
        @{ name = 'name'; type = 'Edm.String'; searchable = $true; filterable = $true },
        @{ name = 'description'; type = 'Edm.String'; searchable = $true },
        @{ name = 'servings'; type = 'Edm.Int32'; filterable = $true },
        @{ name = 'ingredients'; type = 'Collection(Edm.ComplexType)'; fields = @(
            @{ name = 'name'; type = 'Edm.String'; searchable = $true },
            @{ name = 'quantity'; type = 'Edm.Double'; filterable = $true },
            @{ name = 'unit'; type = 'Edm.String'; searchable = $true }
        )},
        @{ name = 'instructions'; type = 'Collection(Edm.String)'; searchable = $true },
        @{ name = 'tags'; type = 'Collection(Edm.String)'; searchable = $true; filterable = $true; facetable = $true }
    )
    semantic = @{
        configurations = @(@{
            name = 'recipes-semantic'
            prioritizedFields = @{
                titleField = @{ fieldName = 'name' }
                prioritizedContentFields = @(@{ fieldName = 'description' }, @{ fieldName = 'instructions' })
                prioritizedKeywordsFields = @(@{ fieldName = 'tags' })
            }
        })
    }
}
$indexJson = $index | ConvertTo-Json -Depth 20
Invoke-RestMethod -Method Put -Uri "$endpoint/indexes/$IndexName`?api-version=$apiVersion" -Headers $headers -Body $indexJson | Out-Null

$documents = @($recipes | ForEach-Object {
    $document = [ordered]@{ '@search.action' = 'mergeOrUpload' }
    foreach ($property in $_.PSObject.Properties) { $document[$property.Name] = $property.Value }
    $document
})
$body = @{ value = $documents } | ConvertTo-Json -Depth 20
$result = Invoke-RestMethod -Method Post -Uri "$endpoint/indexes/$IndexName/docs/index`?api-version=$apiVersion" -Headers $headers -Body $body
$failed = @($result.value | Where-Object { -not $_.status })
if ($failed.Count) { throw "Azure AI Search rejected $($failed.Count) sample documents." }
Write-Host "Initialized '$IndexName' with $($documents.Count) recipes."
