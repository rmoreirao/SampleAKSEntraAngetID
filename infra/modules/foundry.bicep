param location string
param accountName string
param projectName string
param chatDeployments array
param embeddingDeployments array
param inferencePrincipalIds array
param inferenceRoleDefinitionId string

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'PoC workload project'
    displayName: projectName
  }
}

resource chat 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for deployment in chatDeployments: {
  parent: account
  name: deployment.name
  sku: {
    name: deployment.skuName
    capacity: deployment.capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: deployment.modelName
      version: deployment.modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [
    project
  ]
}]

resource embeddings 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for deployment in embeddingDeployments: {
  parent: account
  name: deployment.name
  sku: {
    name: deployment.skuName
    capacity: deployment.capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: deployment.modelName
      version: deployment.modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [
    chat
  ]
}]

resource inferenceAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in inferencePrincipalIds: {
  name: guid(account.id, principalId, inferenceRoleDefinitionId)
  scope: account
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', inferenceRoleDefinitionId)
  }
}]

output accountResourceId string = account.id
output accountEndpoint string = account.properties.endpoint
output projectResourceId string = project.id
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output chatDeploymentResourceIds array = [for (deployment, index) in chatDeployments: chat[index].id]
output embeddingDeploymentResourceIds array = [for (deployment, index) in embeddingDeployments: embeddings[index].id]
