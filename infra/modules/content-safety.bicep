targetScope = 'resourceGroup'

@description('Azure region for the Content Safety resource.')
param location string

@description('Content Safety (Cognitive Services) account name.')
param contentSafetyName string

@description('APIM system-assigned managed identity principal id. Granted Cognitive Services User so the llm-content-safety policy can call the resource with a managed-identity token.')
param apimPrincipalId string = ''

@description('Optional tags applied to the resource.')
param tags object = {}

// Cognitive Services User built-in role.
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource contentSafety 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: contentSafetyName
  location: location
  kind: 'ContentSafety'
  sku: {
    name: 'S0'
  }
  tags: tags
  identity: {
    type: 'None'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    customSubDomainName: toLower(contentSafetyName)
  }
}

resource contentSafetyUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  scope: contentSafety
  name: guid(contentSafety.id, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output endpoint string = contentSafety.properties.endpoint
output id string = contentSafety.id
