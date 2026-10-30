targetScope = 'resourceGroup'

@description('Region for a new NSG. Existing NSGs retain their location and tags.')
param location string = resourceGroup().location

@description('Name of the new or existing NSG in this resource group.')
@minLength(1)
@maxLength(80)
param nsgName string

@description('Reuse a governance-owned NSG and deploy only the application client rule. Otherwise, manage the complete custom rule collection of a new repository-owned NSG.')
param reuseExisting bool = false

@description('Address prefix of the dedicated Application Gateway subnet.')
param subnetAddressPrefix string

@description('Allow port 443 as well as the port 80 redirect when the gateway has an HTTPS listener.')
param enableHttps bool = false

@description('Tags applied only to a repository-owned NSG.')
param tags object = {}

var httpClientPorts = [
  '80'
]
var httpsClientPorts = [
  '80'
  '443'
]
var clientIngressRule = {
  name: 'AllowByokClientIngress'
  properties: {
    description: 'Public Copilot BYOK traffic to the Application Gateway listeners.'
    priority: 1000
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'Internet'
    sourcePortRange: '*'
    destinationAddressPrefix: subnetAddressPrefix
    destinationPortRanges: enableHttps ? httpsClientPorts : httpClientPorts
  }
}

resource managedNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (!reuseExisting) {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      clientIngressRule
      {
        name: 'AllowGatewayManager'
        properties: {
          description: 'Required Application Gateway v2 infrastructure traffic.'
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
    ]
  }
}

resource existingNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' existing = {
  name: nsgName
}

resource existingNsgClientRule 'Microsoft.Network/networkSecurityGroups/securityRules@2023-11-01' = if (reuseExisting) {
  parent: existingNsg
  name: clientIngressRule.name
  properties: clientIngressRule.properties
}

output networkSecurityGroupId string = existingNsg.id
