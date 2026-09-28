# GitHub Copilot BYOK with APIM

A reference implementation for serving your own Microsoft Foundry model to GitHub Copilot, fronted by an **Application Gateway (WAF_v2)** and **Azure API Management** that provide a hardened public entry point plus centralized authentication, routing, and governance — built on Copilot's BYOK capability.

![Architecture diagram of GHCP with BYOK](assets/ghcp_byok_architecture.png)

## Table of contents

- [GitHub Copilot BYOK with APIM](#github-copilot-byok-with-apim)
  - [Table of contents](#table-of-contents)
  - [Solution overview](#solution-overview)
  - [Where this applies](#where-this-applies)
  - [Why GitHub orgs are the Azure-level identity](#why-github-orgs-are-the-azure-level-identity)
  - [Deploying model and configure GitHub portal](#deploying-model-and-configure-github-portal)
    - [1. Deploy Azure resources (WAF, APIM, and Foundry backend)](#1-deploy-azure-resources-waf-apim-and-foundry-backend)
      - [Model requirements](#model-requirements)
      - [How this fits GitHub Copilot BYOK](#how-this-fits-github-copilot-byok)
    - [2. Configuring custom models in the GitHub portal](#2-configuring-custom-models-in-the-github-portal)
      - [Add API keys](#add-api-keys)
      - [Configure added models](#configure-added-models)
  - [Documentation](#documentation)
  - [Notes](#notes)
  - [Useful docs](#useful-docs)
  - [Contributors](#contributors)
  - [Acknowledgements](#acknowledgements)
  - [License](#license)

## Solution overview
**The scenario:** one shared stack — **App Gateway → APIM → Foundry** — that is **multi-tenant by GitHub organization**. APIM publishes a **separate path, key, and policy per org** (`/byok/<org>`); the App Gateway terminates TLS, applies WAF rules, and blocks direct-to-APIM bypass so every request enters through the front door. Each org registers its own OpenAI-compatible provider (scoped to that org in GitHub's AI controls) and its callers present that org's key, so you can **attribute, throttle, and rotate credentials per organization** on one gateway. The boundary is the **organization**, not the individual user or a sub-org team — per-user identity is out of scope.

Use this when you want to bring your own model to Copilot but still need to:

- **Keep backend keys out of clients.** Copilot authenticates to APIM; APIM authenticates to Foundry with managed identity. No Foundry keys in the repo, env vars, or developer machines.
- **Front it with a hardened entry point.** An Application Gateway (WAF_v2) terminates TLS, runs OWASP WAF rules, and forwards a shared secret header so APIM only accepts traffic that came through the gateway.
- **Expose one stable endpoint per org.** An OpenAI-compatible `/byok/<org>` URL that works across VS Code, the Copilot CLI, and GitHub.com (enterprise BYOK).
- **Govern access centrally.** A policy layer for routing, versioning, throttling, and future request transforms — and a single place to swap or upgrade the model.
- **Deploy it repeatably.** Bicep IaC so the same gateway path stands up consistently across dev, test, and prod.

Resilience (circuit breaker, load-balanced pool) plus token limits, token metrics, content safety, and semantic caching are **opt-in AI Gateway capabilities** — all off by default — see the [reference architecture](docs/reference-architecture.md#ai-gateway-capabilities-opt-in).

## Where this applies

The proxy is an OpenAI Chat Completions endpoint, so any Copilot BYOK surface can use it. Clients
point at the **App Gateway front door** — `https://<gateway-host>/byok/<org>`, where
`<gateway-host>` is the gateway's HTTPS custom domain (deployment output `appGatewayFrontendUrl`).
The gateway preserves the `/byok/<org>` path and injects the `X-AppGw-Secret` header; the APIM FQDN
(`https://<apim-name>.azure-api.net`) is the gateway's backend only and rejects direct hits with
**403**. In every case the API key is **that org's client key** (a per-org bearer secret validated
in policy against the `byokKey-<org>` named value — *not* an APIM subscription key) and the model is
your **Foundry deployment name**.

| Surface | BYOK path | Provider option | Point it here |
| --- | --- | --- | --- |
| VS Code | Individual | **Custom Endpoint** with Chat Completions or Responses | `https://<gateway-host>/byok/<org>` |
| Copilot CLI | Individual | `COPILOT_PROVIDER_TYPE=openai` | `https://<gateway-host>/byok/<org>` |
| GitHub.com (+ CLI/IDEs) | Enterprise | **OpenAI-compatible provider** under AI controls, scoped per org | `https://<gateway-host>/byok/<org>` |

Full per-surface steps are in [docs/client-surfaces.md](docs/client-surfaces.md). Note that BYOK covers chat/agent only — inline code completions always use GitHub-hosted models.

## Why GitHub orgs are the Azure-level identity

The `/byok/<org>` path is **only routing** — the credential is the per-org key. Each org's policy
compares the inbound bearer token against **its own** `byokKey-<org>` secret and nothing else, so
pointing at another org's URL without that org's key returns **401**. The path and the key are
bound together; the path alone grants nothing.

This mirrors how GitHub enterprise BYOK works, which is why the org is the right Azure-level unit:

- **GitHub BYOK is 1:1 URL↔key.** A provider registration is a single deployment URL plus a single
  key. Giving each org its own `/byok/<org>` URL and key matches that model exactly — one
  registration per org, cleanly separated.
- **Access scopes to the org.** Enterprise owners register a provider and scope it with
  **Access → Choose per organization**. The org is the smallest unit GitHub lets you scope a BYOK
  provider to, so it is the boundary the platform actually enforces.
- **Server-side key injection makes it stick.** Clients never hold the Foundry credential — APIM
  injects the managed-identity token after validating the org key. The only thing an org proves is
  "I hold org X's key," which the gateway then maps to org X's routing, rate limit, and attribution.

The result: **per-org attribution, throttling, and rotation on one shared gateway**, with the
identity enforced by a credential the org controls rather than by a guessable path. The boundary is
the organization — not individual users, and not sub-org teams.

## Deploying model and configure GitHub portal

### 1. Deploy Azure resources (WAF, APIM, and Foundry backend)
New here? Follow the **[step-by-step getting started guide](docs/getting-started.md)** for
prerequisites, parameters, and verification. The short version:

```bash
az deployment group create --resource-group <resource-group> --template-file infra/main.bicep --parameters infra/example.bicepparam
```

#### Model requirements

Per the Copilot BYOK docs, the Foundry deployment you target must:

- support **tool calling** (function calling)
- support **streaming**
- ideally provide a context window of **≥128k tokens**

If the model lacks tool calling or streaming, Copilot CLI returns an error.

#### How this fits GitHub Copilot BYOK

How the project maps to the public GitHub Copilot BYOK documentation:

- **Approach is supported.** Copilot BYOK explicitly allows OpenAI-compatible endpoints, and an APIM gateway in front of Foundry is exactly that.
- **Auth model is split correctly.** The client authenticates to APIM with a key; APIM authenticates to Foundry with managed identity. Backend keys stay out of the client and the repo.
- **Provider type is `openai`, not `azure`.** With the `azure` provider type, Copilot builds the path `/openai/deployments/<deployment>/chat/completions`, which this proxy does not expose. The `openai` type targeting `/byok` is the intended fit.
- **Responses wire API.** Newer models (e.g. `o3`, `gpt-4.1`) use the Responses API, where Copilot calls `/responses` instead of `/chat/completions`. The proxy exposes both operations; `/responses` is forwarded to the Foundry backend at `/openai/v1/responses` using the same auth and routing as `/chat/completions`.
- **Model discovery.** Copilot's config flow calls `GET /models` to populate its model picker. The proxy answers this itself and returns only the models actually deployed on your Foundry instance — not the full Foundry catalog — in OpenAI list-models format. It merges two live sources (deduped): the Foundry **account** deployments (data-plane `GET /openai/deployments`) for standard deployments, and, when `foundryProjectName` is set, the Foundry **project** deployments (`GET .../services.ai.azure.com/api/projects/<project>/deployments`, `ai.azure.com` audience) which surface **managed-compute** models (e.g. Cohere/HuggingFace catalog models) that do not appear in the account listing. Both queries use the APIM managed identity. The result is **zero-touch**: deploy a new model — standard or managed-compute — and it appears automatically, no code or redeploy. Each deployment `id` is the value clients pass as `model`. To scope models per org, set `orgModels[<slug>]` to an allowlist: that org's `/models` is filtered to those ids and any chat/responses call for another model is rejected with `403`. Orgs without an entry stay unrestricted.
- **Inbound auth.** OpenAI-compatible clients send the key as `Authorization: Bearer <key>`, which APIM's built-in subscription check never sees (it only reads `Ocp-Apim-Subscription-Key`/`subscription-key`, and that check runs before policy). So the API keeps `subscriptionRequired: false` and each org's inbound policy instead extracts the bearer token and validates it against that org's `byokKey-<org>` secret named value, returning 401 on mismatch. Set a strong, unique secret per org in `orgKeys` and hand each value to that org's clients as their API key.

### 2. Configuring custom models in the GitHub portal

Once the gateway is deployed, we can register it as a custom model provider for your enterprise in the GitHub portal. This makes the models available to in Copilot Chat, Copilot CLI, and IDEs.

> [!NOTE]
> Custom models (BYOK) for organizations is in **public preview** and subject to change.

**Prerequisites:** An enterprise owner must have enabled custom models at the enterprise level, under **AI controls → Copilot → Features → Enable custom models**.

![Enable custom models](assets/ghportal_custom_models_enable.png)

#### Add API keys
1. In the upper-right corner of GitHub, click your profile picture, then click **Enterprise**.

2. In the top mene, Select **AI Controls** and then select **Copilot** from the left-menu.

4. Click **Configure allowed models** and then select the **Custom models** tab.

   ![Copilot custom models page](assets/ghportal_custom_models.png)

5. Above the Custom models list, click the green **Add API key** button.

6. Complete the **Add API key** form using the fields below.

   !["Add API key" form](assets/ghportal_custom_models_add.png)

   | Field | Value |
   | --- | --- |
   | **Provider** | Select **OpenAI Compatible**. |
   | **Name** | A display name for this key. It's shown in the model picker, so use something recognizable per org (e.g. `team-alpha`). |
  | **API key** | The org's inbound API key — the strong, unique secret you set for this org in `orgKeys` (the value validated against `byokKey-<org>`). |
   | **Base API URL** | The gateway's `/byok/<org>` endpoint at the App Gateway front door (for example, `https://<gateway-host>/byok/team-alpha`). Each org uses its own path and key, so create a separate API key entry per org. |
   | **Available models** | Click **Fetch new models** to populate the list from the gateway's `/models` response, then select the models to make available under this key. |

7. Click **Save**.

#### Configure added models
Now we will configure model capabilities and access.
1. In the **General** tab, click **Configure** next to the newly added API key.

2. Set the **Display name** (this is what will appear in the model picker), **Endpoint type** and **Capabilities** for your model.

   !["Configure added models" form](assets/ghportal_custom_models_configure.png)

3. In the **Access** tab we can select which organizations can use this model.

   !["Configure model access" form](assets/ghportal_custom_models_access.png)

4. Click **Save**.

The custom models have been added and will appear in your organization's model picker in ~5 minutes.

For full details, see [Enabling custom models for GitHub Copilot in your organization](https://docs.github.com/en/enterprise-cloud@latest/copilot/how-tos/administer-copilot/manage-for-organization/enable-custom-models#adding-your-key-to-an-organization-account).

## Documentation

- **[Getting started](docs/getting-started.md)** — step-by-step guide to deploy the gateway and point a Copilot surface at it.
- **[Traffic flow and WAF placement](docs/traffic-flow.md)**: plain-language walkthrough of DNS, TLS,
  Application Gateway, WAF inspection, APIM authorization, Foundry routing, and the deployed HTTPS setup.
- **[AI Gateway capabilities](docs/ai-gateway.md)** — enable-and-use runbook for token limits, token metrics/dashboard, content safety, semantic caching, and the multi-Foundry pool.
- **[Reference architecture](docs/reference-architecture.md)** — how the App Gateway, APIM, and Foundry fit together, the per-org security model, and the opt-in AI Gateway capabilities.
- **[Client surfaces](docs/client-surfaces.md)** — per-surface configuration for VS Code, the Copilot CLI, and enterprise BYOK on GitHub.com.
  
## Notes

- The Foundry/OpenAI resource is expected to already exist.
- APIM reaches Foundry through a named **backend entity** (`foundry-backend`) and authenticates with its system-assigned managed identity, which holds the `Foundry User` role.
- The policy validates the client key, attaches the managed-identity token, and routes OpenAI-compatible chat completion calls to the backend entity.
- The `/models` operation is served entirely within APIM: it merges the Foundry **account** deployments and (when `foundryProjectName` is set) the Foundry **project** deployments, deduped, and returns them in OpenAI list-models format — so Copilot's model picker reflects the real deployments rather than the whole catalog. The account query catches standard deployments; the project query catches managed-compute deployments (which are absent from the account listing). New models of either kind appear automatically with no redeploy. Tune the lookups with `foundryDeploymentsApiVersion` (default `2023-03-15-preview`) and `foundryProjectDeploymentsApiVersion` (default `2025-05-01`). `extraModelIds` remains as a manual safety net for anything neither query returns.
- **Opt-in AI Gateway capabilities.** Token limits/quotas (`llm-token-limit`), per-org token metrics (`llm-emit-token-metric`), content safety (`llm-content-safety`), semantic caching (`llm-semantic-cache-*`), and a circuit-broken multi-Foundry load-balanced pool (`foundryBackends`) can each be enabled with a single parameter; all are off in the default deployment. See the [reference architecture](docs/reference-architecture.md#ai-gateway-capabilities-opt-in).
- **Enterprise BYOK is public preview** and subject to change.

## Useful docs

- [AI language models in VS Code (BYOK)](https://code.visualstudio.com/docs/agent-customization/language-models#_bring-your-own-language-model-key)
- [GitHub Copilot CLI — Using your own LLM models (BYOK)](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models)
- [Enterprise — Using your LLM provider API keys with Copilot](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-your-own-api-keys)
- [Azure API Management AI gateway](https://learn.microsoft.com/en-us/azure/api-management/genai-gateway-capabilities)
- [Import a Microsoft Foundry API](https://learn.microsoft.com/en-us/azure/api-management/azure-ai-foundry-api)
- [Application Gateway WAF (WAF_v2)](https://learn.microsoft.com/en-us/azure/web-application-firewall/ag/ag-overview)

## Contributors

<a href="https://github.com/vallentyne"><img src="https://github.com/vallentyne.png" width="64" height="64" style="border-radius:50%" alt="vallentyne" /></a>
<a href="https://github.com/jasonmoodie"><img src="https://github.com/jasonmoodie.png" width="64" height="64" style="border-radius:50%" alt="jasonmoodie" /></a>
<a href="https://github.com/aj-enns"><img src="https://github.com/aj-enns.png" width="64" height="64" style="border-radius:50%" alt="aj-enns" /></a>


## Acknowledgements
[ghcp-byok-apim: A reference implementation for serving your own Microsoft Foundry model to GitHub Copilot, with Azure API Management providing centralized authentication, routing, and governance — built on Copilot's BYOK capability](https://github.com/Frank802/ghcp-byok-apim) by **Frank802**.

## License
MIT License. See [LICENSE](LICENSE.txt) for details.