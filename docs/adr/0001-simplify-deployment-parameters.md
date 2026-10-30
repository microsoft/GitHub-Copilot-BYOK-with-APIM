# ADR 0001: Simplify deployment parameters

- **Status:** Accepted
- **Date:** 2026-10-22

## Context

A client completed installation without Application Gateway. Both the template and example
defaulted to `deployAppGateway = false`, despite the documented architecture including it.

The example also exposed 69 parameter assignments, mixing required inputs, repeated defaults,
and optional features. Organization slugs appeared in both `orgs` and `orgKeys`, creating
another opportunity for configuration drift.

## Decision

Make the default deployment match the documented Application Gateway + APIM architecture.
Keep advanced overrides, but remove them from the starter configuration unless needed.

### Reduce the starter configuration

The [starter file](../../infra/example.bicepparam) now contains eight assignments: seven values
to fill in, plus an explicit `deployAppGateway = true`:

- `apimName`
- `apimPublisherEmail`
- `foundryAccountName`
- `foundryAccountSubscriptionId`
- `foundryAccountResourceGroup`
- `orgKeys`
- `appGwSharedSecret`

Optional AI features remain off. Existing parameter names remain supported.

Keep the Foundry subscription ID explicit because the existing account can be in a different
subscription from APIM. It scopes the backend resource ID and the APIM identity's role assignment;
the account name and endpoint do not trigger cross-subscription discovery. The template retains
its deployment-subscription default for compatibility, but the starter does not rely on it.

### Separate setup from advanced configuration

- Keep a few common overrides commented out in the starter: APIM tier, model allowlists,
  and Foundry project discovery, alongside endpoint and certificate settings.
- Document every supported parameter in the grouped [parameter reference](../parameters.md),
  including its type, default, dependencies, and cost implications.
- Keep [Getting started](../getting-started.md) focused on the recommended deployment path.
  Use [feature guides](../ai-gateway.md) for working examples and verification.

Defaults belong in the template. Omit unused overrides rather than copying their defaults into
parameter files. Commented examples aid discovery; they are not a second parameter catalog.

### Derive values instead of repeating them

| Parameter | New default |
| --- | --- |
| `deployAppGateway` | `true`; APIM-only deployments explicitly opt out |
| `orgs` | Organization slugs from `objectKeys(orgKeys)` |
| `appGwName` | `<apimName>-appgw` |
| `foundryBackendBaseUrl` | `https://<foundryAccountName>.openai.azure.com` |
| `appGwEnableHttps` | Enabled when `appGwHttpsPfxBase64` is supplied |

These are defaults, not resource discovery. Custom endpoints and resource names still require
explicit overrides. Foundry subscription and resource-group defaults remain unchanged.

Each organization retains its own gateway key, endpoint, policies, attribution, and limits.
An explicit `orgs` array can still select a subset of the organizations in `orgKeys`.

### Keep secrets explicit and report configuration errors

- Generate a distinct client key per organization and a separate gateway secret using the
  [OpenSSL or PowerShell commands](../getting-started.md#step-2--clone-the-repo-and-generate-keys).
  Preserve them across redeployments unless intentionally rotating them.
- Require a gateway secret of at least 32 characters when Application Gateway is enabled.
- Require Application Gateway and both PFX values when HTTPS is enabled.
- Do not generate or rotate secrets automatically.

APIM continues to authenticate to Foundry with managed identity. Organization keys are gateway
credentials, not Foundry backend keys.

### Verify the deployed topology

Expose a non-secret `deploymentSummary` output reporting gateway enablement, name, resource ID,
HTTPS enablement, WAF mode, and organization slugs. The
[setup guide](../getting-started.md#confirm-application-gateway-exists) also checks that the
gateway resource exists with `Succeeded` status and the `WAF_v2` SKU.

## Consequences

- New deployments include Application Gateway and its Azure charges by default.
- Deployments that previously omitted `deployAppGateway` now add it. Explicit `false` values
  still select APIM-only operation without WAF.
- The first deployment remains HTTP-only until certificate settings are supplied. Clients
  must not send keys or connect Copilot before HTTPS is verified.
- WAF still starts in Detection mode; enabling the gateway does not enable blocking.
- APIM remains public. The gateway-secret policy is not network isolation.
- The starter makes the Foundry account's subscription explicit rather than silently assuming
  the APIM deployment subscription.
- Advanced settings remain discoverable without making the starter a wall of configuration.
  Template parameter changes must be reflected in the reference.

## Migration

1. Review the parameter file actually used for deployment. Change an old
   `deployAppGateway = false` only when adopting the gateway topology.
2. Supply a stable gateway secret meeting the new minimum length.
3. Supply both PFX values and remove an explicit `appGwEnableHttps = false` to use HTTPS inference.
4. Preserve existing custom gateway names and endpoints. Keep `foundryAccountSubscriptionId`
   and `foundryAccountResourceGroup` set to the existing Foundry account's location; do not replace
   a cross-subscription value with the APIM deployment subscription.
5. Recheck the gateway resource and summary. Both gateway and HTTPS enablement must be `true`
   before connecting Copilot through Application Gateway.

## Alternatives considered

- **Documentation only:** leaves the misleading default in place.
- **Enable the gateway only in the example:** preserves older automation behavior, but leaves
  direct template deployments inconsistent with the documented baseline.
- **Remove advanced parameters:** simplifies the interface but breaks existing customization.
- **Hide the Foundry subscription in optional overrides:** makes separate-subscription setups
  easy to misconfigure. Keep the template default for compatibility, but expose the starter input.
- **Comment out every parameter in the starter:** preserves the wall of settings, duplicates
  documentation, and encourages unnecessary overrides that can drift from template defaults.

## Scope and validation

Implemented in [the Bicep template](../../infra/main.bicep) and
[generated ARM template](../../infra/main.json), with
[offline regression checks](../../tests/deployment-contract.ps1).

The checks require every parameter to appear exactly once in the reference with a matching type
and default. They also compile the starter both as provided and with its commented overrides
enabled. Documentation links and heading anchors are checked separately.

API-version defaults are unchanged. Deprecating the redundant `foundryApiVersion` setting was
discussed but is not part of this decision.
