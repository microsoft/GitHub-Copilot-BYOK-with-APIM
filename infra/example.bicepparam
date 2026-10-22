using './main.bicep'

// Required: replace these values.
// Generate each org key and the separate gateway secret with: openssl rand -hex 32
// Run once per secret; reuse the values on redeployment unless intentionally rotating them.
param apimName = 'your-globally-unique-apim-name'
param apimPublisherEmail = 'your-email@example.com'
param foundryAccountName = 'your-foundry-account'
param foundryAccountResourceGroup = 'your-foundry-resource-group'
param orgKeys = {
  'your-github-org': '<org-key>'
}
param appGwSharedSecret = '<gateway-secret>'

// Recommended setup: Application Gateway + WAF. Set false only for APIM-only deployments.
param deployAppGateway = true

// Inferred: orgs from orgKeys, appGwName from apimName, and the standard Foundry endpoint
// from foundryAccountName. Foundry defaults to the deployment subscription.
// Uncomment only when these defaults do not match your existing Foundry account:
// param foundryAccountSubscriptionId = '<foundry-subscription-id>'
// param foundryBackendBaseUrl = 'https://your-custom-endpoint'

// HTTPS: after creating DNS and obtaining a password-protected full-chain PFX, supply both.
// HTTPS is enabled automatically when appGwHttpsPfxBase64 is set.
// param appGwHttpsPfxBase64 = '<base64-encoded-pfx>'
// param appGwHttpsPfxPassword = '<pfx-password>'

// Optional features are off. Add only the overrides you need:
// - Per-org model allowlists and limits: main.bicep, "Organization access and request limits".
// - Token governance, telemetry, content safety, caching, resilience: ../docs/ai-gateway.md.
