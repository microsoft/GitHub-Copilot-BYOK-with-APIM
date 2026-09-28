targetScope = 'resourceGroup'

@description('Azure region for the App Gateway and its network.')
param location string = resourceGroup().location

@description('Name of the Application Gateway.')
param appGwName string

@description('Name of the VNet created for the Application Gateway.')
param vnetName string = '${appGwName}-vnet'

@description('Address space for the App Gateway VNet.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Name of the dedicated App Gateway subnet.')
param subnetName string = 'appgw-subnet'

@description('Address prefix for the dedicated App Gateway subnet (v2 requires a subnet with no other resources, /24 recommended).')
param subnetAddressPrefix string = '10.50.0.0/24'

@description('Name of the public IP fronting the Application Gateway.')
param publicIpName string = '${appGwName}-pip'

@description('Public hostname of the APIM gateway, for example my-apim.azure-api.net. Used as the backend target and Host/SNI.')
param apimGatewayHost string

@description('Shared secret injected as the X-AppGw-Secret header on every forwarded request. APIM validates it to block direct (bypass) callers.')
@secure()
param sharedSecret string

@description('WAF mode. Start in Detection for an LLM gateway to observe false positives on chat prompts before enforcing.')
@allowed([
  'Detection'
  'Prevention'
])
param wafMode string = 'Detection'

@description('Instance count for the Application Gateway.')
@minValue(1)
param capacity int = 1

@description('Enable an HTTPS listener on 443 (with HTTP->HTTPS redirect). Requires httpsPfxBase64 and httpsPfxPassword.')
param enableHttps bool = false

@description('Base64-encoded PFX (full chain) for the HTTPS listener. Generate with [Convert]::ToBase64String([IO.File]::ReadAllBytes(pfxPath)).')
@secure()
param httpsPfxBase64 string = ''

@description('Password protecting the PFX in httpsPfxBase64.')
@secure()
param httpsPfxPassword string = ''

@description('Optional tags applied to deployed resources.')
param tags object = {}

var appGwId = resourceId('Microsoft.Network/applicationGateways', appGwName)
var frontendPortName = 'port-80'
var frontendIpName = 'appGwPublicFrontendIp'
var backendPoolName = 'apim-backend'
var backendHttpSettingsName = 'apim-https-settings'
var httpListenerName = 'http-listener'
var probeName = 'apim-status-probe'
var rewriteRuleSetName = 'inject-appgw-secret'
var routingRuleName = 'route-to-apim'
var httpsPortName = 'port-443'
var httpsListenerName = 'https-listener'
var sslCertName = 'appgw-ssl-cert'
var redirectConfigName = 'http-to-https'
var httpsRoutingRuleName = 'route-to-apim-https'
var redirectRoutingRuleName = 'redirect-http-to-https'

var frontendPortsAll = enableHttps ? [
  {
    name: frontendPortName
    properties: {
      port: 80
    }
  }
  {
    name: httpsPortName
    properties: {
      port: 443
    }
  }
] : [
  {
    name: frontendPortName
    properties: {
      port: 80
    }
  }
]

var sslCerts = enableHttps ? [
  {
    name: sslCertName
    properties: {
      data: httpsPfxBase64
      password: httpsPfxPassword
    }
  }
] : []

var httpListenerObj = {
  name: httpListenerName
  properties: {
    frontendIPConfiguration: {
      id: '${appGwId}/frontendIPConfigurations/${frontendIpName}'
    }
    frontendPort: {
      id: '${appGwId}/frontendPorts/${frontendPortName}'
    }
    protocol: 'Http'
  }
}

var httpsListenerObj = {
  name: httpsListenerName
  properties: {
    frontendIPConfiguration: {
      id: '${appGwId}/frontendIPConfigurations/${frontendIpName}'
    }
    frontendPort: {
      id: '${appGwId}/frontendPorts/${httpsPortName}'
    }
    protocol: 'Https'
    sslCertificate: {
      id: '${appGwId}/sslCertificates/${sslCertName}'
    }
  }
}

var listenersAll = enableHttps ? [
  httpListenerObj
  httpsListenerObj
] : [
  httpListenerObj
]

var redirectConfigs = enableHttps ? [
  {
    name: redirectConfigName
    properties: {
      redirectType: 'Permanent'
      targetListener: {
        id: '${appGwId}/httpListeners/${httpsListenerName}'
      }
      includePath: true
      includeQueryString: true
    }
  }
] : []

var httpBackendRule = {
  name: routingRuleName
  properties: {
    ruleType: 'Basic'
    priority: 100
    httpListener: {
      id: '${appGwId}/httpListeners/${httpListenerName}'
    }
    backendAddressPool: {
      id: '${appGwId}/backendAddressPools/${backendPoolName}'
    }
    backendHttpSettings: {
      id: '${appGwId}/backendHttpSettingsCollection/${backendHttpSettingsName}'
    }
    rewriteRuleSet: {
      id: '${appGwId}/rewriteRuleSets/${rewriteRuleSetName}'
    }
  }
}

var httpsBackendRule = {
  name: httpsRoutingRuleName
  properties: {
    ruleType: 'Basic'
    priority: 100
    httpListener: {
      id: '${appGwId}/httpListeners/${httpsListenerName}'
    }
    backendAddressPool: {
      id: '${appGwId}/backendAddressPools/${backendPoolName}'
    }
    backendHttpSettings: {
      id: '${appGwId}/backendHttpSettingsCollection/${backendHttpSettingsName}'
    }
    rewriteRuleSet: {
      id: '${appGwId}/rewriteRuleSets/${rewriteRuleSetName}'
    }
  }
}

var redirectRule = {
  name: redirectRoutingRuleName
  properties: {
    ruleType: 'Basic'
    priority: 110
    httpListener: {
      id: '${appGwId}/httpListeners/${httpListenerName}'
    }
    redirectConfiguration: {
      id: '${appGwId}/redirectConfigurations/${redirectConfigName}'
    }
  }
}

var routingRulesAll = enableHttps ? [
  httpsBackendRule
  redirectRule
] : [
  httpBackendRule
]

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = {
  name: '${appGwName}-waf'
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: wafMode
      requestBodyCheck: true
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2022-07-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
  }
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: capacity
    }
    gatewayIPConfigurations: [
      {
        name: 'appGwIpConfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: frontendIpName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: frontendPortsAll
    sslCertificates: sslCerts
    backendAddressPools: [
      {
        name: backendPoolName
        properties: {
          backendAddresses: [
            {
              fqdn: apimGatewayHost
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Https'
          host: apimGatewayHost
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: backendHttpSettingsName
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 120
          probe: {
            id: '${appGwId}/probes/${probeName}'
          }
        }
      }
    ]
    httpListeners: listenersAll
    redirectConfigurations: redirectConfigs
    rewriteRuleSets: [
      {
        name: rewriteRuleSetName
        properties: {
          rewriteRules: [
            {
              name: 'set-appgw-secret'
              ruleSequence: 100
              actionSet: {
                requestHeaderConfigurations: [
                  {
                    headerName: 'X-AppGw-Secret'
                    headerValue: sharedSecret
                  }
                ]
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: routingRulesAll
    firewallPolicy: {
      id: wafPolicy.id
    }
    forceFirewallPolicyAssociation: true
  }
}

output publicIpAddress string = publicIp.properties.ipAddress
output frontendUrl string = 'http://${publicIp.properties.ipAddress}'
output httpsEnabled bool = enableHttps
output appGatewayName string = appGateway.name
