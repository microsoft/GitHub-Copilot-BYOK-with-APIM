using './main.bicep'

// Required: replace these values.
// Generate each org key and the separate gateway secret with either command:
// OpenSSL: openssl rand -hex 32
// PowerShell 7.2+:
// [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
// Run once per secret; reuse the values on redeployment unless intentionally rotating them.
param apimName = 'your-globally-unique-apim-name'
param apimPublisherEmail = 'your-email@example.com'
param foundryAccountName = 'your-foundry-account'
param foundryAccountSubscriptionId = '<foundry-subscription-id>'
param foundryAccountResourceGroup = 'your-foundry-resource-group'
param orgKeys = {
  'your-github-org': '<org-key>'
}
param appGwSharedSecret = '<gateway-secret>'

// Recommended setup: Application Gateway + WAF. Set false only for APIM-only deployments.
param deployAppGateway = true

// Inferred: orgs from orgKeys, appGwName from apimName, and the standard Foundry endpoint
// from foundryAccountName. Uncomment only for a nonstandard Foundry endpoint:
// param foundryBackendBaseUrl = 'https://your-custom-endpoint'

// HTTPS: after creating DNS and obtaining a password-protected full-chain PFX, supply both.
// HTTPS is enabled automatically when appGwHttpsPfxBase64 is set.
// param appGwHttpsPfxBase64 = '<base64-encoded-pfx>'
// param appGwHttpsPfxPassword = '<pfx-password>'

// Common overrides: uncomment only what you need.
// Choose a production APIM tier deliberately; Developer is for testing.
// param apimSkuName = 'StandardV2'

// Restrict which deployments this org may discover and call.
// param orgModels = {
//   'your-github-org': [ 'your-model-deployment' ]
// }

// Also discover an existing Foundry project's managed-compute deployments.
// param foundryProjectName = 'your-foundry-project'

// All parameters, defaults, dependencies, and cost notes: ../docs/parameters.md.
// Optional AI features remain off; examples and verification: ../docs/ai-gateway.md.
