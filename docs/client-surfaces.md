# Where this configuration applies

The APIM proxy in this repo is fronted by an **Application Gateway (WAF_v2)** and published as an
OpenAI **Chat Completions** endpoint, with a separate path **per organization**. Clients point at
the gateway front door — `https://<gateway-host>/byok/<org>`, where `<gateway-host>` is the App
Gateway's HTTPS custom domain (deployment output `appGatewayFrontendUrl`). The gateway preserves
the `/byok/<org>` path and injects the shared `X-AppGw-Secret` header; the APIM FQDN
(`https://<apim-name>.azure-api.net`) is the gateway's backend only and returns **403** to callers
that hit it directly. Any Copilot surface that supports a BYOK / OpenAI-compatible provider can
point at one of those paths. If you haven't deployed the gateway yet, follow the
[getting started guide](getting-started.md) first.

There are two distinct BYOK paths:

- **Individual BYOK** — a single user adds the endpoint in VS Code or the CLI. Per-user, no admin required.
- **Enterprise BYOK** — an enterprise admin registers the endpoint on GitHub.com; the models then appear for the scoped org across GitHub.com, the CLI, and IDEs. (Public preview.)

> **Intended scenario.** This gateway is **multi-tenant by organization**: each org gets its
> own path, key, and policy on one shared APIM instance, so you can attribute and throttle
> **per org**. The presented key is bound to its org's path, so callers cannot shift cost by
> repointing at another org's URL. The boundary is the **organization**, not the individual
> user or sub-org team — see
> [Per-organization multi-tenant BYOK](reference-architecture.md#per-organization-multi-tenant-byok).

## Summary

| Surface | BYOK path | Provider option | Point it here |
| --- | --- | --- | --- |
| VS Code | Individual | **Custom Endpoint** with Chat Completions or Responses | `https://<gateway-host>/byok/<org>` |
| Copilot CLI | Individual | `COPILOT_PROVIDER_TYPE=openai` | `https://<gateway-host>/byok/<org>` |
| GitHub.com (+ CLI/IDEs) | Enterprise | **OpenAI-compatible provider** under AI controls, scoped per org | `https://<gateway-host>/byok/<org>` |

In every case the API key is that **org's client key** (`byokKey-<org>`), and the model
identifier is your **Foundry deployment name**. The gateway adds the backend token and
`api-version`.

## VS Code

1. Open the Chat view, open the model picker, and select **Manage Language Models** (or run **Chat: Manage Language Models**).
2. Select **Add Models**, then choose **Custom Endpoint**. The older OpenAI Compatible provider is deprecated and only uses Chat Completions.
3. Configure:
   - Base URL / endpoint: `https://<gateway-host>/byok/<org>`
   - API key: that org's client key
   - Model: your Foundry deployment name
   - API type: **Responses** for models that combine reasoning with function tools; otherwise choose the API type supported by the model
4. Select the model from the model picker.

For an explicit Responses configuration in `chatLanguageModels.json`, set the model URL to
`https://<gateway-host>/byok/<org>/responses` and set `"apiType": "responses"`. This is
required when a model rejects function tools plus `reasoning_effort` on `/chat/completions`.

BYOK in VS Code applies to **chat and agent** features only. Inline code completions and
embeddings still use GitHub-hosted models.

See [AI language models in VS Code](https://code.visualstudio.com/docs/agent-customization/language-models).

## Copilot CLI

```bash
export COPILOT_PROVIDER_TYPE=openai
export COPILOT_PROVIDER_BASE_URL=https://<gateway-host>/byok/<org>
export COPILOT_PROVIDER_API_KEY=<that-org-client-key>
export COPILOT_MODEL=<your-foundry-deployment-name>
copilot
```

Copilot appends `/chat/completions` to the base URL, which matches the proxy operation.

See [Using your own LLM models in GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models).

## GitHub.com (enterprise only)

An enterprise owner registers **one entry per org** — GitHub requires a separate API key per
deployment URL — and scopes each to the matching organization. The models then become
available in Copilot Chat on GitHub.com as well as in the CLI and IDEs, for that org only.

1. On GitHub.com, go to your enterprise, then **AI controls** → **Copilot** → **Configure allowed models** → **Custom models**.
2. **Add API key** for an **OpenAI-compatible provider**. Set the **Deployment URL** to `https://<gateway-host>/byok/<org>` and paste that org's client key. (Repeat once per org — different URLs cannot share a key.)
3. Add the model(s) to expose, identified by the Foundry deployment name.
4. On the model's **Access** tab, choose **Choose per organization** and select only the matching org (or **Allow for all organizations** if the model is shared).
5. For IDE use, ensure the **Bring Your Own Language Model Key in VS Code** policy is enabled in the [Copilot policy settings](https://github.com/settings/copilot/features).

Because GitHub injects the key server-side and scopes visibility per organization, members
can neither extract another org's key nor select a model that wasn't scoped to them.

Supported enterprise providers include Anthropic, AWS Bedrock, Google AI Studio,
Microsoft Foundry, OpenAI, **OpenAI-compatible providers**, and xAI — this proxy
registers as an OpenAI-compatible provider.

See [Using your LLM provider API keys with Copilot](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-enterprise/use-your-own-api-keys).

## Cross-surface caveats

- **Completions are never BYOK.** Inline code completions always use GitHub-hosted models. BYOK covers chat, agent, and utility tasks.
- **Org, not user or team.** Attribution and scoping are per **organization**. Several teams inside one org cannot be separated through the enterprise picker; use the individual surfaces for sub-org separation.
- **Enterprise BYOK is public preview** and subject to change.
- **Reasoning models may require Responses.** If a model returns `400` saying function tools with
   `reasoning_effort` are unsupported on `/v1/chat/completions`, configure that VS Code model as a
   Custom Endpoint with `apiType: "responses"`; do not disable reasoning globally at the gateway.
- **Some models require the default temperature.** If a model rejects a value such as
   `temperature: 0.1`, add its deployment id to `defaultTemperatureModelIds` and redeploy. APIM
   rewrites client-supplied temperatures to `1` only for those Chat Completions models.
- **Use a least-privilege key.** Here that is the per-org client key, not a backend Foundry key.
