# AI Gateway capabilities — enable and use

This is the operational runbook for the optional **AI Gateway** capabilities: what each one does,
the parameter(s) that turn it on, and how to verify and use it after deploying. For the design
rationale (policy order, tenant isolation, tradeoffs), see the
[reference architecture](reference-architecture.md#ai-gateway-capabilities-opt-in).

For every setting, default, and dependency, see the [parameter reference](parameters.md).

> **Everything here is off by default.** The base deployment behaves exactly as the
> [getting started guide](getting-started.md) describes. Each capability is a parameter you set in
> your params file (e.g. `infra/my.bicepparam`) and a redeploy — nothing changes for your clients
> or the `/byok/<org>` contract.

## What the AI gateway is

This solution already runs APIM as an OpenAI-compatible gateway in front of Foundry. The "AI
gateway" is APIM's purpose-built [GenAI policy set](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
(`llm-*` policies) that understands the LLM wire format — so it can count **tokens** (not just
requests), moderate prompts, cache completions by meaning, and load-balance across Foundry
accounts. Each capability is rendered **per org** and reuses the `byokOrg` / `byokModel` request
variables the auth policy already sets.

## Capabilities at a glance

| Capability | Turn on with | New resources / cost | Applies to |
| --- | --- | --- | --- |
| [Token limits & quotas](#token-limits--quotas) | `tokensPerMinuteDefault` / `orgTokensPerMinute`, `monthlyTokenQuotaDefault` / `orgMonthlyTokenQuota` | none | chat + responses |
| [Token metrics & dashboard](#token-metrics--dashboard) | `deployObservability`, `enableTokenMetrics` | Log Analytics + App Insights (low) | chat + responses |
| [Content safety](#content-safety) | `deployContentSafety` (or `contentSafetyEndpoint`), `orgContentSafetyEnabled` | Content Safety resource (per-call) | chat + responses |
| [Semantic caching](#semantic-caching) | `deploySemanticCache`, `embeddingsDeploymentName`, `orgSemanticCacheEnabled` | Azure Managed Redis (largest) | chat only |
| [Resilient multi-Foundry pool](#resilient-multi-foundry-pool) | `foundryBackends` | none | all Foundry routing |

## How to enable (the pattern)

1. Edit your params file (`infra/my.bicepparam`) and set the flag(s) for the capability.
2. Redeploy:

   ```powershell
   az deployment group create --resource-group <resource-group> --parameters infra/my.bicepparam
   ```

3. Verify with the per-capability steps below.

To turn a capability **off**, set its flag back to `false` (or clear the array/map) and redeploy —
the policy block and any backend dependency are removed cleanly, nothing else is touched.

---

## Token limits & quotas

**What it does.** Enforces per-org **token** budgets with the native `llm-token-limit` policy: a
per-minute rate and/or a monthly quota, keyed on the org. Prompt tokens are estimated, so an
over-budget request is rejected before it reaches Foundry. TPM exhaustion → **429**; monthly quota
exhaustion → **403** until the month resets (UTC). This is the token-aware complement to the
request-count `rate-limit-by-key` (which stays on).

**Enable.**

```bicep
param tokensPerMinuteDefault = 0            // global baseline; 0 = no per-minute limit
param orgTokensPerMinute = {
  'covenantcoders': 50000                   // per-org override
}
param monthlyTokenQuotaDefault = 0          // global baseline; 0 = no quota
param orgMonthlyTokenQuota = {
  'covenantcoders': 5000000
}
```

**Verify / use.** Every governed response carries usage headers:

- `x-ratelimit-remaining-tokens` — tokens left in the current minute
- `x-ratelimit-remaining-quota-tokens` — tokens left in the monthly quota
- `x-ratelimit-consumed-tokens` — tokens this request cost

Set a deliberately low TPM for a test org, send a request, and inspect the headers; keep sending to
see a **429**. Clients should honor the `Retry-After` header on 429.

---

## Token metrics & dashboard

**What it does.** Emits per-org token counts (`llm-emit-token-metric`) to Application Insights with
dimensions `byokOrg`, `model`, `API ID`, `Operation ID`. Request/response bodies are captured at
**0 bytes**, so **prompts and completions are never logged** — only counts and dimensions.

**Enable.**

```bicep
param deployObservability = true            // stands up Log Analytics + App Insights
param enableTokenMetrics = true             // emits the byok-llm metrics
// Optional: reuse an existing workspace instead of creating one
param logAnalyticsWorkspaceId = ''
```

**Where the dashboard is.** After deploying and sending some traffic:

1. **Per-org token usage** — Azure portal → Application Insights **`<apimName>-ai`** (e.g.
   `ghcp-byok-apim-dev-ai`) → **Metrics** → metric namespace **`byok-llm`** → pick the token
   metric and **split by `byokOrg`** (or `model`).
2. **APIM's built-in view** — APIM `<apimName>` → **Monitoring → Application Insights**, and the
   **Azure OpenAI / LLM** analytics workbook.
3. **Platform metrics (always available, no tokens)** — APIM → **Monitoring → Metrics** for
   requests, latency, and status codes.

> Metrics can take a few minutes to appear after the first governed request.

---

## Content safety

**What it does.** Screens each prompt with [Azure AI Content Safety](https://learn.microsoft.com/azure/ai-services/content-safety/overview)
(`llm-content-safety`) — harm categories plus, with Prompt Shields, jailbreak / prompt-injection
detection — **before** it reaches the model. A blocked request returns **403**. This complements the
WAF (which inspects bytes, not intent) and runs before the cache lookup, so every prompt is screened
even on a cache hit.

**Enable.**

```bicep
param deployContentSafety = true            // creates the resource + grants APIM the role
// or reuse an existing one (grant APIM 'Cognitive Services User' yourself):
// param contentSafetyEndpoint = 'https://<name>.cognitiveservices.azure.com'

param contentSafetyEnabledDefault = false   // or true for all orgs
param orgContentSafetyEnabled = {
  'covenantcoders': true
}
param contentSafetyShieldPrompt = true      // jailbreak / prompt-injection detection
param contentSafetyOutputType = 'FourSeverityLevels'
param contentSafetyHateThreshold = 4        // reject at/above this severity
param contentSafetySelfHarmThreshold = 4
param contentSafetySexualThreshold = 4
param contentSafetyViolenceThreshold = 4
```

**Verify / use.** Send a benign coding prompt and confirm you still get **200** — coding content
(SQL-, script-, shell-like text) is legitimate here, so start with permissive thresholds and tune
down only if needed. A prompt that trips a category returns **403** with a content-safety error.
Watch for false positives on real prompts before tightening thresholds.

---

## Semantic caching

**What it does.** Returns a cached completion when a new prompt is semantically close to a prior one
(`llm-semantic-cache-lookup` / `store`), cutting tokens and latency. Cache entries are partitioned by
**org and model**, so no tenant (or model) can read another's cached response. **Chat completions
only** — `/responses` is intentionally excluded.

**Prerequisite.** An **embeddings deployment** on the Foundry account (used to vectorize prompts).

**Enable.**

```bicep
param deploySemanticCache = true            // Azure Managed Redis (RediSearch) + APIM external cache
param embeddingsDeploymentName = 'text-embedding-3-small'   // must exist on the Foundry account
param redisSku = 'Balanced_B0'
param semanticCacheScoreThreshold = '0.05'  // stricter is lower; >0.2 risks mismatches
param semanticCacheDurationSeconds = 120
param semanticCacheMaxMessageCount = 4
param semanticCacheEnabledDefault = false
param orgSemanticCacheEnabled = {
  'covenantcoders': true
}
```

**Verify / use.** Send the same prompt twice. The second call should return noticeably faster; to
confirm it was a cache hit, trace the operation in the APIM **portal test console / API Inspector** —
the trace shows the cache lookup outcome. Loosen `semanticCacheScoreThreshold` slightly if you want
more hits, but keep it ≤ 0.2 to avoid returning a stale/mismatched answer.

---

## Resilient multi-Foundry pool

**What it does.** Routes all orgs through a **load-balanced pool** across several Foundry accounts
instead of the single `foundryBackendBaseUrl`, published under the same `foundry-backend` id (so the
per-org policy is unchanged). Each member has a **circuit breaker** that trips on `429`/`5xx` and
honors `Retry-After`; `priority` sets failover order and `weight` sets share within a priority.

**Prerequisite.** Every account must expose **equivalent deployment names** (the `model` the client
sends is resolved on whichever member serves the request). `/models` still lists the primary account.

**Enable.**

```bicep
param foundryBackends = [
  { accountName: 'aoai-eastus2', backendBaseUrl: 'https://aoai-eastus2.openai.azure.com', priority: 1, weight: 1 }
  { accountName: 'aoai-westus',  backendBaseUrl: 'https://aoai-westus.openai.azure.com',  priority: 2, weight: 1 }
]
```

The APIM identity is granted **Foundry User** on every member account automatically. `subscriptionId`
and `resourceGroup` default to the primary's; set them per entry for accounts elsewhere.

**Verify / use.** Send chat requests as normal — clients see no change. Under load or when a member
returns 429/5xx, traffic shifts to the next-priority member; watch APIM **Metrics** (backend
failures) and Application Insights to observe failover.

---

## Rollback

Every capability is a single flag. Set the relevant `deploy*` / `enable*` parameter back to `false`
(or clear `foundryBackends` / the per-org maps) and redeploy. Because the flags gate both the
resources and the per-org policy rendering, turning one off removes its policy block and backend
dependency without affecting the others. The optional resources (App Insights, Content Safety, Redis)
can then be deleted from the resource group if you no longer need the retained data.
