param location string
param logAnalyticsName string
param appInsightsName string
param telemetryPrincipalIds array
param monitoringMetricsPublisherRoleDefinitionId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource telemetryPublishers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in telemetryPrincipalIds: {
  name: guid(appInsights.id, principalId, monitoringMetricsPublisherRoleDefinitionId)
  scope: appInsights
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleDefinitionId)
  }
}]

output logAnalyticsResourceId string = workspace.id
output applicationInsightsResourceId string = appInsights.id
output applicationInsightsConnectionString string = appInsights.properties.ConnectionString
