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
- **Agent requests need context capacity.** Model discovery and a small direct prompt can work
  while fixed instructions and enabled tools exceed the client's model budget. If diagnostics
  report that static context exceeds the usable budget, reduce unnecessary tools/instructions
  or select a larger-context model. See [client context troubleshooting](traffic-flow.md#5-direct-inference-works-but-copilot-still-reports-no-response).

## Context windows and client token budgets

Application Gateway and APIM do not increase a model's context capacity. The effective
budget also depends on the limits advertised to the client. An enterprise-managed model's
picker name and underlying deployment name can differ, and a larger backend model does
not help if the client still advertises the same smaller prompt budget.

For an **individually configured VS Code Custom Endpoint**, the model entry in
`chatLanguageModels.json` supports `contextWindow` (input plus output) and
`maxOutputTokens`. When `maxInputTokens` is omitted, VS Code derives it as
`contextWindow - maxOutputTokens`. For example, these token properties reserve 8,192
output tokens within a verified 128,000-token model window:

```json
{
  "contextWindow": 128000,
  "maxOutputTokens": 8192
}
```

Merge these properties into the appropriate Custom Endpoint model entry, retaining its
ID, URL, and other settings. This allows at most 119,808 input tokens; the client may
reserve additional headroom. Verify the selected deployment's real limits first.
Do not remove a limit or advertise a larger window than the backend supports.

These fields apply to that local Custom Endpoint entry, **not** an enterprise-managed
Copilot model or another agent provider's catalog. Do not assume a local edit overrides
limits shown for an enterprise-managed model. Check the limits actually reported by the
client and whether its provider exposes a supported configuration control.

For **standalone Copilot CLI with a locally configured BYOK provider**, GitHub documents
`COPILOT_PROVIDER_MODEL_ID` for identifying model capabilities, and optional
`COPILOT_PROVIDER_MAX_PROMPT_TOKENS` / `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS` overrides.
For the same verified 128,000-token window and 8,192-token output allocation:

```powershell
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = '119808'
$env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = '8192'
```

These are additional settings for the direct-provider configuration above, not a
verified override for enterprise-managed models in the Insiders CLI-backed agent.
Raising the declared budget may still be insufficient if fixed tools/instructions
exceed it; use a genuinely larger-context model/provider configuration or reduce
optional static context.

References: [VS Code Custom Endpoint configuration](https://code.visualstudio.com/docs/agent-customization/language-models#_custom-endpoint-configuration-reference)
and [Copilot CLI BYOK configuration](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models).

## Insiders client-engine verification

VS Code Insiders can offer both standard local Copilot Chat and a CLI-backed Agent Host.
They are different client engines, even when the picker shows the same enterprise model.
If direct inference works but the CLI-backed session fails, compare the same model in a
new standard local chat before changing Azure or model limits.

A separate `.code-workspace` file can open the same repository with these workspace-only
settings, without copying code or changing global preferences:

```json
{
  "chat.editor.preferCopilotHarness": false,
  "chat.defaultToCopilotHarness": false,
  "chat.editor.localAgent.enabled": true
}
```

These are experimental engine-selection settings, not context-window settings. Check
their descriptions in the installed Insiders build, and create a **new** chat rather
than resuming an existing CLI-backed session. This is a diagnostic/workaround path, not
a claim that an underlying CLI-backed client defect has been fixed.

If that comparison exposes a concrete upstream request error instead, fix the API
compatibility issue. For example, the current gateway normalizes legacy `max_tokens`
automatically for all models using the Foundry OpenAI chat contract; no model-name
exception list is required. See [chat request compatibility](traffic-flow.md#chat-request-parameter-compatibility).
