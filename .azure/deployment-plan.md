# Azure Deployment Plan

> **Status:** Validated

Generated: 2026-09-09

---

## 1. Project Overview

**Goal:** Vet the repository's documented GitHub Copilot BYOK per-organization AI Gateway deployment in a new MCAPS tenant before a customer deploys it.

**Path:** Redeploy existing Bicep solution with tenant-specific parameters; do not redesign the template.

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Development / customer-vetting environment |
| Scale | Small |
| Budget | Cost-optimized while preserving the current test configuration |
| Tenant | `83d77135-b29d-4c2a-b0fc-c971781c5e66` |
| Foundry subscription | `ME-MngEnvMCAP987131-ajenns-1` (`2dcbcaee-5167-49dc-8f81-fcab16979241`) |
| Gateway subscription | `ME-MngEnvMCAP987131-ajenns-3` (`a08cafe6-0a04-4fd4-a981-b75bd0c7f223`) |
| Location | `eastus2` |
| Foundry resource group | `rg-987131-foundry` |
| Gateway resource group | `rg-ghcp-byok` |

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Gateway infrastructure | IaC | Bicep | `infra/main.bicep` |
| APIM policies | Gateway policy | XML | `infra/policies/` |
| Proxy contract | API schema | OpenAPI 3 | `infra/openapi/byok-proxy.openapi.json` |
| Observability | IaC module | Bicep | `infra/modules/observability.bicep` |
| Foundry RBAC | IaC module | Bicep | `infra/modules/foundry-access.bicep` |

## 4. Recipe Selection

**Selected:** Azure CLI + resource-group-scoped Bicep.

**Rationale:** This is the repository's documented deployment path. Foundry is an explicit pre-existing dependency of `infra/main.bicep`; it and its model deployments are created first, then the gateway template is deployed unchanged with an ignored local parameter file.

## 5. Architecture

```text
GitHub Copilot BYOK
	|
	v
APIM Developer (ajenns-3 / rg-ghcp-byok)
	|
	| system-assigned managed identity + Foundry User
	v
Foundry AIServices S0 (ajenns-1 / rg-987131-foundry)
	|
	+-- gpt-5-mini 2025-08-07 (GlobalStandard)
	+-- gpt-4o 2024-11-20 (GlobalStandard)
	+-- gpt-5.6-sol 2026-07-09 (GlobalStandard)
	+-- gpt-6-astra 2026-09-03 (GlobalStandard)
```

| Component | Azure Service | Configuration |
|-----------|---------------|---------------|
| AI backend | Microsoft Foundry / AIServices | `ghcp-byok-foundry-987131`, S0, public endpoint, East US 2 |
| Gateway | API Management | `ghcp-byok-apim-987131`, Developer, capacity 1 |
| Monitoring | Log Analytics | New workspace, PerGB2018, 30-day retention |
| APM | Application Insights | Workspace-based |
| Front door | Application Gateway WAF | Disabled for this vetting deployment, matching current local configuration |
| Tenant route | APIM API + policies | `covenantcoders`, fresh 256-bit client key |
| Model allowlist | APIM policy | `gpt-5-mini`, `gpt-4o`, `gpt-5.6-sol`, `gpt-6-astra` |

## 6. Provisioning Limit Checklist

| Subscription | Resource Type | Number to Deploy | Current | Total After | Limit/Quota | Result |
|--------------|---------------|------------------|---------|-------------|-------------|--------|
| ajenns-1 | `Microsoft.CognitiveServices/accounts` AIServices S0 | 1 | 0 | 1 | 100 | Pass |
| ajenns-1 | `gpt-4o` GlobalStandard TPM (thousands) | 10 | 0 | 10 | 450 | Pass |
| ajenns-1 | `gpt-5-mini` GlobalStandard TPM (thousands) | 10 | 0 | 10 | 1000 | Pass |
| ajenns-1 | `gpt-5.6-sol` GlobalStandard TPM (thousands) | 150 | 0 | 150 | Deployment succeeded | Pass |
| ajenns-1 | `gpt-6-astra` GlobalStandard TPM (thousands) | 150 | 0 | 150 | Deployment succeeded | Pass |
| ajenns-3 | `Microsoft.ApiManagement/service` | 1 | 0 | 1 | No quota limitation reported | Pass |
| ajenns-3 | `Microsoft.OperationalInsights/workspaces` | 1 | 1 policy-managed | 2 | No quota limitation reported | Pass |
| ajenns-3 | `Microsoft.Insights/components` | 1 | 0 | 1 | No quota limitation reported | Pass |

Quota source: live subscription quota and model catalog queries on 2026-09-09 plus successful deployment state on 2026-09-10. Proposed Foundry and APIM names were also confirmed globally available.

## 7. Prerequisites and Risks

- `Microsoft.ApiManagement` is registered in ajenns-3.
- Azure CLI is authenticated as the tenant-native account `ajenns@MngEnvMCAP987131.onmicrosoft.com` (object ID `3b9bbdac-cded-40b1-8f7a-71821d7df4d1`). Its inherited Owner assignment permits `Microsoft.Authorization/roleAssignments/write` in both subscriptions.
- `infra/main.bicep` creates the APIM managed identity and assigns `Foundry User` on the cross-subscription Foundry account. This remains part of the customer-vetting design.
- APIM Developer is not a production SKU. It is appropriate for vetting but the customer must choose a production SKU and resiliency design separately.
- Application Gateway WAF remains disabled for parity with the current local vetting parameters. This means APIM is the public endpoint in this deployment.
- Model usage incurs consumption charges. Global Standard capacity is a quota allocation, not reserved-throughput billing. Model deployment lifecycle is user-managed for this vetting environment.

## 8. Execution Checklist

### Preparation

- [x] Authenticate Azure extension and Azure CLI to the new tenant
- [x] Confirm Foundry and gateway subscriptions
- [x] Confirm East US 2
- [x] Inventory both subscriptions
- [x] Confirm model versions, SKU support, and quota
- [x] Confirm globally unique Foundry and APIM names
- [x] Compile `infra/main.bicep`
- [x] Obtain explicit plan approval

### Foundry Prerequisite

- [x] Target ajenns-1 explicitly on every Foundry command
- [x] Create `rg-987131-foundry` in East US 2
- [x] Create `ghcp-byok-foundry-987131` as AIServices S0
- [x] Verify four user-managed Global Standard deployments
- [x] Verify account endpoint and deployment states

### Gateway Preparation and Validation

- [x] Register `Microsoft.ApiManagement` in ajenns-3
- [x] Create `rg-ghcp-byok` in East US 2
- [x] Generate a fresh `covenantcoders` key
- [x] Update ignored `infra/my.bicepparam` only; do not change solution Bicep for tenant values
- [x] Parse all policy XML/fragments
- [x] Build Bicep and tenant parameters
- [x] All validation checks pass
	- [x] Core validation: CLI, auth, Bicep build, ARM validation, and resource-group what-if via the shared `validate-deployment.ps1` script
	- [x] Bicep linting
	- [x] Azure Policy validation
- [x] Resolve ajenns-1 role-assignment permission with an authorized identity
- [x] Mark plan Ready for Validation and complete azure-validate workflow

### Deployment and Vetting

- [ ] Deploy with `az deployment group create` exactly as documented
- [ ] Verify deployment outputs and APIM provisioning state
- [ ] Verify APIM managed identity has `Foundry User` on the Foundry account
- [ ] Verify requests without a bearer key and with a wrong key return 401
- [ ] Verify `/models` lists exactly the four allowed deployment IDs
- [ ] Verify chat streaming and tool calling through APIM for each model
- [ ] Verify `/responses` for models that use that wire API
- [ ] Verify Application Insights receives token metrics without prompt/completion bodies
- [ ] Record findings suitable for customer review

## 9. Validation Proof

### Commands and Results

| Command | Result |
|---------|--------|
| `validate-deployment.ps1 -Scope group -ResourceGroup rg-ghcp-byok -Template ./infra/main.bicep -Parameters ./infra/my.bicepparam -Subscription a08cafe6-0a04-4fd4-a981-b75bd0c7f223` | PASS: CLI, authentication, Bicep build, ARM validation, and what-if; 15 creates, 0 modifies, 0 deletes |
| `az bicep lint --file infra/main.bicep` | Exit 0; six known APIM `managedIdentity` type-definition warnings and no errors |
| `az bicep build --file infra/main.bicep --stdout` | Exit 0 |
| `az bicep build-params --file infra/my.bicepparam --stdout` | Exit 0; two quoted-property style warnings and no errors |
| `az policy assignment list --subscription a08cafe6-0a04-4fd4-a981-b75bd0c7f223 --scope /subscriptions/a08cafe6-0a04-4fd4-a981-b75bd0c7f223 --disable-scope-strict-match` | Three inherited Defender assignments; none constrain the planned resource types, East US 2, APIM SKU, or tags |
| `az policy state summarize --subscription a08cafe6-0a04-4fd4-a981-b75bd0c7f223 --resource-group rg-ghcp-byok` | No evaluated violations in the target resource group |

| Check | Result | Timestamp |
|-------|--------|-----------|
| Azure extension context | New tenant + ajenns-3 selected | 2026-09-09 |
| Azure CLI context | New tenant + ajenns-3 selected | 2026-09-09 |
| Subscription inventory | Only MCAPS governance defaults; no existing AI/gateway resources | 2026-09-09 |
| Region availability | East US 2 supports all planned resource types and models | 2026-09-09 |
| Foundry account | AIServices S0 created; legacy OpenAI endpoint verified | 2026-09-10 |
| Model deployments | Four Global Standard deployments in Succeeded state | 2026-09-10 |
| Quota | All planned resources/models within limits | 2026-09-09 |
| Name availability | `ghcp-byok-foundry-987131` and `ghcp-byok-apim-987131` available | 2026-09-09 |
| Bicep build | Pass; known APIM `managedIdentity` type warnings only | 2026-09-09 |
| APIM policy XML/fragments | Six files parsed successfully | 2026-09-10 |
| Tenant parameter build | Pass; fresh key format verified and file git-ignored | 2026-09-10 |
| Core Azure validation | PASS: CLI, authentication, Bicep build, ARM validation, what-if | 2026-09-10 |
| What-if | 15 creates, 0 modifies, 0 deletes | 2026-09-10 |
| Bicep lint | Pass with six known APIM backend type-definition warnings | 2026-09-10 |
| Azure Policy | Three Defender assignments unrelated to planned resources; no resource-group violations | 2026-09-10 |
| Static role verification | APIM identity gets resource-scoped Foundry User; conditional roles are least-privilege and disabled in this deployment | 2026-09-10 |
| Effective role-assignment permission | Allowed in both subscriptions using tenant-native Owner account | 2026-09-10 |

**Validated by:** `azure-validate` workflow; all checks passed on 2026-09-10.

## 10. Role Assignment Verification

- **Status:** Verified
- **Identity checked:** APIM system-assigned managed identity
- **Active role confirmed:** `Foundry User` (`53ca6127-db72-4b80-b1b0-d745d6d5456d`) on the specific `ghcp-byok-foundry-987131` account in ajenns-1
- **Conditional roles reviewed:** `Cognitive Services User` is resource-scoped when Content Safety is deployed; `Monitoring Metrics Publisher` is resource-scoped when explicitly enabled. Both are disabled by the current parameters.
- **Local development identity:** Not required for gateway runtime; deployment uses the tenant-native Owner and functional tests call Foundry through APIM.
- **Issues:** None

## 11. Files

| File | Purpose | Status |
|------|---------|--------|
| `.azure/deployment-plan.md` | Deployment source of truth | Complete for approval |
| `infra/main.bicep` | Existing gateway infrastructure | Unchanged; build passes |
| `infra/my.bicepparam` | Ignored tenant-specific parameters and secrets | Update only after approval |

## 12. Approval Boundary

Approval authorizes creation of the two resource groups, one Foundry account, one APIM Developer instance, one Log Analytics workspace, and one Application Insights component. Model deployments are user-managed. It also authorizes provider registration, deployment validation/what-if, and the cross-subscription Foundry User role assignment executed by the tenant-native Owner identity.
