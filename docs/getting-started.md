# Getting started

Deploy an HTTPS gateway for your existing Microsoft Foundry models, then connect GitHub Copilot.
Each GitHub organization gets its own `/byok/<org>` path, key, and policy on one shared gateway.
For the design, see the [reference architecture](reference-architecture.md).

**Default setup: Application Gateway (WAF_v2) + APIM.** Application Gateway incurs Azure charges.
The first deployment creates the gateway; adding a certificate enables HTTPS. Do not connect
Copilot or send keys until HTTPS is verified.

Commands use Bash unless labeled PowerShell. Replace angle-bracketed placeholders with your values.

## Prerequisites

- An Azure subscription and permission to create resources and assign roles. You need
  `Microsoft.Authorization/roleAssignments/write` on the Foundry account, even if it is in
  another subscription.
- An existing Foundry / Azure OpenAI account with a model deployment supporting **tool calling**
  and **streaming**. A context window of at least **128k tokens** is recommended.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), Git, and either
  PowerShell 7.2+ or OpenSSL for key generation.
  Use Bicep CLI 0.38 or later (`az bicep upgrade`).
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

### If public IP creation requires feature registration

The gateway creates a Standard, Static, Azure-allocated public IP; it does not import your own
IP address or prefix. If deployment fails with `SubscriptionNotRegisteredForFeature` for
`Microsoft.Network/AllowBringYourOwnPublicIpAddress`, this is a **subscription feature-registration
issue**, not a missing resource group. The `resourceGroups//` segment in the error does not mean
you need to create another resource group. Registering the `Microsoft.Network` resource provider
alone does not enable this feature.

Run these commands in the subscription hosting the gateway, which may differ from the Foundry
subscription:

```bash
az account set --subscription <target-subscription-id>
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state --output tsv
```

Repeat the status command until it returns `Registered`. Then refresh the resource provider:

```bash
az provider register --namespace Microsoft.Network --wait
```

Retry [Step 4](#step-4--deploy) with the same parameter file and secrets. This feature registration
is a recovery step for subscriptions reporting this error, not a prerequisite for every deployment.

Feature registration requires `Microsoft.Features/*` permissions at subscription scope, included
in the Contributor and Owner roles. If the status is `Pending`, registration may require Microsoft
approval, particularly for internal Azure subscriptions. Open an Azure support request with the
subscription ID, feature name, and deployment error; repeated deployments do not grant approval.
See [feature registration](https://learn.microsoft.com/azure/azure-resource-manager/management/preview-features)
and the [BYOIP registration guidance](https://learn.microsoft.com/en-us/answers/questions/1691016/registering-allowbringyourownpublicipaddress-featu).

## Step 1 — Collect your Foundry details

Record the existing account's name, subscription ID, and resource group. Foundry can be in a
different subscription from APIM; the template does not discover it across subscriptions.

The endpoint defaults to `https://<foundryAccountName>.openai.azure.com`. If **Keys and Endpoint**
shows a different URL, use that as the `foundryBackendBaseUrl` override.

Also record the model's **deployment name**, not its base model name. Clients send this as `model`.

## Step 2 — Clone the repo and generate keys

```bash
git clone https://github.com/microsoft/GitHub-Copilot-BYOK-with-APIM.git
cd GitHub-Copilot-BYOK-with-APIM
```

Generate one unique client key per organization and one separate Application Gateway secret.
Run either command once per secret. Both produce 32 random bytes as 64 hex characters.

**OpenSSL:**

```bash
openssl rand -hex 32
```

**PowerShell 7.2+ (no OpenSSL required):**

```powershell
[Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
```

Store the client keys in `orgKeys` and the gateway secret in `appGwSharedSecret` in the next step.
The gateway secret must contain at least 32 characters. Never reuse a client key as the gateway
secret, and keep the same values for redeployments unless intentionally rotating them.

## Step 3 — Set deployment parameters

Copy the [example parameters](../infra/example.bicepparam):

```bash
cp infra/example.bicepparam infra/my.bicepparam
```

### Required: edit seven settings

Edit these entries in `infra/my.bicepparam`; do not copy every parameter from the template:

| Parameter | Value |
| --- | --- |
| `apimName` | Globally unique APIM instance name |
| `apimPublisherEmail` | Contact email |
| `foundryAccountName` | Existing Foundry account name |
| `foundryAccountSubscriptionId` | Subscription ID containing the existing Foundry account, even if different from APIM's subscription |
| `foundryAccountResourceGroup` | Foundry resource group |
| `orgKeys` | Organization slug to client key; slugs use lowercase letters, numbers, and hyphens |
| `appGwSharedSecret` | Separate gateway secret from Step 2 |

Leave `deployAppGateway = true` in the starter file. The template also defaults to `true`.

Set `foundryAccountSubscriptionId` explicitly, even when Foundry and APIM share a subscription.
It scopes the backend resource ID and the APIM identity's role assignment; it is not inferred
from the account name or endpoint. If omitted outside the starter, it defaults to the APIM
deployment subscription.

### Inferred: leave these alone unless needed

| Setting | Default |
| --- | --- |
| `orgs` | Organization slugs from `orgKeys` |
| `appGwName` | `<apimName>-appgw` |
| `foundryBackendBaseUrl` | `https://<foundryAccountName>.openai.azure.com` |
| `appGwEnableHttps` | Enabled when `appGwHttpsPfxBase64` is supplied |

### Optional: add only what you need

| Parameter | Purpose |
| --- | --- |
| `apimSkuName` / `apimSkuCapacity` | APIM tier and units; defaults to `Developer` / `1` for testing |
| `orgModels` | Per-org model allowlists; omitted orgs or empty arrays are unrestricted |
| `perOrgRateLimitCalls` / `perOrgRateLimitRenewalPeriod` | Request limit per org; defaults to 300 calls per 60 seconds |
| `foundryProjectName` | Include the project's managed-compute deployments in `/models` |
| `extraModelIds` | Manually add callable deployments missing from discovery |
| `defaultTemperatureModelIds` | Normalize Chat Completions temperature to `1` for models that require it |

For all types, defaults, dependencies, and cost notes, see the
[parameter reference](parameters.md). Keep discovery API versions at their defaults; inference
uses `/openai/v1`. For AI feature examples, use the [AI Gateway guide](ai-gateway.md).

**Existing parameter files override defaults.** If upgrading from an older example, change
`deployAppGateway = false` to `true` and remove an explicit `appGwEnableHttps = false` when adding
your certificate. Preserve existing custom names, endpoints, and Foundry subscription and resource-group
settings. Deployments that previously omitted `deployAppGateway` will now add it; set `false` explicitly
only if you intend to run APIM without WAF.

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

### Confirm Application Gateway exists

Read the configuration summary:

```bash
az deployment group show \
  --resource-group <resource-group> \
  --name main \
  --query properties.outputs.deploymentSummary.value
```

Check `applicationGatewayEnabled: true`, the expected `applicationGatewayName`, and
`wafMode: "Detection"`. `httpsEnabled: false` is expected until the next section.
Use that gateway name in this resource check:

```bash
az network application-gateway show \
  --resource-group <resource-group> \
  --name <appgw-name> \
  --query "{state:provisioningState,sku:sku.name}"
```

Expect `state: "Succeeded"` and `sku: "WAF_v2"`. **Stop if the gateway is missing or disabled.**
Check `deployAppGateway` in the parameter file actually used by the deployment, then redeploy.

Read the public IP for DNS:

```bash
az deployment group show --resource-group <resource-group> --name main \
  --query properties.outputs.appGatewayPublicIp.value --output tsv
```

Complete HTTPS setup before sending keys or connecting Copilot. WAF starts in **Detection**
mode: it records matches but does not block requests. See [WAF tuning](traffic-flow.md#where-the-waf-is)
before enabling Prevention.

## (Production) Enable HTTPS on the App Gateway

Copilot BYOK requires HTTPS. After the first deployment:

1. **Configure DNS.** Create an `A` record pointing your hostname at `appGatewayPublicIp`.
   Confirm it resolves, for example with `nslookup copilot.example.com`.
2. **Obtain a certificate.** Follow [Get a Let's Encrypt certificate](lets-encrypt.md) for
   Windows/PowerShell instructions using Posh-ACME and DNS-01 validation. It generates a
   password-protected, full-chain PFX. You can also use another publicly trusted certificate.
3. **Base64-encode the PFX** using PowerShell:

   Use the full path to the generated `fullchain.pfx` in the command below. Run it from a private
   directory outside the repository so the base64-encoded private key is not saved in the repo.

   ```powershell
   $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('fullchain.pfx'))
   $b64 | Set-Content pfx.b64.txt
   ```

4. **Update** `infra/my.bicepparam`:

   ```bicep
   param appGwHttpsPfxBase64 = '<contents of pfx.b64.txt>'
   param appGwHttpsPfxPassword = '<the PFX password>'
   ```

5. **Redeploy** using the Step 4 command. HTTPS is inferred from the PFX; no enable flag is needed.
   Recheck `deploymentSummary`: both `applicationGatewayEnabled` and `httpsEnabled` must be `true`.
   Port 443 terminates TLS; port 80 redirects to HTTPS.

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

## Start or stop Application Gateway

Use the [PowerShell helper](../scripts/app-gateway.ps1) to start or stop an existing gateway.
Requires PowerShell 7.2+, Azure CLI, an `az login` session, and permission to read and
start/stop the gateway. Run from the repository root:

```powershell
$resourceGroup = '<gateway-resource-group>'
$gatewayName = '<appgw-name>'

.\scripts\app-gateway.ps1 -Action Start -ResourceGroup $resourceGroup -GatewayName $gatewayName
.\scripts\app-gateway.ps1 -Action Stop -ResourceGroup $resourceGroup -GatewayName $gatewayName

# Preview without changing the gateway:
.\scripts\app-gateway.ps1 -Action Stop -ResourceGroup $resourceGroup -GatewayName $gatewayName -WhatIf
```

The gateway name defaults to `<apimName>-appgw` at deployment unless `appGwName` is overridden.
Use the **gateway deployment's resource group**, not `foundryAccountResourceGroup` unless they
are the same. The helper requires both names explicitly; it does not read secrets from
`my.bicepparam`. To find the resource group in the current subscription:

```powershell
az network application-gateway list --query "[].{Name:name,ResourceGroup:resourceGroup,State:operationalState}" --output table
```

The helper uses your current Azure CLI subscription. Add `-SubscriptionId '<gateway-subscription-id>'`
to target another subscription without changing the CLI default. It supports `-Confirm`, skips
operations when the gateway is already in the requested state, and returns the gateway name,
resource group, operational state, and provisioning state. Operations can take several minutes;
the helper waits and verifies the resulting operational state. This does not verify backend health.
If the gateway is already starting or stopping, wait for that operation to finish and retry.

**Stopping interrupts all gateway traffic until you start it again.** This does not stop APIM,
Foundry, or other supporting resources, which can continue to incur charges.

## Troubleshooting

| Symptom | Check or fix |
| --- | --- |
| Application Gateway missing | Check the deployed `deployAppGateway` value, especially in older parameter files |
| Application Gateway stopped | Use the [start/stop helper](#start-or-stop-application-gateway) with `-Action Start` |
| HTTPS stays disabled after adding a PFX | Remove an explicit `appGwEnableHttps = false`; supply both PFX parameters and redeploy |
| Gateway secret validation fails | Set `appGwSharedSecret` to a stable random value of at least 32 characters |
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
