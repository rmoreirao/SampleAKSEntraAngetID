<#
.SYNOPSIS
Seeds the deployed Azure app with the expanded recipe and inventory data.

.DESCRIPTION
Runs the full sequence agreed in the seeding plan:

  1. Removes the temporary validate_seed_data.py if it is still present.
  2. Commits data/ so the image tag is traceable.
  3. Uploads data/recipes.json into the Azure AI Search 'recipes' index.
  4. Asserts the index really contains the expected document count.
  5. Reads the inventory actually running in AKS.
  6. Rebuilds and redeploys ONLY if that inventory is stale.
  7. Prints the public web address for an end-to-end check.

Recipes reach Azure through Azure AI Search. Inventory is baked into the
container image (COPY data ./data in docker/python.Dockerfile) and read at
/app/data, so it can only be refreshed by rebuilding and rolling out.

.NOTES
Requires: az (logged in), kubectl, git, and Search Service Contributor plus
Search Index Data Contributor on the Search service.
#>
[CmdletBinding()]
param(
    [string]$InfrastructureOutputsPath = (Join-Path $PSScriptRoot '..\infra-outputs.json'),
    [ValidateSet('sidecar', 'direct', 'mixed')][string]$AuthMode = 'sidecar',
    [int]$ExpectedRecipeCount = 28,
    [int]$ExpectedProductCount = 93,
    [string]$IndexName = 'recipes',
    # Rebuild and redeploy even if the running inventory already matches.
    [switch]$ForceRebuild,
    # Skip the git commit (ACR builds the working tree either way).
    [switch]$SkipCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error when
# $ErrorActionPreference is 'Stop'. This script inspects $LASTEXITCODE itself
# (and expects some probes to fail), so opt out where the variable exists.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$root = Split-Path -Parent $PSScriptRoot
$apiVersion = '2024-07-01'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message" -ForegroundColor Cyan }

$infra = Get-Content -LiteralPath $InfrastructureOutputsPath -Raw | ConvertFrom-Json
$endpoint = ([string]$infra.searchEndpoint).TrimEnd('/')
$resourceGroup = [string]$infra.resourceGroupName
$aksName = [string]$infra.aksName
$subscriptionId = [string]$infra.subscriptionId
foreach ($pair in @{ searchEndpoint = $endpoint; resourceGroupName = $resourceGroup
        aksName = $aksName; subscriptionId = $subscriptionId }.GetEnumerator()) {
    if (-not $pair.Value) { throw "infra-outputs.json is missing $($pair.Key)." }
}

# --- 0. Confirm the Azure CLI is pointed at the right subscription ---------
Write-Step 'Checking Azure CLI context'
$currentSubscription = az account show --query id -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Not logged in. Run: az login --tenant $($infra.tenantId)" }
if ($currentSubscription -ne $subscriptionId) {
    Write-Host "Switching subscription to $subscriptionId"
    az account set --subscription $subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the expected subscription.' }
}

# --- 1. Remove the temporary validation script ----------------------------
$tempScript = Join-Path $root 'validate_seed_data.py'
if (Test-Path -LiteralPath $tempScript) {
    Write-Step 'Removing temporary validate_seed_data.py'
    Remove-Item -LiteralPath $tempScript -Force
}

# --- 2. Commit the seed data ----------------------------------------------
if (-not $SkipCommit) {
    Write-Step 'Committing data/'
    # Include the temp script in the pathspec only when git already tracks it,
    # otherwise 'git add' fails with "pathspec did not match any files".
    # 'ls-files' without --error-unmatch always exits 0, so no failure probe.
    $paths = @('data')
    if (& git -C $root ls-files -- validate_seed_data.py) {
        $paths += 'validate_seed_data.py'
    }

    $pending = & git -C $root status --porcelain -- $paths
    if ($pending) {
        & git -C $root add -A -- $paths
        if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
        & git -C $root commit -m 'Expand seed recipes and inventory' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
        Write-Host 'Committed.'
    }
    else { Write-Host 'Nothing to commit; data/ is already clean.' }
}

# --- 3. Seed Azure AI Search ----------------------------------------------
Write-Step "Uploading recipes into the '$IndexName' index"
# These helper scripts use $ErrorActionPreference = 'Stop' and throw on failure,
# so a failure propagates here; $LASTEXITCODE would only reflect their last
# native call and must not be treated as their status.
& (Join-Path $PSScriptRoot 'Initialize-SampleData.ps1') `
    -InfrastructureOutputsPath $InfrastructureOutputsPath -IndexName $IndexName

# --- 4. Verify the index document count -----------------------------------
Write-Step 'Verifying the Search document count'
$searchToken = az account get-access-token --resource https://search.azure.com `
    --query accessToken -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $searchToken) { throw 'Could not acquire a Search token.' }
$countUri = '{0}/indexes/{1}/docs/$count?api-version={2}' -f $endpoint, $IndexName, $apiVersion
$indexedCount = Invoke-RestMethod -Uri $countUri -Headers @{ Authorization = "Bearer $searchToken" }
Write-Host "Index '$IndexName' now holds $indexedCount document(s)."
if ([int]$indexedCount -ne $ExpectedRecipeCount) {
    throw "Expected $ExpectedRecipeCount recipes in Search but found $indexedCount."
}

# --- 5. Read the inventory actually running in the cluster ----------------
Write-Step 'Reading the inventory running in AKS'
az aks get-credentials --resource-group $resourceGroup --name $aksName `
    --overwrite-existing --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not acquire AKS credentials.' }

$countExpression = "import json;print(len(json.load(open('/app/data/inventory.json'))))"
$runningCount = & kubectl exec "deployment/inventory-mcp" -n apps -- python -c $countExpression
if ($LASTEXITCODE -ne 0) { throw 'Could not read inventory.json from the inventory-mcp pod.' }
$runningCount = [int]($runningCount | Select-Object -Last 1)
Write-Host "inventory-mcp is serving $runningCount product(s)."

# --- 6. Rebuild and redeploy only when stale ------------------------------
if ($runningCount -eq $ExpectedProductCount -and -not $ForceRebuild) {
    Write-Host "Inventory is already current; skipping the rebuild and redeploy." -ForegroundColor Green
}
else {
    Write-Step 'Inventory is stale - rebuilding and redeploying'
    # A NEW tag is mandatory: the aks-agents containers set no imagePullPolicy,
    # so Kubernetes defaults to IfNotPresent for non-'latest' tags and would
    # keep serving the cached image if the tag were reused.
    $imageTag = 'llm-agents-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmm')
    Write-Host "Building image tag '$imageTag'..."
    & (Join-Path $PSScriptRoot 'Build-PushImages.ps1') `
        -InfrastructureOutputsPath $InfrastructureOutputsPath -ImageTag $imageTag

    & (Join-Path $PSScriptRoot 'Deploy-AksWorkloads.ps1') `
        -AuthMode $AuthMode -ImageTag $imageTag `
        -InfrastructureOutputsPath $InfrastructureOutputsPath

    $runningCount = & kubectl exec "deployment/inventory-mcp" -n apps -- python -c $countExpression
    if ($LASTEXITCODE -ne 0) { throw 'Could not re-read inventory.json after the rollout.' }
    $runningCount = [int]($runningCount | Select-Object -Last 1)
    if ($runningCount -ne $ExpectedProductCount) {
        throw "After redeploy the pod still serves $runningCount products, expected $ExpectedProductCount."
    }
    Write-Host "Redeployed; inventory-mcp now serves $runningCount products." -ForegroundColor Green
}

# --- 7. Point the operator at the running app -----------------------------
Write-Step 'Seeding complete'
$address = & kubectl get service web -n apps `
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}'
Write-Host "Recipes in Search : $indexedCount"
Write-Host "Products in AKS   : $runningCount"
if ($address) {
    Write-Host "Open http://$address and ask for something new, for example" -ForegroundColor Green
    Write-Host '  "a japanese dinner for two" or "brazilian fish stew"' -ForegroundColor Green
}
else {
    Write-Host 'The web LoadBalancer has no external address yet; check: kubectl get service web -n apps'
}
