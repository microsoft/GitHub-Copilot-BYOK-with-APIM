targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string
param vnetId string
param subnetId string
@description('Primary and pool accounts, each with accountName, subscriptionId, and resourceGroup.')
param foundryAccounts array
param tags object = {}

var privateDnsZoneNames = [
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.services.ai.azure.com'
]

resource accounts 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = [for account in foundryAccounts: {
  name: account.accountName
  scope: resourceGroup(account.subscriptionId, account.resourceGroup)
}]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in privateDnsZoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

var privateDnsZoneConfigs = [for (zoneName, i) in privateDnsZoneNames: {
  name: zoneName
  properties: {
    privateDnsZoneId: privateDnsZones[i].id
  }
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zoneName, i) in privateDnsZoneNames: {
  parent: privateDnsZones[i]
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for (account, i) in foundryAccounts: {
  name: '${namePrefix}-foundry-pe-${i}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'foundry'
        properties: {
          privateLinkServiceId: accounts[i].id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}]

resource dnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (account, i) in foundryAccounts: {
  parent: privateEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: accounts[i].kind == 'OpenAI' ? [
      privateDnsZoneConfigs[0]
    ] : accounts[i].kind == 'AIServices' ? privateDnsZoneConfigs
      : fail('Private Foundry connections require OpenAI or AIServices accounts.')
  }
}]
