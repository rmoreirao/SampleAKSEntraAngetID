targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short, globally unique prefix. Use lowercase letters and numbers.')
@minLength(3)
@maxLength(12)
param prefix string

@description('AKS Kubernetes version. Leave empty to use the platform default.')
param kubernetesVersion string = ''

@description('AKS region. Defaults to the resource group region but can use a nearby capacity fallback.')
param aksLocation string = location

@description('AKS system node VM size.')
param aksNodeVmSize string = 'Standard_D2s_v6'

@description('AKS system node count.')
@minValue(1)
param aksNodeCount int = 2

@description('Chat model deployments. Set to [] when the selected region does not support them.')
param chatDeployments array = [
  {
    name: 'chat'
    modelName: 'gpt-5-mini'
    modelVersion: '2025-08-07'
    skuName: 'GlobalStandard'
    capacity: 10
  }
]

@description('Embedding model deployments. Set to [] when the selected region does not support them.')
param embeddingDeployments array = [
  {
    name: 'embedding'
    modelName: 'text-embedding-3-small'
    modelVersion: '1'
    skuName: 'GlobalStandard'
    capacity: 10
  }
]

@description('Kubernetes namespace used by the workload service accounts.')
param workloadNamespace string = 'apps'

var compactPrefix = toLower(replace(prefix, '-', ''))
var globalSuffix = take(uniqueString(subscription().id, resourceGroup().id), 6)
var names = {
  logAnalytics: '${prefix}-law'
  appInsights: '${prefix}-appi'
  acr: '${compactPrefix}${globalSuffix}acr'
  aks: '${prefix}-aks'
  foundry: '${compactPrefix}${globalSuffix}ai'
  foundryProject: '${prefix}-project'
  search: '${compactPrefix}-${globalSuffix}-search'
}
var chatDeploymentNames = [for deployment in chatDeployments: deployment.name]
var embeddingDeploymentNames = [for deployment in embeddingDeployments: deployment.name]

// Keep all Azure built-in role IDs in one place.
var roleDefinitionIds = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  cognitiveServicesOpenAIUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsName: names.logAnalytics
    appInsightsName: names.appInsights
    telemetryPrincipalIds: [
      identities.outputs.concierge.principalId
      identities.outputs.mealPlanner.principalId
      identities.outputs.availability.principalId
      identities.outputs.inventoryMcp.principalId
    ]
    monitoringMetricsPublisherRoleDefinitionId: roleDefinitionIds.monitoringMetricsPublisher
  }
}

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    location: location
    acrName: names.acr
  }
}

module identities 'modules/identities.bicep' = {
  name: 'identities'
  params: {
    location: location
    prefix: prefix
  }
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    location: aksLocation
    aksName: names.aks
    kubernetesVersion: kubernetesVersion
    nodeVmSize: aksNodeVmSize
    nodeCount: aksNodeCount
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
    acrResourceId: acr.outputs.resourceId
    acrPullRoleDefinitionId: roleDefinitionIds.acrPull
  }
}

module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location: location
    accountName: names.foundry
    projectName: names.foundryProject
    chatDeployments: chatDeployments
    embeddingDeployments: embeddingDeployments
    inferencePrincipalIds: [
      identities.outputs.concierge.principalId
      identities.outputs.mealPlanner.principalId
      identities.outputs.availability.principalId
    ]
    inferenceRoleDefinitionId: roleDefinitionIds.cognitiveServicesOpenAIUser
  }
}

module search 'modules/search.bicep' = {
  name: 'search'
  params: {
    location: location
    searchName: names.search
    mealPlannerPrincipalId: identities.outputs.mealPlanner.principalId
    searchIndexDataReaderRoleDefinitionId: roleDefinitionIds.searchIndexDataReader
  }
}

module federatedCredentials 'modules/federated-credentials.bicep' = {
  name: 'federated-credentials'
  params: {
    issuerUrl: aks.outputs.oidcIssuerUrl
    namespace: workloadNamespace
    identityNames: identities.outputs.names
  }
}

output tenantId string = tenant().tenantId
output subscriptionId string = subscription().subscriptionId
output resourceGroupName string = resourceGroup().name
output aksName string = names.aks
output aksOidcIssuer string = aks.outputs.oidcIssuerUrl
output workloadNamespace string = workloadNamespace
output acrName string = names.acr
output acrLoginServer string = acr.outputs.loginServer
output foundryProjectEndpoint string = foundry.outputs.projectEndpoint
output foundryModelDeployments object = {
  chat: chatDeploymentNames
  embedding: embeddingDeploymentNames
}
output searchEndpoint string = search.outputs.endpoint
output searchName string = names.search
output applicationInsightsConnectionString string = monitoring.outputs.applicationInsightsConnectionString
output identities object = identities.outputs.identities

output logAnalyticsResourceId string = monitoring.outputs.logAnalyticsResourceId
output applicationInsightsResourceId string = monitoring.outputs.applicationInsightsResourceId
output acrResourceId string = acr.outputs.resourceId
output aksResourceId string = aks.outputs.resourceId
output aksFqdn string = aks.outputs.fqdn
output foundryResourceId string = foundry.outputs.accountResourceId
output foundryEndpoint string = foundry.outputs.accountEndpoint
output foundryProjectResourceId string = foundry.outputs.projectResourceId
output chatDeploymentResourceIds array = foundry.outputs.chatDeploymentResourceIds
output embeddingDeploymentResourceIds array = foundry.outputs.embeddingDeploymentResourceIds
output searchResourceId string = search.outputs.resourceId
