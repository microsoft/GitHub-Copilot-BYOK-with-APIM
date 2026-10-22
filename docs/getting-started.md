# Getting started

Deploy an HTTPS gateway for your existing Microsoft Foundry models, then connect GitHub Copilot.
Each GitHub organization gets its own `/byok/<org>` path, key, and policy on one shared gateway.
For the design, see the [reference architecture](reference-architecture.md).

Commands use Bash unless labeled PowerShell. Replace angle-bracketed placeholders with your values.

## Prerequisites

- An Azure subscription and permission to create resources and assign roles. You need
  `Microsoft.Authorization/roleAssignments/write` on the Foundry account, even if it is in
  another subscription.
- An existing Foundry / Azure OpenAI account with a model deployment supporting **tool calling**
  and **streaming**. A context window of at least **128k tokens** is recommended.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), Git, and OpenSSL.
  Azure CLI installs Bicep tooling on first use.
- A hostname you control and a publicly trusted TLS certificate; see [Enable HTTPS](#production-enable-https-on-the-app-gateway).
- A Copilot client: VS Code, Copilot CLI, or enterprise BYOK on GitHub.com.

Sign in and select the subscription that will host the gateway:

```bash
az login
az account set --subscription <target-subscription-id>
```

### Register the Azure resource providers

Register the providers for APIM and Application Gateway in the selected subscription:

```bash
az provider register --namespace Microsoft.ApiManagement --wait
az provider register --namespace Microsoft.Network --wait
```

For optional features, register these providers with the same command:

| Feature | Resource providers |
| --- | --- |
| `deployObservability = true` | `Microsoft.OperationalInsights`, `Microsoft.Insights` |
| `deployContentSafety = true` | `Microsoft.CognitiveServices` |
| `deploySemanticCache = true` | `Microsoft.Cache` |

## Step 1 — Collect your Foundry details

Record the account name, subscription ID, resource group, and endpoint base URL
(under **Keys and Endpoint**), for example `https://contoso-foundry.openai.azure.com`.

Also record the model's **deployment name**, not its base model name. Clients send this as `model`.

## Step 2 — Clone the repo and generate keys

```bash
git clone https://github.com/microsoft/GitHub-Copilot-BYOK-with-APIM.git
cd GitHub-Copilot-BYOK-with-APIM
```

Generate one unique client key per organization and one separate Application Gateway secret.
Run this once for each value:

```bash
openssl rand -hex 32
```

Store the client keys in `orgKeys` and the gateway secret in `appGwSharedSecret` in the next step.
Never reuse a client key as the gateway secret.

## Step 3 — Set deployment parameters

Copy the [example parameters](../infra/example.bicepparam):

```bash
cp infra/example.bicepparam infra/my.bicepparam
```

Edit the existing entries in `infra/my.bicepparam`:

| Parameter | Value |
| --- | --- |
| `apimName` | Globally unique APIM instance name |
| `apimPublisherName` / `apimPublisherEmail` | Organization name and contact email |
| `apimSkuName` / `apimSkuCapacity` | Tier and units; `Developer` is suitable for testing |
| `foundryAccountName` | Existing Foundry account name |
| `foundryAccountSubscriptionId` | Foundry subscription ID; omit to use the selected subscription |
| `foundryAccountResourceGroup` | Foundry resource group |
| `foundryBackendBaseUrl` | Endpoint base URL from Step 1 |
| `orgs` | Organization slugs using lowercase letters, numbers, and hyphens |
| `orgKeys` | Map of each slug to its client key |
| `deployAppGateway` | `true` for the gateway path in this guide; defaults to `false` |
| `appGwName` | Application Gateway name |
| `appGwSharedSecret` | Separate gateway secret from Step 2 |

Replace sample organizations in **all** per-org maps, including optional overrides.
Leave `appGwEnableHttps = false` until the certificate is ready.

Optional settings:

| Parameter | Purpose |
| --- | --- |
| `orgModels` | Per-org model allowlists; omitted orgs or empty arrays are unrestricted |
| `perOrgRateLimitCalls` / `perOrgRateLimitRenewalPeriod` | Request limit per org; defaults to 300 calls per 60 seconds |
| `foundryProjectName` | Include the project's managed-compute deployments in `/models` |
| `extraModelIds` | Manually add callable deployments missing from discovery |
| `defaultTemperatureModelIds` | Normalize Chat Completions temperature to `1` for models that require it |

Keep the API-version defaults (`foundryApiVersion`, `foundryDeploymentsApiVersion`, and
`foundryProjectDeploymentsApiVersion`) unless your backend requires different versions.

**Do not commit secrets.** `infra/my.bicepparam` is ignored by Git. Protect any copies, keys,
passwords, PFX files, and base64-encoded certificate data.

## Step 4 — Deploy

Create or reuse a resource group, then deploy:

```bash
az group create --name <resource-group> --location <azure-region>

az deployment group create \
  --resource-group <resource-group> \
  --template-file infra/main.bicep \
  --parameters infra/my.bicepparam
```

This creates APIM, Application Gateway, and the per-org APIs and policies. It grants APIM's
managed identity the **Foundry User** role on your Foundry account. APIM provisioning can take
30–45 minutes.

Read the deployment outputs:

```bash
az deployment group show \
  --resource-group <resource-group> \
  --name main \
  --query properties.outputs
```

| Output | Use |
| --- | --- |
| `appGatewayPublicIp` | IP for your DNS `A` record |
| `appGatewayFrontendUrl` | Initial HTTP address, not the HTTPS client URL |
| `apimGatewayUrl` / `orgProxyBasePaths` | APIM backend URLs; direct requests without the gateway secret return `403` |
| `backendCompletionUrl` | Foundry backend URL for reference |

Complete HTTPS setup before sending keys or connecting Copilot. WAF starts in **Detection**
mode: it records matches but does not block requests. See [WAF tuning](traffic-flow.md#where-the-waf-is)
before enabling Prevention.

## (Production) Enable HTTPS on the App Gateway

Copilot BYOK requires HTTPS. After the first deployment:

1. **Configure DNS.** Create an `A` record pointing your hostname at `appGatewayPublicIp`.
   Confirm it resolves, for example with `nslookup copilot.example.com`.
2. **Obtain a certificate.** Issue a publicly trusted certificate for that hostname, such as
   Let's Encrypt using Posh-ACME with DNS-01. Export a password-protected, full-chain PFX.
3. **Base64-encode the PFX** using PowerShell:

   ```powershell
   $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('fullchain.pfx'))
   $b64 | Set-Content pfx.b64.txt
   ```

4. **Update** `infra/my.bicepparam`:

   ```bicep
   param appGwEnableHttps = true
   param appGwHttpsPfxBase64 = '<contents of pfx.b64.txt>'
   param appGwHttpsPfxPassword = '<the PFX password>'
   ```

5. **Redeploy** using the Step 4 command. Port 443 now terminates TLS; port 80 redirects to HTTPS.

Use `https://<gateway-host>/byok/<org>` as the client base URL, not the APIM or HTTP output URLs.
Renew and redeploy the certificate before it expires; renewal is manual unless automated.

## Step 5 — Verify the proxy

Use `https://<gateway-host>/byok/<org>` as `<base-url>` and the matching organization's key as
`<client-key>`. Run both checks over HTTPS.

**List models:**

```bash
curl "<base-url>/models" \
  -H "Authorization: Bearer <client-key>"
```

Expect `{ "object": "list", "data": [ ... ] }` containing your deployments, filtered by any
`orgModels` allowlist. Each `id` is a value clients can send as `model`.

**Send a chat completion:**

```bash
curl "<base-url>/chat/completions" \
  -H "Authorization: Bearer <client-key>" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "<your-foundry-deployment-name>",
        "messages": [{"role": "user", "content": "Say hello in one word."}]
      }'
```

Expect a completion containing an assistant message. For errors, use the table below.

## Step 6 — Connect Copilot

Use the same HTTPS base URL, organization key, and Foundry deployment name:

| Client | Setup |
| --- | --- |
| VS Code | [Custom Endpoint](client-surfaces.md#vs-code); choose the API type your model supports |
| Copilot CLI | [OpenAI provider](client-surfaces.md#copilot-cli) (`openai`, not `azure`) |
| Enterprise BYOK | [OpenAI-compatible provider](../README.md#configure-enterprise-byok); scope access to the matching organization |

## Troubleshooting

| Symptom | Check or fix |
| --- | --- |
| `403 gateway_required` | Use the gateway's HTTPS hostname, not APIM. If already using it, check the gateway secret |
| `401 invalid_api_key` | Match the client key to the `/byok/<org>` path; redeploy after key rotation |
| Chat returns `5xx`, but `/models` works | Check `foundryBackendBaseUrl` and the deployment name; allow time for the role assignment to propagate |
| `/models` is empty | Check the account's deployments, API version, and `orgModels` allowlist |
| Managed-compute model missing | Set `foundryProjectName`, or add its deployment name to `extraModelIds` |
| `429 Too Many Requests` | Check per-org request or token rate limits; reduce traffic or adjust limits |
| `403 model_not_allowed` | Use an allowed deployment from `/models`, or update `orgModels` and redeploy |
| Copilot CLI rejects the model | Confirm [tool calling and streaming support](../README.md#model-requirements) |
| `400` mentions function tools with `reasoning_effort` | Configure VS Code's Custom Endpoint for **Responses**, with URL `<base-url>/responses` |
| `400` says temperature must be `1` | Add the deployment ID to `defaultTemperatureModelIds` and redeploy |
| Client calls `/openai/deployments/...` | Change provider type from `azure` to `openai` |

For DNS, TLS, WAF, and gateway errors, see [traffic-flow troubleshooting](traffic-flow.md#common-failure-points).

## Next steps

- [Enable AI Gateway capabilities](ai-gateway.md): token governance, metrics, content safety,
  caching, and backend resilience.
- [Review the organization boundary](reference-architecture.md#per-organization-multi-tenant-byok):
  access is per organization, not per user or team.
