using './main.bicep'

param apimName = 'ghcp-byok-apim-dev'
param apimPublisherName = 'GHCP BYOK'
param apimPublisherEmail = 'your-email@example.com'
param apimSkuName = 'Developer'
param apimSkuCapacity = 1
param foundryAccountName = 'your-foundry-account'
param foundryAccountSubscriptionId = '00000000-0000-0000-0000-000000000000'
param foundryAccountResourceGroup = 'your-foundry-resource-group'
param foundryBackendBaseUrl = 'https://your-foundry-account.openai.azure.com'
param foundryApiVersion = '2024-06-01'
param foundryDeploymentsApiVersion = '2023-03-15-preview'

// Optional: set the Foundry project name to also list that project's managed-compute
// deployments (e.g. Cohere/HuggingFace catalog models) in /models. Standard account
// deployments are listed either way; managed-compute ones only show when this is set.
// The APIM managed identity reads the project data plane with an ai.azure.com token.
param foundryProjectName = ''
param foundryProjectDeploymentsApiVersion = '2025-05-01'

// Optional: manually force model ids into /models for anything the live account/project
// queries don't return. Usually left empty once foundryProjectName is set.
param extraModelIds = []

// Optional: multi-account resilience. Leave empty (default) to use the single
// foundryBackendBaseUrl above. When set, requests route through a load-balanced pool named
// foundry-backend across every listed account, each with a circuit breaker that trips on
// 429/5xx and honors Retry-After. All accounts must expose the same deployment names; /models
// still lists the primary account only. subscriptionId/resourceGroup default to the primary's;
// priority sets failover order, weight sets share within a priority (both default to 1).
param foundryBackends = []
// Example:
// param foundryBackends = [
//   { accountName: 'aoai-eastus2', backendBaseUrl: 'https://aoai-eastus2.openai.azure.com', priority: 1, weight: 1 }
//   { accountName: 'aoai-westus',  backendBaseUrl: 'https://aoai-westus.openai.azure.com',  priority: 2, weight: 1 }
// ]

// Each org gets its own BYOK path (byok/<slug>), key, and policy. Slugs must be
// lowercase letters, numbers, and hyphens. Register each org's enterprise BYOK
// provider with base URL https://<apimName>.azure-api.net/byok/<slug> and the
// matching key below, then scope the registration to that org in GitHub AI controls.
param orgs = [
  'contoso-platform'
  'contoso-data'
  'contoso-mobile'
]

// Keyed by org slug. Use strong, unique secrets and supply them from Key Vault or a
// secure params file rather than committing real values.
param orgKeys = {
  'contoso-platform': 'replace-with-a-strong-secret-key-1'
  'contoso-data': 'replace-with-a-strong-secret-key-2'
  'contoso-mobile': 'replace-with-a-strong-secret-key-3'
}

// Optional: per-org model allowlist, keyed by org slug -> the model ids that org may use.
// A listed org sees only these ids in /models and any chat/responses call naming another
// model is rejected with 403. Orgs omitted (or mapped to []) are unrestricted and see every
// discovered model. Use the deployment id (the value clients pass as `model`).
param orgModels = {
  'contoso-platform': [ 'gpt-5.6-sol' ]
  'contoso-data': [ 'cohere-north-mini-code' ]
}

// Optional: models that only accept the default Chat Completions temperature. APIM rewrites
// any client-supplied temperature to 1 for these deployment ids and leaves other models unchanged.
param defaultTemperatureModelIds = []

// Optional: per-org throttling. Limits are counted independently per org slug.
param perOrgRateLimitCalls = 300
param perOrgRateLimitRenewalPeriod = 60

// Optional: per-org AI token governance (applied only to /chat/completions and /responses via
// the native llm-token-limit policy). tokensPerMinuteDefault/monthlyTokenQuotaDefault set the
// baseline for every org; the *Override maps raise or lower it per org. 0 disables that limit.
// Exceeding TPM returns 429; exceeding the monthly quota returns 403 until the month resets (UTC).
param tokensPerMinuteDefault = 0
param orgTokensPerMinute = {
  'contoso-platform': 50000
}
param monthlyTokenQuotaDefault = 0
param orgMonthlyTokenQuota = {
  'contoso-data': 5000000
}

// Optional: observability + per-org token metrics. deployObservability stands up Log Analytics
// and Application Insights (or reuses an existing workspace via logAnalyticsWorkspaceId) and wires
// an APIM logger + diagnostic with custom metrics enabled. enableTokenMetrics then emits per-org
// token counts (dimensions: byokOrg, model, API ID, Operation ID). Prompt/completion bodies are
// never logged. Leave deployObservability = false to skip all of this.
param deployObservability = false
param logAnalyticsWorkspaceId = ''
param logAnalyticsWorkspaceName = ''
param appInsightsName = ''
param enableTokenMetrics = false
// Off by default: token metrics reach App Insights customMetrics via the logger without it. Enable
// only to publish to the Azure Monitor custom-metric store, where the built-in role id resolves.
param grantMetricsPublisherRole = false

// Optional: Azure AI Content Safety prompt moderation (llm-content-safety) on /chat/completions
// and /responses. deployContentSafety stands up a Content Safety resource and grants the APIM
// identity Cognitive Services User; or set contentSafetyEndpoint to reuse an existing one (grant
// the role yourself). Enable per org via contentSafetyEnabledDefault + orgContentSafetyEnabled.
// shieldPrompt turns on jailbreak/prompt-injection detection; thresholds reject at or above the
// given severity (scale = contentSafetyOutputType). This complements the WAF, which sees bytes,
// not intent. Tune thresholds against real coding prompts to control false positives.
param deployContentSafety = false
param contentSafetyEndpoint = ''
param contentSafetyName = ''
param contentSafetyEnabledDefault = false
param orgContentSafetyEnabled = {
  'contoso-platform': true
}
param contentSafetyShieldPrompt = true
param contentSafetyOutputType = 'FourSeverityLevels'
param contentSafetyHateThreshold = 4
param contentSafetySelfHarmThreshold = 4
param contentSafetySexualThreshold = 4
param contentSafetyViolenceThreshold = 4
param contentSafetyBlocklists = []

// Optional: semantic caching (llm-semantic-cache) on /chat/completions only. deploySemanticCache
// stands up Azure Managed Redis with RediSearch + an APIM external cache and an embeddings backend
// (embeddingsDeploymentName must be a deployment on the Foundry account). Cache entries are
// partitioned per org and per model, so no tenant sees another's completions. Keep the score
// threshold conservative (>0.2 risks mismatches). Enable per org via semanticCacheEnabledDefault
// + orgSemanticCacheEnabled. /responses is intentionally not cached.
param deploySemanticCache = false
param redisCacheName = ''
param redisSku = 'Balanced_B0'
param embeddingsDeploymentName = ''
param semanticCacheScoreThreshold = '0.05'
param semanticCacheDurationSeconds = 120
param semanticCacheMaxMessageCount = 4
param semanticCacheEnabledDefault = false
param orgSemanticCacheEnabled = {
  'contoso-platform': true
}

// Optional: route selected orgs to a managed online (Cohere) endpoint instead of Foundry.
// Set cohereBackendBaseUrl to the endpoint base ending at the score API version, add the
// org slug(s) to cohereOrgs, and list the model id(s) to advertise on /models. The APIM
// managed identity authenticates with an AAD token (audience https://ml.azure.com); the
// endpoint owner must grant that identity a role with .../onlineEndpoints/score/action.
param cohereBackendBaseUrl = ''
param cohereBackendResource = 'https://ml.azure.com'
param cohereOrgs = []
param cohereModelIds = []

// Optional: route selected orgs to a managed-compute (Azure ML online) endpoint. Independent
// of the Cohere slot so it can carry its own audience. Same auth model as above: the APIM
// managed identity presents an AAD token (audience https://ml.azure.com) and the endpoint
// owner must grant that identity .../onlineEndpoints/score/action. For an endpoint in a
// foreign tenant, cross-tenant MI auth is not possible — use a key-based endpoint instead.
param mcBackendBaseUrl = ''
param mcBackendResource = 'https://ml.azure.com'
param mcOrgs = []
param mcModelIds = []

// Optional: front the public APIM instance with an Application Gateway (WAF_v2) and
// enforce that requests arrive through it. App Gateway injects the shared secret below
// as X-AppGw-Secret; APIM rejects any request without it (403), so the WAF can't be
// bypassed by calling the APIM hostname directly. Start WAF in Detection to observe
// false positives on chat prompts, then switch to Prevention.
param deployAppGateway = false
param appGwName = 'ghcp-byok-appgw-dev'
param appGwSharedSecret = 'replace-with-a-strong-random-secret'
param appGwWafMode = 'Detection'
param appGwCapacity = 1
// After the first deploy, optionally set this to the App Gateway public IP (from the
// appGatewayPublicIp output) to also restrict APIM inbound to that IP, then redeploy.
param appGwAllowedClientIp = ''

// HTTPS listener (optional). Terminate TLS at the gateway with an HTTP->HTTPS redirect.
// Supply the cert as a base64-encoded full-chain PFX (no Key Vault needed):
//   $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('fullchain.pfx'))
// A free 90-day Let's Encrypt cert (issued via Posh-ACME DNS-01) works well here.
param appGwEnableHttps = false
param appGwHttpsPfxBase64 = ''
param appGwHttpsPfxPassword = ''

