targetScope = 'resourceGroup'

param location string = resourceGroup().location
param appGwName string
param existingNsgName string = ''
param enableHttps bool = false
param tags object = {}

var vnetName = '${appGwName}-vnet'
var appGatewaySubnetName = 'appgw-subnet'
var appGatewaySubnetPrefix = '10.50.0.0/24'
var apimSubnetName = 'apim-subnet'
var apimSubnetPrefix = '10.50.1.0/24'
var privateEndpointSubnetName = 'private-endpoints-subnet'

module networkSecurityGroup 'app-gateway-nsg.bicep' = {
  name: 'appGatewayNsg'
  params: {
    location: location
    nsgName: empty(existingNsgName) ? '${appGwName}-nsg' : existingNsgName
    reuseExisting: !empty(existingNsgName)
    subnetAddressPrefix: appGatewaySubnetPrefix
    enableHttps: enableHttps
    tags: tags
  }
}

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${appGwName}-apim-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowApplicationGatewayHttps'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appGatewaySubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: apimSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowApiManagementControlPlane'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'ApiManagement'
          sourcePortRange: '*'
          destinationAddressPrefix: apimSubnetPrefix
          destinationPortRange: '3443'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: apimSubnetPrefix
          destinationPortRange: '6390'
        }
      }
      {
        name: 'AllowApimSubnetTraffic'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: apimSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: apimSubnetPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyOtherInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.50.0.0/16'
      ]
    }
    // Keep reserved subnets when disabling private mode, until APIM has detached.
    subnets: [
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: appGatewaySubnetPrefix
          networkSecurityGroup: {
            id: networkSecurityGroup.outputs.networkSecurityGroupId
          }
        }
      }
      {
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.50.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output appGatewaySubnetId string = '${vnet.id}/subnets/${appGatewaySubnetName}'
output apimSubnetId string = '${vnet.id}/subnets/${apimSubnetName}'
output privateEndpointSubnetId string = '${vnet.id}/subnets/${privateEndpointSubnetName}'
output networkSecurityGroupId string = networkSecurityGroup.outputs.networkSecurityGroupId
