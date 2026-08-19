param location string
param prefix string

resource concierge 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-concierge-id'
  location: location
}

resource mealPlanner 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-meal-planner-id'
  location: location
}

resource availability 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-availability-id'
  location: location
}

resource inventoryMcp 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-inventory-mcp-id'
  location: location
}

output names object = {
  concierge: concierge.name
  mealPlanner: mealPlanner.name
  availability: availability.name
  inventoryMcp: inventoryMcp.name
}

output concierge object = {
  clientId: concierge.properties.clientId
  principalId: concierge.properties.principalId
  resourceId: concierge.id
}

output mealPlanner object = {
  clientId: mealPlanner.properties.clientId
  principalId: mealPlanner.properties.principalId
  resourceId: mealPlanner.id
}

output availability object = {
  clientId: availability.properties.clientId
  principalId: availability.properties.principalId
  resourceId: availability.id
}

output inventoryMcp object = {
  clientId: inventoryMcp.properties.clientId
  principalId: inventoryMcp.properties.principalId
  resourceId: inventoryMcp.id
}

output identities object = {
  concierge: {
    clientId: concierge.properties.clientId
    principalId: concierge.properties.principalId
    resourceId: concierge.id
  }
  mealPlanner: {
    clientId: mealPlanner.properties.clientId
    principalId: mealPlanner.properties.principalId
    resourceId: mealPlanner.id
  }
  availability: {
    clientId: availability.properties.clientId
    principalId: availability.properties.principalId
    resourceId: availability.id
  }
  inventoryMcp: {
    clientId: inventoryMcp.properties.clientId
    principalId: inventoryMcp.properties.principalId
    resourceId: inventoryMcp.id
  }
}
