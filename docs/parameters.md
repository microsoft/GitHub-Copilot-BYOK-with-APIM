# Deployment parameters

Complete reference for [the deployment template](../infra/main.bicep). Start with
[Getting started](getting-started.md) and the [small starter file](../infra/example.bicepparam);
add overrides only when you need them.

**Defaults apply when a parameter is omitted.** `Required` means there is no template default.
Some optional parameters become required when a feature is enabled; those dependencies are
noted below. `''` means an empty string. Secure values must stay out of source control and logs.

- [APIM and deployment](#apim-and-deployment)
- [Organizations and request limits](#organizations-and-request-limits)
- [Foundry and model discovery](#foundry-and-model-discovery)
- [Application Gateway and HTTPS](#application-gateway-and-https)
- [Token governance](#token-governance)
- [Observability](#observability)
- [Content safety](#content-safety)
- [Semantic caching](#semantic-caching)
- [Alternate backends](#alternate-backends)

## APIM and deployment

APIM is billed by tier and capacity. `Developer` is for testing, not production. The allowed
tiers are `Developer`, `Basic`, `BasicV2`, `Standard`, `StandardV2`, `Premium`, and `PremiumV2`;
availability and feature support depend on the tier and region.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `location` | string | `resourceGroup().location` | Region for APIM and supporting resources. |
| `apimName` | string | Required | Globally unique APIM instance name. |
| `apimPublisherName` | string | `'GHCP BYOK'` | Publisher display name. |
| `apimPublisherEmail` | string | Required | Publisher contact email. |
| `apimSkuName` | string | `'Developer'` | APIM tier; select a production tier deliberately. |
| `apimSkuCapacity` | int | `1` | Scale units; minimum `1`. More units increase cost. |
| `tags` | object | `{}` | Tags applied to deployed resources. |

## Organizations and request limits

Keys authorize organizations, not individual users. Each org gets a separate path and policy
without another gateway. Generate a unique key per org with `openssl rand -hex 32` and retain
it for redeployments. Use deployment names, not base model names, in model lists.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `orgKeys` | secure object | Required | Map of organization slug to gateway client key. Not a Foundry key or APIM subscription key. |
| `orgs` | array | `objectKeys(orgKeys)` | Slugs to deploy; override to select a subset. Requires at least one org and a key for each. Slugs use lowercase letters, numbers, and hyphens. |
| `orgModels` | object | `{}` | Map of slug to permitted deployment IDs. Filters discovery and rejects other models. Omitted orgs or empty arrays are unrestricted. |
| `defaultTemperatureModelIds` | array | `[]` | Deployments whose Chat Completions temperature must be normalized to `1`. |
| `perOrgRateLimitCalls` | int | `300` | Maximum requests per organization per renewal period. |
| `perOrgRateLimitRenewalPeriod` | int | `60` | Request-limit renewal period in seconds. |

For the identity boundary and key rotation, see the
[organization design](reference-architecture.md#per-organization-multi-tenant-byok).

## Foundry and model discovery

The template uses an existing Foundry account; it does not deploy the account or models.
APIM uses managed identity, not a Foundry API key. Role-assignment permissions are required
on every backing account, including accounts in other subscriptions.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `foundryAccountName` | string | Required | Existing Foundry / Azure OpenAI account name. |
| `foundryAccountSubscriptionId` | string | `subscription().subscriptionId` | Subscription containing the account. Override for cross-subscription access. |
| `foundryAccountResourceGroup` | string | `resourceGroup().name` | Resource group containing the account. Override when different from the gateway group. |
| `foundryBackendBaseUrl` | string | `'https://${foundryAccountName}.openai.azure.com'` | Standard Azure OpenAI endpoint; override for a different account endpoint. Must not be empty. |
| `foundryBackends` | array | `[]` | Optional load-balanced backend pool; see the member schema below. |
| `foundryProjectName` | string | `''` | Also discover project deployments, including managed-compute models. |
| `extraModelIds` | array | `[]` | Manually add callable deployment IDs missing from discovery. Does not deploy models or bypass allowlists. |
| `foundryDeploymentsApiVersion` | string | `'2023-03-15-preview'` | API version for account deployment discovery. |
| `foundryProjectDeploymentsApiVersion` | string | `'2025-05-01'` | API version for project deployment discovery. Used when a project is configured. |
| `foundryApiVersion` | string | `'2024-06-01'` | Included only in the `backendCompletionUrl` reference output. It does not configure inference requests. |

Inference uses `/openai/v1`; it does not need a dated API version. Leave discovery versions at
their defaults unless the discovery APIs require a change.

Each `foundryBackends` entry requires `accountName` and `backendBaseUrl`. Optional
`subscriptionId` and `resourceGroup` default to the primary account's settings; `priority` and
`weight` default to `1`. A nonempty array replaces the single backend with a pool and grants
APIM access to each member. All members must expose equivalent deployment names. Discovery
still uses the primary account and its configured project, not every pool member.

The pool creates no additional Foundry accounts, but model calls remain billable. For examples
and failover checks, see [backend resilience](ai-gateway.md#resilient-multi-foundry-pool).

## Application Gateway and HTTPS

Application Gateway WAF_v2 is enabled by default and adds gateway and public-IP charges.
APIM remains public; its secret-header policy is not network isolation.

Without a certificate, the gateway is HTTP-only for initial setup. Supply both PFX values before
connecting Copilot or sending keys. An explicit `appGwEnableHttps = false` overrides inference.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `deployAppGateway` | bool | `true` | Deploy the WAF gateway and enforce its secret header in APIM. Set `false` explicitly for APIM-only operation without WAF. |
| `appGwName` | string | `'${apimName}-appgw'` | Gateway name; preserve an existing override when upgrading. |
| `appGwSharedSecret` | secure string | `''` | Required when the gateway is enabled; at least 32 characters. Generate separately from org keys and retain for redeployments. |
| `appGwWafMode` | string | `'Detection'` | `Detection` records matches without blocking. Tune coding-prompt false positives before using `Prevention`. |
| `appGwCapacity` | int | `1` | WAF_v2 instance count; minimum `1`. More instances increase cost. |
| `appGwEnableHttps` | bool | `!empty(appGwHttpsPfxBase64)` | Enable port 443 and HTTP-to-HTTPS redirect. Requires the gateway and both certificate values. |
| `appGwHttpsPfxBase64` | secure string | `''` | Base64-encoded, full-chain PFX for the public hostname. Supplying it enables HTTPS by default. |
| `appGwHttpsPfxPassword` | secure string | `''` | Password for the PFX; required when HTTPS is enabled. |
| `appGwAllowedClientIp` | string | `''` | Optional APIM IP filter, usually the gateway's public IP after the first deployment. Empty means the gateway-secret check alone. |

Follow [HTTPS setup](getting-started.md#production-enable-https-on-the-app-gateway) and
[traffic-flow troubleshooting](traffic-flow.md#common-failure-points) for verification.

## Token governance

No additional service is created. Limits apply per organization to Chat Completions and
Responses. Per-org map entries override global defaults; `0` disables that limit.
Request limits above remain independent of token limits.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `tokensPerMinuteDefault` | int | `0` | Default tokens-per-minute limit. Exhaustion returns `429`. |
| `orgTokensPerMinute` | object | `{}` | Map of slug to tokens-per-minute override. |
| `monthlyTokenQuotaDefault` | int | `0` | Default monthly token quota. Exhaustion returns `403` until the UTC month resets. |
| `orgMonthlyTokenQuota` | object | `{}` | Map of slug to monthly token quota override. |

See [token-limit examples and checks](ai-gateway.md#token-limits--quotas).

## Observability

Enable `deployObservability` before `enableTokenMetrics`. This creates Application Insights and,
unless reusing a workspace, Log Analytics; ingestion and retention incur charges. APIM
diagnostics capture no prompt or completion bodies. These settings do not configure WAF logs.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `deployObservability` | bool | `false` | Create observability resources and configure the APIM logger and diagnostics. |
| `logAnalyticsWorkspaceId` | string | `''` | Existing workspace resource ID to reuse. Empty creates a workspace when observability is enabled. |
| `logAnalyticsWorkspaceName` | string | `''` | New workspace name; empty derives `<apimName>-logs`. Ignored when reusing a workspace. |
| `appInsightsName` | string | `''` | Application Insights name; empty derives `<apimName>-ai`. |
| `enableTokenMetrics` | bool | `false` | Emit per-org token metrics; requires observability. |
| `grantMetricsPublisherRole` | bool | `false` | Grant APIM Monitoring Metrics Publisher. Not needed for logger-based `customMetrics`; use only for Azure Monitor custom-metric publishing where the role resolves. |

See [token metrics and dashboards](ai-gateway.md#token-metrics--dashboard).

## Content safety

**Creating a resource does not enable moderation.** Set `deployContentSafety = true`, or provide
`contentSafetyEndpoint`, then enable checks globally or per org. Reusing an endpoint requires
granting APIM's identity **Cognitive Services User** on that resource.

Checks apply to Chat Completions and Responses and incur Content Safety usage charges.
Provisioning a new resource also requires `Microsoft.CognitiveServices` registration.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `deployContentSafety` | bool | `false` | Create a Content Safety resource and grant APIM access. |
| `contentSafetyEndpoint` | string | `''` | Reuse an existing endpoint instead. A newly deployed resource takes precedence when both are set. |
| `contentSafetyName` | string | `''` | New resource name; empty derives `<apimName>-cs`. Used only when deploying the resource. |
| `contentSafetyEnabledDefault` | bool | `false` | Enable checks for all orgs unless overridden. Requires a deployed or existing endpoint. |
| `orgContentSafetyEnabled` | object | `{}` | Map of slug to `true` or `false`; overrides global enablement. |
| `contentSafetyShieldPrompt` | bool | `true` | Enable Prompt Shields during active moderation. Does not enable moderation by itself. |
| `contentSafetyOutputType` | string | `'FourSeverityLevels'` | Threshold scale: `FourSeverityLevels` or `EightSeverityLevels`. |
| `contentSafetyHateThreshold` | int | `4` | Reject Hate severity at or above this value. Use a value supported by the selected scale. |
| `contentSafetySelfHarmThreshold` | int | `4` | Reject SelfHarm severity at or above this value. |
| `contentSafetySexualThreshold` | int | `4` | Reject Sexual severity at or above this value. |
| `contentSafetyViolenceThreshold` | int | `4` | Reject Violence severity at or above this value. |
| `contentSafetyBlocklists` | array | `[]` | Content Safety blocklist names to enforce during active checks. |

See [content-safety examples and tuning](ai-gateway.md#content-safety).

## Semantic caching

**Provisioning the cache does not enable it for organizations.** Set `deploySemanticCache = true`,
provide an existing Foundry embeddings deployment, and enable caching globally or per org.
This creates billable Azure Managed Redis resources and requires `Microsoft.Cache` registration.
Embedding calls also incur usage charges.

Caching applies only to Chat Completions, not Responses. Entries are partitioned by org and model.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `deploySemanticCache` | bool | `false` | Create Redis with RediSearch, the APIM external cache, and the embeddings backend. |
| `redisCacheName` | string | `''` | Redis resource name; empty derives `<apimName>-redis`. |
| `redisSku` | string | `'Balanced_B0'` | Redis SKU; affects availability, capacity, and cost. |
| `embeddingsDeploymentName` | string | `''` | Required when deploying the cache; existing embeddings deployment on the Foundry account. |
| `semanticCacheScoreThreshold` | string | `'0.05'` | Similarity threshold from `0.0` to `1.0`. Lower is stricter; values above `0.2` risk mismatches. |
| `semanticCacheDurationSeconds` | int | `120` | Cached completion lifetime in seconds. |
| `semanticCacheMaxMessageCount` | int | `4` | Skip cache lookup above this message count. |
| `semanticCacheEnabledDefault` | bool | `false` | Enable caching for all orgs unless overridden. Requires the cache infrastructure. |
| `orgSemanticCacheEnabled` | object | `{}` | Map of slug to `true` or `false`; overrides global enablement. |

See [semantic-cache examples and checks](ai-gateway.md#semantic-caching).

## Alternate backends

Two independent slots can route selected orgs to existing managed endpoints instead of the
primary Foundry backend or pool. A nonempty base URL creates an APIM backend, not the model
endpoint itself. Endpoint compute and inference remain billable.

For each slot, configure its URL, org list, and advertised model IDs together. Listed orgs must
also exist in `orgs`; their `/models` response is static. The endpoint owner must grant APIM's
managed identity the required scoring permission. For managed online endpoints, use the same
tenant; these parameters do not configure key-based cross-tenant authentication.

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `cohereBackendBaseUrl` | string | `''` | First alternate endpoint base URL, for example `https://<endpoint>.<region>.inference.ml.azure.com/score/v1`. Empty disables the slot. |
| `cohereBackendResource` | string | `'https://ml.azure.com'` | Managed-identity token audience; must match the endpoint. |
| `cohereOrgs` | array | `[]` | Orgs routed to the first slot. Requires its base URL. |
| `cohereModelIds` | array | `[]` | Model IDs advertised to those orgs; does not deploy models. |
| `mcBackendBaseUrl` | string | `''` | Second independent endpoint base URL. Empty disables the slot. |
| `mcBackendResource` | string | `'https://ml.azure.com'` | Managed-identity token audience for the second slot. |
| `mcOrgs` | array | `[]` | Orgs routed to the second slot. Requires its base URL; takes precedence if an org also appears in `cohereOrgs`. |
| `mcModelIds` | array | `[]` | Model IDs advertised to second-slot orgs. |

For endpoint URLs, audiences, and RBAC examples, see
[per-org backend routing](reference-architecture.md#per-org-backend-routing-optional-eg-cohere).
