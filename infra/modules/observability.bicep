targetScope = 'resourceGroup'

@description('Azure region for the observability resources.')
param location string

@description('Existing Log Analytics workspace resource id to reuse. When empty, a new workspace is created.')
param logAnalyticsWorkspaceId string = ''

@description('Name for the Log Analytics workspace created when no existing workspace id is supplied.')
param logAnalyticsWorkspaceName string = ''

@description('Application Insights resource name.')
param appInsightsName string

@description('APIM system-assigned managed identity principal id. Granted Monitoring Metrics Publisher when grantMetricsPublisher is true.')
param apimPrincipalId string = ''

@description('Grant the APIM managed identity Monitoring Metrics Publisher on the Application Insights resource so it can emit custom token metrics.')
param grantMetricsPublisher bool = false

@description('Optional tags applied to deployed resources.')
param tags object = {}

var createWorkspace = empty(logAnalyticsWorkspaceId)
// Monitoring Metrics Publisher built-in role.
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4751-bf13-2c14e6f13a70'

resource newWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (createWorkspace) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: createWorkspace ? newWorkspace.id : logAnalyticsWorkspaceId
  }
}

resource metricsPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantMetricsPublisher && !empty(apimPrincipalId)) {
  scope: appInsights
  name: guid(appInsights.id, apimPrincipalId, monitoringMetricsPublisherRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
@description('Application Insights connection string used to configure the APIM logger.')
output appInsightsConnectionString string = appInsights.properties.ConnectionString
