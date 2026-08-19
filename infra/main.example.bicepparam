using './main.bicep'

param location = 'swedencentral'
param prefix = 'mealagentpoc'
param aksNodeVmSize = 'Standard_D4ds_v5'
param aksNodeCount = 2
param workloadNamespace = 'apps'

param chatDeployments = [
  {
    name: 'chat'
    modelName: 'gpt-4o-mini'
    modelVersion: '2024-07-18'
    skuName: 'GlobalStandard'
    capacity: 10
  }
]

param embeddingDeployments = [
  {
    name: 'embedding'
    modelName: 'text-embedding-3-small'
    modelVersion: '1'
    skuName: 'GlobalStandard'
    capacity: 10
  }
]
