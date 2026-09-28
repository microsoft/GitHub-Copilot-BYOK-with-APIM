targetScope = 'resourceGroup'

@description('Azure region for APIM and supporting resources.')
param location string = resourceGroup().location

@description('Name of the API Management instance.')
param apimName string

@description('APIM publisher display name.')
param apimPublisherName string = 'GHCP BYOK'

@description('APIM publisher contact email.')
param apimPublisherEmail string

@allowed([
  'Developer'
  'Basic'
  'BasicV2'
  'Standard'
  'StandardV2'
  'Premium'
  'PremiumV2'
])
param apimSkuName string = 'Developer'

@minValue(1)
param apimSkuCapacity int = 1

@description('Microsoft Foundry / Azure OpenAI resource name.')
param foundryAccountName string

@description('Subscription that contains the Foundry resource. Defaults to the APIM deployment subscription.')
param foundryAccountSubscriptionId string = subscription().subscriptionId

@description('Resource group that contains the Foundry resource.')
param foundryAccountResourceGroup string = resourceGroup().name

@description('Backend base URL, for example https://contoso.openai.azure.com.')
@minLength(1)
param foundryBackendBaseUrl string

@description('Optional: additional Foundry accounts to form a load-balanced, circuit-broken backend pool. Each entry: { accountName, backendBaseUrl, subscriptionId?, resourceGroup?, priority?, weight? }. When non-empty, requests route through a pool named foundry-backend and every listed account must expose equivalent deployment names; when empty (default), the single primary backend is used. /models still lists the primary account only.')
param foundryBackends array = []

@description('Azure OpenAI-compatible API version to send to the backend.')
param foundryApiVersion string = '2024-06-01'

@description('Data-plane API version used to list Foundry deployments for the /models endpoint.')
param foundryDeploymentsApiVersion string = '2023-03-15-preview'

@description('Foundry project name. When set, the /models endpoint also lists the project deployments (including managed-compute models like cohere-north-mini-code) via the AI Foundry project data plane, so they appear automatically without extraModelIds.')
param foundryProjectName string = ''

@description('API version for the AI Foundry project deployments listing used by /models.')
param foundryProjectDeploymentsApiVersion string = '2025-05-01'

@description('Extra model ids to merge into the live /models list. A manual safety net for deployments that are callable but not returned by the live deployment listings.')
param extraModelIds array = []

@description('Optional managed online endpoint (for example Cohere) base URL, ending at the score API version, for example https://<endpoint>.<region>.inference.ml.azure.com/score/v1. Orgs listed in cohereOrgs route here instead of Foundry.')
param cohereBackendBaseUrl string = ''

@description('AAD token audience for the managed online endpoint. Azure ML online endpoints accept tokens issued for https://ml.azure.com.')
param cohereBackendResource string = 'https://ml.azure.com'

@description('Org slugs that route to the managed online (Cohere) endpoint instead of Foundry. Must be a subset of orgs; requires cohereBackendBaseUrl.')
param cohereOrgs array = []

@description('Model ids advertised on /models for Cohere orgs. The managed endpoint does not expose a Foundry-style deployments listing, so ids are declared here.')
param cohereModelIds array = []

@description('Optional managed-compute (Azure ML online endpoint) base URL, ending at the score API version, for example https://<endpoint>.<region>.inference.ml.azure.com/score/v1. Orgs listed in mcOrgs route here. Distinct from the Cohere slot so it can use a different audience.')
param mcBackendBaseUrl string = ''

@description('AAD token audience for the managed-compute endpoint. Azure ML online endpoints accept tokens issued for https://ml.azure.com.')
param mcBackendResource string = 'https://ml.azure.com'

@description('Org slugs that route to the managed-compute endpoint. Must be a subset of orgs; requires mcBackendBaseUrl.')
param mcOrgs array = []

@description('Model ids advertised on /models for managed-compute orgs (the endpoint has no deployments listing).')
param mcModelIds array = []

@description('GitHub organization slugs that each get their own BYOK path (byok/<slug>), key, and policy. Use lowercase letters, numbers, and hyphens.')
param orgs array

@description('Optional per-org model allowlist, keyed by org slug -> array of model ids that org may see and call. An org listed here has its /models filtered to these ids and any chat/responses request for another model rejected with 403. Orgs omitted (or mapped to an empty array) are unrestricted.')
param orgModels object = {}

@description('Model deployment ids whose Chat Completions requests must use the default temperature of 1. Use for models that reject sampling temperatures sent by clients such as VS Code.')
param defaultTemperatureModelIds array = []

@description('Per-org client keys, keyed by org slug. Each org registers its own enterprise BYOK provider with this key and base URL https://<apim>.azure-api.net/byok/<slug>. Provide via a secure params file or Key Vault reference.')
@secure()
param orgKeys object

@description('Per-org rate limit: maximum calls per renewal period, counted independently per org.')
param perOrgRateLimitCalls int = 300

@description('Per-org rate limit renewal period, in seconds.')
param perOrgRateLimitRenewalPeriod int = 60

@description('Default tokens-per-minute (TPM) limit applied to every org unless overridden in orgTokensPerMinute. 0 disables the per-minute limit. Enforced only on /chat/completions and /responses; exceeding it returns 429.')
param tokensPerMinuteDefault int = 0

@description('Per-org tokens-per-minute overrides, keyed by org slug. Overrides tokensPerMinuteDefault for the listed orgs.')
param orgTokensPerMinute object = {}

@description('Default monthly token quota applied to every org unless overridden in orgMonthlyTokenQuota. 0 disables the quota. Exceeding it returns 403 until the month resets (UTC).')
param monthlyTokenQuotaDefault int = 0

@description('Per-org monthly token quota overrides, keyed by org slug.')
param orgMonthlyTokenQuota object = {}

@description('Deploy observability (Log Analytics + Application Insights) and wire an APIM Application Insights logger. Required for enableTokenMetrics.')
param deployObservability bool = false

@description('Existing Log Analytics workspace resource id to reuse for Application Insights. When empty and deployObservability is true, a new workspace is created.')
param logAnalyticsWorkspaceId string = ''

@description('Name for the Log Analytics workspace created when deployObservability is true and no workspace id is supplied. Defaults to <apimName>-logs.')
param logAnalyticsWorkspaceName string = ''

@description('Name for the Application Insights resource created when deployObservability is true. Defaults to <apimName>-ai.')
param appInsightsName string = ''

@description('Emit per-org LLM token metrics (llm-emit-token-metric) to Application Insights on /chat/completions and /responses. Requires deployObservability. Prompt and completion bodies are never logged.')
param enableTokenMetrics bool = false

@description('Grant the APIM identity Monitoring Metrics Publisher on Application Insights. Off by default: token metrics reach App Insights customMetrics via the logger connection string without it. Enable only to publish to the Azure Monitor custom-metric store, and only where the standard built-in role id resolves.')
param grantMetricsPublisherRole bool = false

@description('Deploy an Azure AI Content Safety resource and wire llm-content-safety prompt moderation. When false and contentSafetyEndpoint is empty, no content safety is applied.')
param deployContentSafety bool = false

@description('Existing Azure AI Content Safety endpoint (https://<name>.cognitiveservices.azure.com) to reuse instead of deploying one. The APIM identity must already have Cognitive Services User on that resource.')
param contentSafetyEndpoint string = ''

@description('Name for the Content Safety resource created when deployContentSafety is true. Defaults to <apimName>-cs.')
param contentSafetyName string = ''

@description('Enable content safety for every org by default. Per-org overrides in orgContentSafetyEnabled win. Applies only to /chat/completions and /responses.')
param contentSafetyEnabledDefault bool = false

@description('Per-org content safety enablement overrides, keyed by org slug (true/false).')
param orgContentSafetyEnabled object = {}

@description('Enable Prompt Shields (jailbreak / prompt-injection detection) in the content safety check.')
param contentSafetyShieldPrompt bool = true

@description('Content safety severity scale used for category thresholds.')
@allowed([
  'FourSeverityLevels'
  'EightSeverityLevels'
])
param contentSafetyOutputType string = 'FourSeverityLevels'

@description('Reject requests whose Hate severity is at or above this threshold. Range depends on contentSafetyOutputType.')
param contentSafetyHateThreshold int = 4

@description('Reject requests whose SelfHarm severity is at or above this threshold.')
param contentSafetySelfHarmThreshold int = 4

@description('Reject requests whose Sexual severity is at or above this threshold.')
param contentSafetySexualThreshold int = 4

@description('Reject requests whose Violence severity is at or above this threshold.')
param contentSafetyViolenceThreshold int = 4

@description('Optional Content Safety blocklist names to enforce on requests.')
param contentSafetyBlocklists array = []

@description('Deploy Azure Managed Redis (with RediSearch) + an APIM external cache and enable llm-semantic-cache on /chat/completions only. Requires an embeddings deployment on the Foundry account (embeddingsDeploymentName).')
param deploySemanticCache bool = false

@description('Name for the Azure Managed Redis cache created when deploySemanticCache is true. Defaults to <apimName>-redis.')
param redisCacheName string = ''

@description('Azure Managed Redis SKU for the semantic cache (for example Balanced_B0).')
param redisSku string = 'Balanced_B0'

@description('Embeddings deployment name on the Foundry account, used to vectorize prompts for semantic cache lookup. Required when deploySemanticCache is true.')
param embeddingsDeploymentName string = ''

@description('Semantic cache similarity score threshold (0.0-1.0, as a string). Lower is stricter; values above 0.2 risk cache mismatch. Start conservative.')
param semanticCacheScoreThreshold string = '0.05'

@description('Cached response TTL in seconds for llm-semantic-cache-store.')
param semanticCacheDurationSeconds int = 120

@description('Skip caching once a chat dialog has more than this many messages (long multi-turn threads cache poorly).')
param semanticCacheMaxMessageCount int = 4

@description('Enable semantic caching for every org by default. Per-org overrides in orgSemanticCacheEnabled win. Applies to /chat/completions only.')
param semanticCacheEnabledDefault bool = false

@description('Per-org semantic cache enablement overrides, keyed by org slug (true/false).')
param orgSemanticCacheEnabled object = {}

@description('Deploy an Application Gateway (WAF_v2) in front of the public APIM instance and enforce that requests arrive through it.')
param deployAppGateway bool = false

@description('Name of the Application Gateway (required when deployAppGateway is true).')
param appGwName string = ''

@description('Shared secret that App Gateway injects as X-AppGw-Secret and APIM validates. Generate a strong random value; provide via a secure params file or Key Vault.')
@secure()
param appGwSharedSecret string = ''

@description('WAF mode for the Application Gateway. Start in Detection for an LLM gateway, tune false positives on chat prompts, then switch to Prevention.')
@allowed([
  'Detection'
  'Prevention'
])
param appGwWafMode string = 'Detection'

@description('Instance count for the Application Gateway.')
@minValue(1)
param appGwCapacity int = 1

@description('Enable an HTTPS listener (443) on the App Gateway with HTTP->HTTPS redirect. Requires appGwHttpsPfxBase64 and appGwHttpsPfxPassword.')
param appGwEnableHttps bool = false

@description('Base64-encoded PFX (full chain) for the App Gateway HTTPS listener.')
@secure()
param appGwHttpsPfxBase64 string = ''

@description('Password protecting the PFX in appGwHttpsPfxBase64.')
@secure()
param appGwHttpsPfxPassword string = ''

@description('Optional: also restrict APIM inbound to this IP via ip-filter (typically the App Gateway public IP, known after the first deploy). Leave empty to rely on the X-AppGw-Secret header only.')
param appGwAllowedClientIp string = ''

@description('Optional tags applied to deployed resources.')
param tags object = {}

var openApiPath = 'openapi/byok-proxy.openapi.json'
var policyTemplatePath = 'policies/byok-proxy.xml'
var modelsPolicyPath = 'policies/models.xml'
var chatCompletionsPolicyPath = 'policies/chat-completions.xml'
var responsesPolicyPath = 'policies/responses.xml'
var appGwGuardPath = 'policies/appgw-guard.xml'
var staticModelsPath = 'policies/models-static.xml'
var backendId = 'foundry-backend'
var cohereBackendId = 'cohere-backend'
var mcBackendId = 'managed-compute-backend'
var openApiSpec = loadTextContent(openApiPath)
var policyTemplate = loadTextContent(policyTemplatePath)
var modelsPolicyXml = replace(loadTextContent(modelsPolicyPath), '__EXTRA_MODELS_JSON__', join(map(extraModelIds, m => '"${m}"'), ', '))
var defaultTemperatureModelIdsCsharp = join(map(defaultTemperatureModelIds, m => '"${m}"'), ', ')
var chatCompletionsPolicyXml = replace(loadTextContent(chatCompletionsPolicyPath), '__DEFAULT_TEMPERATURE_MODELS_JSON__', defaultTemperatureModelIdsCsharp)
var responsesPolicyXml = loadTextContent(responsesPolicyPath)
var appGwGuardTemplate = loadTextContent(appGwGuardPath)
var staticModelsTemplate = loadTextContent(staticModelsPath)
var normalizedFoundryBackendBaseUrl = endsWith(foundryBackendBaseUrl, '/') ? substring(foundryBackendBaseUrl, 0, length(foundryBackendBaseUrl) - 1) : foundryBackendBaseUrl
var foundryDeploymentsUrl = '${normalizedFoundryBackendBaseUrl}/openai/deployments?api-version=${foundryDeploymentsApiVersion}'
var foundryProjectDeploymentsUrl = empty(foundryProjectName) ? 'https://disabled.invalid' : 'https://${foundryAccountName}.services.ai.azure.com/api/projects/${foundryProjectName}/deployments?api-version=${foundryProjectDeploymentsApiVersion}'

// Cohere (managed online endpoint) routing. When cohereBackendBaseUrl is set, a second
// backend is created and orgs in cohereOrgs are pointed at it. Their /models response is
// a static list rendered from cohereModelIds, since the managed endpoint has no listing.
var deployCohereBackend = !empty(cohereBackendBaseUrl)
var cohereModelIdsCsharp = join(map(cohereModelIds, m => '"${m}"'), ', ')
var cohereStaticModelsXml = replace(staticModelsTemplate, '__MODELS_JSON__', cohereModelIdsCsharp)

// Managed-compute (Azure ML online endpoint) routing. Independent of the Cohere slot so it
// can carry its own audience (ml.azure.com). Orgs in mcOrgs route here with a static /models.
var deployMcBackend = !empty(mcBackendBaseUrl)
var mcModelIdsCsharp = join(map(mcModelIds, m => '"${m}"'), ', ')
var mcStaticModelsXml = replace(staticModelsTemplate, '__MODELS_JSON__', mcModelIdsCsharp)

// Optional ip-filter fragment, injected into the guard only when an allowed IP is supplied.
var appGwIpFilterXml = empty(appGwAllowedClientIp) ? '' : '<ip-filter action="allow"><address>${appGwAllowedClientIp}</address></ip-filter>'
// The App Gateway guard is injected into every org policy only when the feature is enabled;
// otherwise the __APPGW_GUARD__ token is stripped to an empty string.
var appGwGuardXml = deployAppGateway ? replace(appGwGuardTemplate, '__APPGW_IPFILTER__', appGwIpFilterXml) : ''

// ----- AI governance rendering (token limits + token metrics), applied to chat/responses only -----
// Per-org effective TPM and monthly quota; a per-org override wins over the global default.
var orgTpm = [for org in orgs: contains(orgTokensPerMinute, org) ? int(orgTokensPerMinute[org]) : tokensPerMinuteDefault]
var orgQuota = [for org in orgs: contains(orgMonthlyTokenQuota, org) ? int(orgMonthlyTokenQuota[org]) : monthlyTokenQuotaDefault]
var orgTpmAttr = [for (org, i) in orgs: orgTpm[i] > 0 ? ' tokens-per-minute="${orgTpm[i]}"' : '']
var orgQuotaAttr = [for (org, i) in orgs: orgQuota[i] > 0 ? ' token-quota="${orgQuota[i]}" token-quota-period="Monthly"' : '']
// llm-token-limit element rendered per org; empty when the org has neither a TPM nor a quota.
var orgTokenLimitXml = [for (org, i) in orgs: (orgTpm[i] > 0 || orgQuota[i] > 0) ? '<llm-token-limit counter-key="@((string)context.Variables[&quot;byokOrg&quot;])"${orgTpmAttr[i]}${orgQuotaAttr[i]} estimate-prompt-tokens="true" remaining-tokens-header-name="x-ratelimit-remaining-tokens" remaining-quota-tokens-header-name="x-ratelimit-remaining-quota-tokens" tokens-consumed-header-name="x-ratelimit-consumed-tokens" />' : '']
// llm-emit-token-metric element (constant across orgs); byokModel is captured in the API-level policy.
var tokenMetricXml = (deployObservability && enableTokenMetrics) ? '<llm-emit-token-metric namespace="byok-llm"><dimension name="byokOrg" value="@((string)context.Variables[&quot;byokOrg&quot;])" /><dimension name="model" value="@((string)context.Variables[&quot;byokModel&quot;])" /><dimension name="API ID" /><dimension name="Operation ID" /></llm-emit-token-metric>' : ''
// Content safety (llm-content-safety) rendered per org; empty for orgs where it's disabled.
var contentSafetyBackendId = 'content-safety-backend'
var useContentSafety = deployContentSafety || !empty(contentSafetyEndpoint)
var csBlocklistsXml = empty(contentSafetyBlocklists) ? '' : '<blocklists>${join(map(contentSafetyBlocklists, b => '<id>${b}</id>'), '')}</blocklists>'
var contentSafetyXml = '<llm-content-safety backend-id="${contentSafetyBackendId}" shield-prompt="${toLower(string(contentSafetyShieldPrompt))}"><categories output-type="${contentSafetyOutputType}"><category name="Hate" threshold="${contentSafetyHateThreshold}" /><category name="SelfHarm" threshold="${contentSafetySelfHarmThreshold}" /><category name="Sexual" threshold="${contentSafetySexualThreshold}" /><category name="Violence" threshold="${contentSafetyViolenceThreshold}" /></categories>${csBlocklistsXml}</llm-content-safety>'
var orgContentSafetyXml = [for org in orgs: (useContentSafety && (contains(orgContentSafetyEnabled, org) ? bool(orgContentSafetyEnabled[org]) : contentSafetyEnabledDefault)) ? contentSafetyXml : '']
// ----- Semantic cache (chat/completions only) -----
var embeddingsBackendId = 'embeddings-backend'
var useSemanticCache = deploySemanticCache
var orgCacheEnabled = [for org in orgs: useSemanticCache && (contains(orgSemanticCacheEnabled, org) ? bool(orgSemanticCacheEnabled[org]) : semanticCacheEnabledDefault)]
var orgCacheLookupXml = [for (org, i) in orgs: orgCacheEnabled[i] ? '<llm-semantic-cache-lookup score-threshold="${semanticCacheScoreThreshold}" embeddings-backend-id="${embeddingsBackendId}" embeddings-backend-auth="system-assigned" ignore-system-messages="true" max-message-count="${semanticCacheMaxMessageCount}"><vary-by>@((string)context.Variables[&quot;byokOrg&quot;])</vary-by><vary-by>@((string)context.Variables[&quot;byokModel&quot;])</vary-by></llm-semantic-cache-lookup>' : '']
var orgCacheStoreXml = [for (org, i) in orgs: orgCacheEnabled[i] ? '<llm-semantic-cache-store duration="${semanticCacheDurationSeconds}" />' : '']
// Token-limit + metric block used by /chat/completions (content-safety and cache injected separately there).
var orgTokenGovernanceXml = [for (org, i) in orgs: '${orgTokenLimitXml[i]}${tokenMetricXml}']
// Combined block for /responses (no caching): content-safety, then token-limit, then metric.
var orgAiGovernanceXml = [for (org, i) in orgs: '${orgContentSafetyXml[i]}${orgTokenLimitXml[i]}${tokenMetricXml}']

// ----- Foundry backend pool (optional multi-account resilience) -----
var useFoundryPool = !empty(foundryBackends)
// Pool members, normalized with per-entry defaults. Deployment names must match across members.
var foundryPoolMembersSpec = [for b in foundryBackends: {
  accountName: b.accountName
  baseUrl: endsWith(b.backendBaseUrl, '/') ? substring(b.backendBaseUrl, 0, length(b.backendBaseUrl) - 1) : b.backendBaseUrl
  subscriptionId: b.?subscriptionId ?? foundryAccountSubscriptionId
  resourceGroup: b.?resourceGroup ?? foundryAccountResourceGroup
  priority: int(b.?priority ?? 1)
  weight: int(b.?weight ?? 1)
}]
// RBAC targets: the single primary when no pool, else every pool member account.
var foundryRbacTargets = useFoundryPool ? map(foundryPoolMembersSpec, m => {
  accountName: m.accountName
  subscriptionId: m.subscriptionId
  resourceGroup: m.resourceGroup
}) : [
  {
    accountName: foundryAccountName
    subscriptionId: foundryAccountSubscriptionId
    resourceGroup: foundryAccountResourceGroup
  }
]

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: apimSkuName
    capacity: apimSkuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: apimPublisherName
    publisherEmail: apimPublisherEmail
  }
}

// Single Foundry backend (default). Replaced by a pool when foundryBackends is set.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (!useFoundryPool) {
  parent: apim
  name: backendId
  properties: {
    title: 'Microsoft Foundry'
    description: 'Foundry deployment reached with the APIM managed identity.'
    protocol: 'http'
    url: '${normalizedFoundryBackendBaseUrl}/openai/v1'
    resourceId: '${environment().resourceManager}subscriptions/${foundryAccountSubscriptionId}/resourceGroups/${foundryAccountResourceGroup}/providers/Microsoft.CognitiveServices/accounts/${foundryAccountName}'
    credentials: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Pool member backends (one per Foundry account), each with a circuit breaker that trips on
// 429/5xx and honors Retry-After so an overloaded account is briefly taken out of rotation.
resource foundryPoolMembers 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [for (m, i) in foundryPoolMembersSpec: if (useFoundryPool) {
  parent: apim
  name: '${backendId}-${i}'
  properties: {
    title: 'Microsoft Foundry pool member ${i}'
    description: 'Foundry deployment ${m.accountName} reached with the APIM managed identity.'
    protocol: 'http'
    url: '${m.baseUrl}/openai/v1'
    resourceId: '${environment().resourceManager}subscriptions/${m.subscriptionId}/resourceGroups/${m.resourceGroup}/providers/Microsoft.CognitiveServices/accounts/${m.accountName}'
    credentials: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
    circuitBreaker: {
      rules: [
        {
          name: 'foundryBreaker'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}]

// Load-balanced pool published under the canonical foundry-backend id, so the per-org policy
// contract (set-backend-service backend-id="foundry-backend") is unchanged.
resource foundryPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (useFoundryPool) {
  parent: apim
  name: backendId
  properties: {
    title: 'Microsoft Foundry pool'
    description: 'Load-balanced pool across ${length(foundryPoolMembersSpec)} Foundry account(s).'
    type: 'Pool'
    pool: {
      services: [for (m, i) in foundryPoolMembersSpec: {
        id: foundryPoolMembers[i].id
        priority: m.priority
        weight: m.weight
      }]
    }
  }
}

resource cohereBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (deployCohereBackend) {
  parent: apim
  name: cohereBackendId
  properties: {
    title: 'Cohere managed online endpoint'
    description: 'Azure ML managed online endpoint reached with the APIM managed identity (AAD token, audience https://ml.azure.com).'
    protocol: 'http'
    url: cohereBackendBaseUrl
    credentials: {
      managedIdentity: {
        resource: cohereBackendResource
      }
    }
  }
}

resource mcBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (deployMcBackend) {
  parent: apim
  name: mcBackendId
  properties: {
    title: 'Managed-compute online endpoint'
    description: 'Azure ML managed online endpoint reached with the APIM managed identity (AAD token, audience https://ml.azure.com). Requires the score/action role granted to the APIM MI on the endpoint.'
    protocol: 'http'
    url: mcBackendBaseUrl
    credentials: {
      managedIdentity: {
        resource: mcBackendResource
      }
    }
  }
}

resource foundryDeploymentsUrlNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'foundryDeploymentsUrl'
  properties: {
    displayName: 'foundryDeploymentsUrl'
    secret: false
    value: foundryDeploymentsUrl
  }
}

// Project deployments listing (AI Foundry data plane, ai.azure.com audience). Empty when no
// project is configured; the /models policy skips the extra call in that case.
resource foundryProjectDeploymentsUrlNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'foundryProjectDeploymentsUrl'
  properties: {
    displayName: 'foundryProjectDeploymentsUrl'
    secret: false
    value: foundryProjectDeploymentsUrl
  }
}

// One secret named value per org, holding that org's client key.
resource orgKeyNamedValues 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = [
  for org in orgs: {
    parent: apim
    name: 'byokKey-${org}'
    properties: {
      displayName: 'byokKey-${org}'
      secret: true
      value: orgKeys[org]
    }
  }
]

// Secret named value holding the App Gateway shared secret, validated in policy to block bypass.
resource appGwSecretNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = if (deployAppGateway) {
  parent: apim
  name: 'appGwSecret'
  properties: {
    displayName: 'appGwSecret'
    secret: true
    value: appGwSharedSecret
  }
}

// One API per org, published at byok/<org>. The org identity is the URL path.
resource orgApis 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = [
  for org in orgs: {
    parent: apim
    name: 'byok-${org}'
    properties: {
      displayName: 'BYOK Foundry Proxy - ${org}'
      path: 'byok/${org}'
      protocols: [
        'https'
      ]
      subscriptionRequired: false
      format: 'openapi+json'
      value: openApiSpec
    }
  }
]

// Per-org auth policy: the template is specialised with this org's key named value,
// slug, and rate-limit settings. A key issued to a different org fails the compare here.
resource orgApiPolicies 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = [
  for (org, i) in orgs: {
    parent: orgApis[i]
    name: 'policy'
    properties: {
      format: 'xml'
      value: replace(replace(replace(replace(replace(replace(replace(policyTemplate, '__APPGW_GUARD__', appGwGuardXml), '__BACKEND_ID__', contains(mcOrgs, org) ? mcBackendId : (contains(cohereOrgs, org) ? cohereBackendId : backendId)), '__ORG_KEY_NV__', '{{byokKey-${org}}}'), '__ORG_SLUG__', org), '__RATE_CALLS__', string(perOrgRateLimitCalls)), '__RATE_PERIOD__', string(perOrgRateLimitRenewalPeriod)), '__ALLOWED_MODELS_CSV__', contains(orgModels, org) ? join(orgModels[org], ',') : '')
    }
    dependsOn: [
      orgKeyNamedValues
      appGwSecretNamedValue
      foundryBackend
      foundryPoolMembers
      foundryPool
      cohereBackend
      mcBackend
    ]
  }
]

resource orgListModelsOperations 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' existing = [
  for (org, i) in orgs: {
    parent: orgApis[i]
    name: 'listModels'
  }
]

resource orgListModelsPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = [
  for (org, i) in orgs: {
    parent: orgListModelsOperations[i]
    name: 'policy'
    properties: {
      format: 'xml'
      value: replace(contains(mcOrgs, org) ? mcStaticModelsXml : (contains(cohereOrgs, org) ? cohereStaticModelsXml : modelsPolicyXml), '__ALLOWED_MODELS_CSV__', contains(orgModels, org) ? join(orgModels[org], ',') : '')
    }
    dependsOn: [
      orgKeyNamedValues
      foundryDeploymentsUrlNamedValue
      foundryProjectDeploymentsUrlNamedValue
      foundryBackend
      orgApiPolicies
    ]
  }
]

resource orgChatCompletionsOperations 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' existing = [
  for (org, i) in orgs: {
    parent: orgApis[i]
    name: 'createChatCompletion'
  }
]

resource orgChatCompletionsPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = [
  for (org, i) in orgs: {
    parent: orgChatCompletionsOperations[i]
    name: 'policy'
    properties: {
      format: 'xml'
      value: replace(replace(replace(replace(chatCompletionsPolicyXml, '__AI_CONTENT_SAFETY__', orgContentSafetyXml[i]), '__AI_CACHE_LOOKUP__', orgCacheLookupXml[i]), '__AI_TOKEN_GOVERNANCE__', orgTokenGovernanceXml[i]), '__AI_CACHE_STORE__', orgCacheStoreXml[i])
    }
    dependsOn: [
      orgApiPolicies
      contentSafetyBackend
      embeddingsBackend
      apimSemanticCache
    ]
  }
]

resource orgResponsesOperations 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' existing = [
  for (org, i) in orgs: {
    parent: orgApis[i]
    name: 'createResponse'
  }
]

resource orgResponsesPolicies 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = [
  for (org, i) in orgs: {
    parent: orgResponsesOperations[i]
    name: 'policy'
    properties: {
      format: 'xml'
      value: replace(responsesPolicyXml, '__AI_GOVERNANCE__', orgAiGovernanceXml[i])
    }
    dependsOn: [
      orgApiPolicies
      contentSafetyBackend
    ]
  }
]

// Grant the APIM managed identity Foundry data-plane access on every backing account
// (the single primary, or each pool member when a pool is configured).
module foundryAccess 'modules/foundry-access.bicep' = [for (t, i) in foundryRbacTargets: {
  name: 'foundryAccess-${i}'
  scope: resourceGroup(t.subscriptionId, t.resourceGroup)
  params: {
    foundryAccountName: t.accountName
    apimPrincipalId: apim.identity.principalId
  }
}]

// Optional observability: Log Analytics + Application Insights, an APIM Application Insights
// logger, and a service diagnostic with custom metrics enabled so per-org token metrics emit.
module observability 'modules/observability.bicep' = if (deployObservability) {
  name: 'observability'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    logAnalyticsWorkspaceName: empty(logAnalyticsWorkspaceName) ? '${apimName}-logs' : logAnalyticsWorkspaceName
    appInsightsName: empty(appInsightsName) ? '${apimName}-ai' : appInsightsName
    apimPrincipalId: apim.identity.principalId
    grantMetricsPublisher: grantMetricsPublisherRole
    tags: tags
  }
}

resource apimAppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = if (deployObservability) {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for BYOK LLM token metrics.'
    resourceId: observability!.outputs.appInsightsId
    credentials: {
      connectionString: observability!.outputs.appInsightsConnectionString
    }
  }
}

// metrics: true enables custom metrics required by llm-emit-token-metric. Request/response
// bodies are not captured (bytes: 0), so prompts and completions are never logged.
resource apimAppInsightsDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = if (deployObservability) {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimAppInsightsLogger!.id
    alwaysLog: 'allErrors'
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    frontend: {
      request: {
        body: {
          bytes: 0
        }
      }
      response: {
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: 0
        }
      }
      response: {
        body: {
          bytes: 0
        }
      }
    }
  }
}

// Optional Azure AI Content Safety resource + APIM backend for llm-content-safety prompt moderation.
module contentSafety 'modules/content-safety.bicep' = if (deployContentSafety) {
  name: 'contentSafety'
  params: {
    location: location
    contentSafetyName: empty(contentSafetyName) ? '${apimName}-cs' : contentSafetyName
    apimPrincipalId: apim.identity.principalId
    tags: tags
  }
}

resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (useContentSafety) {
  parent: apim
  name: contentSafetyBackendId
  properties: {
    title: 'Azure AI Content Safety'
    description: 'Content Safety endpoint called by the llm-content-safety policy with the APIM managed identity.'
    protocol: 'http'
    url: deployContentSafety ? contentSafety!.outputs.endpoint : contentSafetyEndpoint
    credentials: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Optional semantic cache: Azure Managed Redis (RediSearch) + APIM external cache + an
// embeddings backend. Enabled on /chat/completions only; /responses is intentionally excluded.
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2024-10-01' = if (useSemanticCache) {
  name: empty(redisCacheName) ? '${apimName}-redis' : redisCacheName
  location: location
  sku: {
    name: redisSku
  }
  tags: tags
}

// RediSearch requires the EnterpriseCluster policy and can only be added at create time.
resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2024-10-01' = if (useSemanticCache) {
  parent: redisEnterprise
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    modules: [
      {
        name: 'RediSearch'
      }
    ]
  }
}

// External cache backed by Azure Managed Redis. The access key is read inline and never output.
resource apimSemanticCache 'Microsoft.ApiManagement/service/caches@2023-05-01-preview' = if (useSemanticCache) {
  parent: apim
  name: 'default'
  properties: {
    description: 'Azure Managed Redis (RediSearch) semantic cache'
    connectionString: '${redisEnterprise!.properties.hostName}:10000,password=${redisDatabase!.listKeys().primaryKey},ssl=True,abortConnect=False'
    useFromLocation: 'default'
  }
}

// Embeddings backend used by llm-semantic-cache-lookup to vectorize prompts (MI auth).
resource embeddingsBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (useSemanticCache) {
  parent: apim
  name: embeddingsBackendId
  properties: {
    title: 'Azure OpenAI embeddings'
    description: 'Embeddings deployment used to vectorize prompts for semantic cache lookup.'
    protocol: 'http'
    url: '${normalizedFoundryBackendBaseUrl}/openai/deployments/${embeddingsDeploymentName}/embeddings'
    resourceId: '${environment().resourceManager}subscriptions/${foundryAccountSubscriptionId}/resourceGroups/${foundryAccountResourceGroup}/providers/Microsoft.CognitiveServices/accounts/${foundryAccountName}'
    credentials: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// Optional Application Gateway (WAF_v2) front door for the public APIM instance.
module appGateway 'modules/app-gateway.bicep' = if (deployAppGateway) {
  name: 'appGateway'
  params: {
    location: location
    appGwName: appGwName
    apimGatewayHost: '${apimName}.azure-api.net'
    sharedSecret: appGwSharedSecret
    wafMode: appGwWafMode
    capacity: appGwCapacity
    enableHttps: appGwEnableHttps
    httpsPfxBase64: appGwHttpsPfxBase64
    httpsPfxPassword: appGwHttpsPfxPassword
    tags: tags
  }
  dependsOn: [
    apim
  ]
}

output apimGatewayUrl string = 'https://${apimName}.azure-api.net'
output orgProxyBasePaths array = [
  for org in orgs: {
    org: org
    basePath: 'https://${apimName}.azure-api.net/byok/${org}'
    modelsUrl: 'https://${apimName}.azure-api.net/byok/${org}/models'
  }
]
output backendCompletionUrl string = '${normalizedFoundryBackendBaseUrl}/openai/v1/chat/completions?api-version=${foundryApiVersion}'
output appGatewayPublicIp string = deployAppGateway ? appGateway!.outputs.publicIpAddress : ''
output appGatewayFrontendUrl string = deployAppGateway ? appGateway!.outputs.frontendUrl : ''
output applicationInsightsName string = deployObservability ? observability!.outputs.appInsightsName : ''
