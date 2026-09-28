# Getting started

This guide walks you through standing up the BYOK proxy end to end: provisioning the
APIM gateway in front of your Microsoft Foundry deployment, then pointing a Copilot BYOK
surface at it. The gateway is **multi-tenant by organization** — each org slug you list
gets its own path, key, and policy on one shared APIM instance. For background on how the
pieces fit together, see the [reference architecture](reference-architecture.md).

## What you'll end up with

- An APIM gateway, fronted by an **Application Gateway (WAF_v2)**, that publishes an
  OpenAI-compatible endpoint per org. Clients point at the gateway front door,
  `https://<gateway-host>/byok/<org>`; the APIM FQDN is the backend only and rejects direct
  hits with `403`.
- A `/byok/<org>/chat/completions` operation (and `/responses`) that routes to your Foundry
  deployment using the gateway's managed identity — no Foundry keys on clients.
- A `/byok/<org>/models` operation that lists your real Foundry deployments in OpenAI
  list-models format, so Copilot's model picker only shows what you've deployed.
- One secret client key **per org** (the `byokKey-<org>` named values), each presented by
  that org's callers as a bearer token and validated against that org's path in policy.

## Prerequisites

Before you deploy, make sure you have:

- **An Azure subscription** with permission to create resources and assign roles
  (you need `Microsoft.Authorization/roleAssignments/write`, e.g. **Owner** or
  **User Access Administrator**, because the deployment grants the gateway a role on
  Foundry).
- **An existing Microsoft Foundry / Azure OpenAI resource** with a model deployment.
  The proxy does **not** create the Foundry resource — it points at one you already have.
- **A model that meets the Copilot BYOK requirements:** tool calling (function calling),
  streaming, and ideally a context window of **≥128k tokens**. Copilot CLI errors out on
  models that lack tool calling or streaming.
- **The [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)** (with the
  Bicep tooling, which `az` installs on first use), signed in via `az login`.
- **A Copilot BYOK surface** to test with: VS Code, the Copilot CLI, or enterprise BYOK
  on GitHub.com.

### Register the Azure resource providers

Register the resource providers used by the template in the **target subscription** where APIM
and the optional Application Gateway will be deployed. Provider registration is per subscription.
The existing Foundry resource is a prerequisite, so its subscription's provider setup is outside
this deployment.

| When required | Resource provider |
| --- | --- |
| Every deployment | `Microsoft.ApiManagement` |
| `deployObservability = true` | `Microsoft.OperationalInsights`, `Microsoft.Insights` |
| `deployAppGateway = true` | `Microsoft.Network` |
| `deployContentSafety = true` | `Microsoft.CognitiveServices` |
| `deploySemanticCache = true` | `Microsoft.Cache` |

Register the core provider before deploying:

**PowerShell:**

```powershell
# Existing Azure subscription that will receive the gateway resources
$TARGET_SUBSCRIPTION_ID = '<target-subscription-id>'

az provider register --subscription $TARGET_SUBSCRIPTION_ID --namespace Microsoft.ApiManagement --wait
```

Register only the providers for the optional features you enable. For example, observability
requires:

```powershell
foreach ($provider in @('Microsoft.OperationalInsights', 'Microsoft.Insights')) {
  az provider register --subscription $TARGET_SUBSCRIPTION_ID --namespace $provider --wait
}
```

**Bash:**

```bash
TARGET_SUBSCRIPTION_ID=<target-subscription-id>

az provider register \
  --subscription "$TARGET_SUBSCRIPTION_ID" \
  --namespace Microsoft.ApiManagement \
  --wait

for provider in Microsoft.OperationalInsights Microsoft.Insights; do
  az provider register \
    --subscription "$TARGET_SUBSCRIPTION_ID" \
    --namespace "$provider" \
    --wait
done
```

Azure normally registers the platform providers used for deployments and role assignments
(`Microsoft.Resources` and `Microsoft.Authorization`). Your deploying identity still needs
`Microsoft.Authorization/roleAssignments/write` on the existing Foundry resource, including
when Foundry is in another subscription. `Microsoft.AlertsManagement` is not used by this
template; register it separately only if you later enable an Application Insights alert that
requires it.

> **Note:** APIM provisioning can take a while to finish (the **Developer** and
> **Premium** tiers in particular can take 30–45 minutes for the gateway to come online).
> Plan for that on the first deployment.

## Step 1 — Collect your Foundry details

From the Foundry / Azure OpenAI resource you'll be fronting, note:

| Value | Where to find it | Example |
| --- | --- | --- |
| Account name | Resource overview | `contoso-foundry` |
| Resource group | Resource overview | `rg-ai` |
| Endpoint base URL | Resource **Keys and Endpoint** | `https://contoso-foundry.openai.azure.com` |
| Deployment name | **Model deployments** blade | `gpt-4o` |

The **deployment name** (not the base model name) is what clients will pass as `model`.

## Step 2 — Clone the repo and pick per-org keys

```bash
git clone https://github.com/jasonmoodie/ghcp-byok-per-org-gateway.git
cd ghcp-byok-per-org-gateway
```

Decide which organizations get access. Generate one **strong, unique client key per org**,
plus a separate shared secret for Application Gateway when `deployAppGateway = true`. For a
single-org deployment with Application Gateway, run this command twice:

```bash
# Run once per org. Store each result under that org's slug in `orgKeys`.
openssl rand -hex 32

# Run once more. Store this different result in `appGwSharedSecret`.
openssl rand -hex 32
```

For multiple orgs, run the first command once per org and the second command only once. Store
the values in `infra/my.bicepparam`, replacing the placeholders as shown below:

```bicep
param orgKeys = {
  'your-github-org': '<first-generated-value>'
}

param deployAppGateway = true
param appGwSharedSecret = '<second-generated-value>'
```

Each org key is a client-facing API key. `appGwSharedSecret` is an internal secret used only
between Application Gateway and APIM. Keep all values secret and do not reuse an org key as
the Application Gateway shared secret.

## Step 3 — Fill in the deployment parameters

Copy the example parameter file and edit it with your values:

```bash
cp infra/example.bicepparam infra/my.bicepparam
```

Then set each parameter in `infra/my.bicepparam`:

| Parameter | What to set it to |
| --- | --- |
| `apimName` | A globally unique name for the new APIM instance |
| `apimPublisherName` | Your team or org name (shown in the APIM portal) |
| `apimPublisherEmail` | A contact email for APIM notifications |
| `apimSkuName` / `apimSkuCapacity` | APIM tier and units (`Developer` is fine for testing) |
| `foundryAccountName` | Foundry account name from Step 1 |
| `foundryAccountSubscriptionId` | Subscription ID that holds the Foundry account. Omit it when Foundry and APIM use the same subscription |
| `foundryAccountResourceGroup` | Resource group that holds the Foundry account |
| `foundryBackendBaseUrl` | Foundry endpoint base URL from Step 1 |
| `foundryApiVersion` | Azure OpenAI API version to send to the backend |
| `foundryDeploymentsApiVersion` | Data-plane version used to list deployments for `/models` |
| `foundryProjectName` | Optional. Foundry project name. Set it to also list the project's **managed-compute** deployments in `/models` (standard account deployments are listed either way) |
| `foundryProjectDeploymentsApiVersion` | Optional. API version for the project deployments listing (default `2025-05-01`) |
| `extraModelIds` | Optional. Manual list of model ids to force into `/models`, for anything the live queries don't return |
| `orgs` | Array of org slugs (lowercase letters, numbers, hyphens) — one path per org |
| `orgKeys` | Object keyed by org slug → that org's secret key from Step 2 |
| `deployAppGateway` | Set to `true` to deploy Application Gateway (WAF_v2) in front of APIM |
| `appGwSharedSecret` | The separate Application Gateway shared secret generated in Step 2; required when `deployAppGateway = true` |
| `orgModels` | Optional. Object keyed by org slug → array of model ids that org may see and call. A listed org's `/models` is filtered to these ids and any chat/responses request for another model is rejected with `403`. Orgs omitted (or mapped to `[]`) are unrestricted |
| `defaultTemperatureModelIds` | Optional. Model deployment ids that only accept the default Chat Completions temperature. APIM rewrites client-supplied temperatures to `1` for these models |
| `perOrgRateLimitCalls` / `perOrgRateLimitRenewalPeriod` | Optional per-org throttle (calls per period) |

> **Don't commit secrets.** The `orgKeys` values and `appGwSharedSecret` are secrets. Keep your filled-in
> `*.bicepparam` out of source control, or pass the keys at deploy time / from Key Vault
> instead of storing them in the file.

## Step 4 — Deploy

Create (or reuse) a resource group for the gateway, then deploy the template:

```bash
az group create --name <resource-group> --location <azure-region>

az deployment group create \
  --resource-group <resource-group> \
  --template-file infra/main.bicep \
  --parameters infra/my.bicepparam
```

The deployment provisions the APIM instance, imports a proxy API per org, applies the
per-org policies, and grants APIM's system-assigned managed identity the **`Foundry User`**
role on your Foundry account.

When it finishes, read the outputs — they give you the per-org URLs you'll need next:

```bash
az deployment group show \
  --resource-group <resource-group> \
  --name main \
  --query properties.outputs
```

| Output | Use |
| --- | --- |
| `apimGatewayUrl` | APIM base URL — the App Gateway backend (not the client-facing host) |
| `appGatewayPublicIp` | The App Gateway's static public IP — create your DNS `A` record against this |
| `appGatewayFrontendUrl` | The gateway's **lab HTTP** address (`http://<public-ip>`). Not the production host — see *Enable HTTPS* below |
| `orgProxyBasePaths` | Array of `{ org, basePath, modelsUrl }`. These are built on the **APIM host**; when the App Gateway guard is on, calling them directly returns `403` — point clients at your gateway hostname instead (see below) |
| `backendCompletionUrl` | The Foundry backend URL the gateway routes to (for reference) |

> When the App Gateway guard is active, calling the APIM FQDN directly returns `403`. During
> initial lab testing (HTTPS not yet enabled) reach the proxy through the HTTP front door
> `appGatewayFrontendUrl`; for real Copilot use you must enable HTTPS (next) and point clients
> at your own domain, because Copilot BYOK requires HTTPS.

## (Production) Enable HTTPS on the App Gateway

Copilot BYOK requires HTTPS, so a production front door needs a TLS certificate on a hostname
you control. The template ships the 443 listener and the HTTP→HTTPS redirect; you supply the
domain and certificate. Do this **after** the first deploy, which creates the public IP:

1. **Read the public IP** from the deployment outputs:

   ```powershell
   az deployment group show -g <resource-group> -n main `
     --query properties.outputs.appGatewayPublicIp.value -o tsv
   ```

2. **Create a DNS `A` record** at your DNS provider pointing your hostname at that IP — for
   example `copilot.example.com → <appGatewayPublicIp>`. Confirm it resolves
   (`nslookup copilot.example.com`).

3. **Issue a publicly-trusted certificate** for that hostname. A free 90-day Let's Encrypt cert
   via Posh-ACME (DNS-01) works well; export it as a full-chain PFX with a password.

4. **Base64-encode the PFX** for the params file:

   ```powershell
   $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('fullchain.pfx'))
   $b64 | Set-Content pfx.b64.txt
   ```

5. **Set the HTTPS parameters** in `infra/my.bicepparam`:

   ```bicep
   param appGwEnableHttps = true
   param appGwHttpsPfxBase64 = '<contents of pfx.b64.txt>'
   param appGwHttpsPfxPassword = '<the PFX password>'
   ```

6. **Redeploy** with the same command as Step 4. Port 443 now terminates TLS and port 80
   permanently redirects to HTTPS.

7. **Point clients at your hostname** — not at the `orgProxyBasePaths` or `appGatewayFrontendUrl`
   outputs (those use the APIM host or the lab HTTP IP):

   ```text
   https://copilot.example.com/byok/<org>
   ```

The certificate lives in the deployment, so renewal is a manual re-issue + redeploy (~every 90
days for Let's Encrypt). Keep the PFX base64, its password, the org keys, and `appGwSharedSecret`
out of source control.

## Step 5 — Verify the proxy

Pick one org's `basePath` from `orgProxyBasePaths` as `<base-url>` and that org's key as
`<client-key>`.

**List models** — confirms managed-identity auth and the `/models` operation:

```bash
curl "<base-url>/models" \
  -H "Authorization: Bearer <client-key>"
```

You should get an OpenAI-style `{ "object": "list", "data": [ ... ] }` response containing
your Foundry deployment(s). Each `id` is a value you can pass as `model`.

**Send a chat completion** — confirms end-to-end routing to Foundry:

```bash
curl "<base-url>/chat/completions" \
  -H "Authorization: Bearer <client-key>" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "<your-foundry-deployment-name>",
        "messages": [{"role": "user", "content": "Say hello in one word."}]
      }'
```

A `401` means the bearer token didn't match that org's `byokKey-<org>` (check you're using
the key that matches the path). A `5xx` usually points at the backend URL, deployment name,
or the role assignment not having propagated yet — wait a minute and retry.

## Step 6 — Point a Copilot surface at it

For each org, the **API key is that org's key** and the **model is your Foundry deployment
name**. The gateway adds the backend token and `api-version`. Use that org's `<base-url>`.

**VS Code (individual).** Chat view → model picker → **Manage Language Models** →
**Add Models** → **Custom Endpoint**. Set the base URL to `<base-url>`, the API key to that
org's key, and the model to your deployment name. Select **Responses** as the API type for
models that combine reasoning with function tools; select Chat Completions only when the model
supports that combination. The older OpenAI Compatible provider is deprecated.

**Copilot CLI (individual).**

```bash
export COPILOT_PROVIDER_TYPE=openai
export COPILOT_PROVIDER_BASE_URL=<base-url>
export COPILOT_PROVIDER_API_KEY=<client-key>
export COPILOT_MODEL=<your-foundry-deployment-name>
copilot
```

**GitHub.com (enterprise).** An enterprise owner registers each org's `<base-url>` under
**AI controls → Copilot → Configure allowed models → Custom models** as an
**OpenAI-compatible provider** with that org's key, then sets **Access → Choose per
organization** to the matching org. The models then surface on GitHub.com, the CLI, and
IDEs for that org only.

Full per-surface steps — including the org-scoping detail and policy toggles — are in
[client-surfaces.md](client-surfaces.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `401 invalid_api_key` | Bearer token doesn't match that org's `byokKey-<org>` | Confirm the key matches the `/byok/<org>` path the client points at; redeploy if you rotated it |
| `5xx` on chat, `/models` works | Backend URL or deployment name wrong, or role not yet propagated | Verify `foundryBackendBaseUrl` + the `model` you send; wait for the role assignment to propagate |
| `/models` returns an empty list | Wrong `foundryDeploymentsApiVersion`, or no deployments on the account | Confirm the account has deployments; adjust the data-plane API version |
| A managed-compute model is missing from `/models` | `foundryProjectName` not set, so only the account listing is queried | Set `foundryProjectName` to the project that holds the managed-compute deployment (or add its name to `extraModelIds`) |
| `429 Too Many Requests` from APIM | That org hit its `perOrgRateLimitCalls` | Raise the per-org limit or spread load |
| `403 model_not_allowed` on chat/responses | The `model` isn't in that org's `orgModels` allowlist | Add the id to `orgModels[<org>]` (and redeploy), or send an allowed model — check `/byok/<org>/models` for the permitted list |
| Copilot CLI errors on the model | Model lacks tool calling or streaming | Use a deployment that supports both (see [model requirements](../README.md#model-requirements)) |
| `400` says function tools with `reasoning_effort` are unsupported on `/v1/chat/completions` | VS Code configured a reasoning model with the Chat Completions API | Reconfigure the model as a **Custom Endpoint** with API type **Responses** and URL `<base-url>/responses` |
| `400` says `temperature` only supports the default value `1` | The client sent a sampling temperature the model does not support | Add the deployment id to `defaultTemperatureModelIds` and redeploy so APIM normalizes it to `1` |
| Copilot uses `azure` and hits `/openai/deployments/...` | Wrong provider type | Use the `openai` provider type targeting `/byok/<org>`, not `azure` |
| Deploy fails: `The 'JObject' start tag ... does not match the end tag of 'set-body'` | A policy has a C# expression with generics (e.g. `As<JObject>`); APIM's XML parser reads `<JObject>` as a tag | Wrap the expression body in `<![CDATA[ ... ]]>` inside `<set-body>` (see `infra/policies/models.xml` for the pattern) |

## Next steps

- Turn on the optional **AI Gateway capabilities** — per-org token limits/quotas, token
  metrics and the telemetry dashboard, content safety, semantic caching, and a resilient
  multi-Foundry pool — with the [enable-and-use runbook](ai-gateway.md). All are off by default.
- Review the [per-organization multi-tenant BYOK](reference-architecture.md#per-organization-multi-tenant-byok)
  design, including GitHub-side org scoping and the teams-inside-one-org limitation.
- Review the full per-surface configuration in [client-surfaces.md](client-surfaces.md).
