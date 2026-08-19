<#
.SYNOPSIS
Builds reproducible Python and web images in Azure Container Registry.
#>
[CmdletBinding()]
param(
    [string]$InfrastructureOutputsPath = (Join-Path $PSScriptRoot '..\infra-outputs.json'),
    [string]$ImageTag,
    [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $InfrastructureOutputsPath -PathType Leaf)) {
    throw "Infrastructure outputs not found: $InfrastructureOutputsPath"
}
$infra = Get-Content -LiteralPath $InfrastructureOutputsPath -Raw | ConvertFrom-Json
$acrName = [string]$infra.acrName
if (-not $acrName) { throw 'infra-outputs.json is missing acrName.' }
if (-not $ImageTag) {
    $ImageTag = (git -C $root rev-parse --short=12 HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $ImageTag) {
        $ImageTag = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    }
}
if ($ImageTag -notmatch '^[A-Za-z0-9_.-]+$') { throw 'ImageTag contains invalid characters.' }

$cacheArgs = @()
if ($NoCache) { $cacheArgs += '--no-cache' }
foreach ($image in @(
    @{ Name = 'aks-agents'; File = 'docker/python.Dockerfile' },
    @{ Name = 'meal-web'; File = 'docker/web.Dockerfile' }
)) {
    Write-Host "Building $($image.Name):$ImageTag in $acrName..."
    & az acr build --registry $acrName --image "$($image.Name):$ImageTag" `
        --file $image.File @cacheArgs --only-show-errors $root
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $($image.Name)." }
}
Write-Host "Published image tag '$ImageTag'."
