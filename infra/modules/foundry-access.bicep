targetScope = 'resourceGroup'

@description('Microsoft Foundry / Azure OpenAI account name.')
param foundryAccountName string

@description('Principal ID for the APIM managed identity.')
param apimPrincipalId string

@description('Built-in role definition ID for Foundry data-plane access. Default is Foundry User.')
param roleDefinitionId string = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: foundryAccountName
}

resource apimRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryAccount
  name: guid(foundryAccount.id, apimPrincipalId, 'foundry-user')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}
