param location string
param searchName string
param mealPlannerPrincipalId string
param searchIndexDataReaderRoleDefinitionId string

resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    disableLocalAuth: true
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'enabled'
    replicaCount: 1
    semanticSearch: 'free'
  }
}

resource indexReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, mealPlannerPrincipalId, searchIndexDataReaderRoleDefinitionId)
  scope: search
  properties: {
    principalId: mealPlannerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReaderRoleDefinitionId)
  }
}

output resourceId string = search.id
output endpoint string = 'https://${search.name}.search.windows.net'
