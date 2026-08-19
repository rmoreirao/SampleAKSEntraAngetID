param issuerUrl string
param namespace string
param identityNames object

var workloads = [
  {
    key: 'concierge'
    serviceAccount: 'concierge'
  }
  {
    key: 'mealPlanner'
    serviceAccount: 'meal-planner'
  }
  {
    key: 'availability'
    serviceAccount: 'availability'
  }
  {
    key: 'inventoryMcp'
    serviceAccount: 'inventory-mcp'
  }
]

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = [for workload in workloads: {
  name: identityNames[workload.key]
}]

resource credentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for (workload, index) in workloads: {
  parent: identities[index]
  name: 'aks-${workload.serviceAccount}'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: issuerUrl
    subject: 'system:serviceaccount:${namespace}:${workload.serviceAccount}'
  }
}]
