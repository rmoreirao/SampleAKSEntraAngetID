# Deployment guide

The PoC supports a no-secret local demo and an Azure deployment to AKS. The
recommended Azure mode uses the Microsoft Entra ID Auth SDK sidecar. The direct
Python exchange is experimental and requires an explicitly documented protocol
contract from your tenant.

## Prerequisites

- PowerShell 7, Azure CLI, `kubectl`, Git, Python 3.12, `uv`, Node.js, and npm.
- An Azure subscription where you can create resource groups, AKS, ACR,
  Microsoft Foundry, Azure AI Search, managed identities, role assignments,
  Log Analytics, and Application Insights.
- A Microsoft Entra tenant where the operator has the documented Agent ID
  Administrator and Application Administrator (or Cloud Application
  Administrator) roles.
- Admin-consented delegated Microsoft Graph scopes:

```text
AgentIdentityBlueprint.Read.All
AgentIdentityBlueprint.Create
AgentIdentityBlueprintPrincipal.Create
AgentIdentityBlueprint.AddRemoveCreds.All
AgentIdentity.Read.All
AgentIdentity.Create.All
AgentIdentity.ReadWrite.All
Application.ReadWrite.All
Directory.Read.All
AppRoleAssignment.ReadWrite.All
```

Model availability, versions, quotas, and SKU support vary by Azure region. The
defaults in `infra/main.bicep` are examples and can be overridden in a direct
`az deployment group create` call when necessary.

## Local demo

Local mode uses seeded recipes and inventory, disables Foundry calls, and uses
an explicit development-only authentication bypass.

```powershell
uv sync --frozen
npm --prefix .\web ci
.\scripts\Start-LocalDemo.ps1
```

Open `http://127.0.0.1:5173`. Stop all processes created by the script with:

```powershell
.\scripts\Start-LocalDemo.ps1 -Stop
```

Never enable `APP_DEVELOPMENT_MODE` or `APP_AUTH_LOCAL_DEV_BYPASS` in AKS.
Local automated tests inject mocked structured model responses and do not call
Azure:

```powershell
$env:PYTHONPATH = 'src'
python -m unittest discover -s tests -v
```

## Azure deployment

### 1. Select the tenant and subscription

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
Connect-MgGraph -TenantId <tenant-id> -Scopes `
  'AgentIdentityBlueprint.Read.All',`
  'AgentIdentityBlueprint.Create',`
  'AgentIdentityBlueprint.ReadWrite.All',`
  'AgentIdentityBlueprintPrincipal.Create',`
  'AgentIdentityBlueprintPrincipal.ReadWrite.All',`
  'AgentIdentityBlueprint.AddRemoveCreds.All',`
  'AgentIdentity.Read.All',`
  'AgentIdentity.Create.All',`
  'AgentIdentity.ReadWrite.All',`
  'Application.Read.All',`
  'Application.ReadWrite.All',`
  'Directory.Read.All',`
  'AppRoleAssignment.ReadWrite.All'
```

### 2. Deploy Azure resources

```powershell
.\scripts\Deploy-AzureInfrastructure.ps1 `
  -ResourceGroupName rg-agentid-poc `
  -Location eastus2 `
  -Prefix mealpoc
```

If the selected region reports sustained AKS capacity pressure, keep Foundry,
Search, and monitoring in the selected region and provide a nearby runtime
fallback with `-AksLocation`, for example `-AksLocation northeurope`.

This writes `infra-outputs.json`. Bicep creates AKS with OIDC and Workload
Identity, ACR, Foundry, Search, monitoring, four workload UAMIs, Azure RBAC, and
the ServiceAccount-to-UAMI federated credentials.

The public web API hosts the Concierge entry point and therefore uses the
Concierge ServiceAccount/UAMI. Meal Planner, Availability, and Inventory MCP
each use their own ServiceAccount/UAMI.

### 3. Create Entra Agent ID resources and app roles

```powershell
.\scripts\New-EntraAgentIdResources.ps1 `
  -InfrastructureOutputsPath .\infra-outputs.json `
  -TenantId <tenant-id> `
  -Sponsor <user-object-id-or-upn> `
  -Owner <directory-object-id-or-upn> `
  -Prefix mealpoc `
  -GrantAdminConsent
```

This writes `entra-outputs.json`, creates one blueprint and Agent ID for each of
the three logical agents, adds each agent UAMI as a blueprint federated
credential, creates the protected APIs, and grants:

| Caller Agent ID | API | App role |
| --- | --- | --- |
| Concierge | Meal Planner | `MealPlan.Request` |
| Concierge | Availability | `Availability.Request` |
| Availability | Inventory MCP | `Inventory.Read` |

If provisioning was run without `-GrantAdminConsent`, grant the assignments
explicitly:

```powershell
.\scripts\Set-AgentRoleAssignments.ps1 `
  -EntraOutputsPath .\entra-outputs.json `
  -TenantId <tenant-id> `
  -ConfirmAdminConsent
```

### 4. Create and seed the Azure AI Search index

The signed-in Azure operator needs `Search Service Contributor` and
`Search Index Data Contributor` on the Search service.

```powershell
.\scripts\Initialize-SampleData.ps1
```

The script creates or replaces the `recipes` schema and uploads
`data/recipes.json`. The `tags` collection is filterable so dietary constraints
are enforced by Azure AI Search and checked again by the Python retriever.

### 5. Build images in ACR

```powershell
$imageTag = git rev-parse --short=12 HEAD
.\scripts\Build-PushImages.ps1 -ImageTag $imageTag
```

ACR builds `aks-agents:<tag>` and `meal-web:<tag>`. The AKS kubelet identity
receives `AcrPull` after ACR creation.

If the worktree is intentionally uncommitted, use a unique release tag rather
than a Git hash so the deployed artifact remains identifiable.

### 6. Deploy the supported sidecar mode

The deployment script defaults to Microsoft Entra ID Auth SDK sidecar
`1.1.1-azurelinux3.0-distroless`, pinned by immutable digest. It uses the
documented `AuthorizationHeaderUnauthenticated` endpoint, named downstream API
configuration, and `SignedAssertionFilePath` on AKS.

```powershell
.\scripts\Deploy-AksWorkloads.ps1 `
  -AuthMode sidecar `
  -ImageTag $imageTag
```

The sidecar is injected only into workloads that acquire Agent ID tokens. It is
not exposed by a Kubernetes Service.

Meal Planner and Availability also set `APP_FOUNDRY_ENABLED=true`. Their
Foundry access uses their UAMIs and Azure RBAC, not the Agent ID sidecar.

### 7. Deploy the experimental direct mode

The direct adapter implements Microsoft's documented two-stage autonomous app
flow. It presents the projected AKS ServiceAccount assertion to a blueprint
federated credential, then exchanges through the blueprint and Agent ID at the
tenant v2 token endpoint. A UAMI token issued through AKS Workload Identity
cannot be reused for this federation because Entra rejects chained
federated-credential tokens.

```powershell
.\scripts\Deploy-AksWorkloads.ps1 `
  -AuthMode direct `
  -ImageTag $imageTag
```

This mode is an educational, fail-closed adapter and is not a production
replacement for the supported Auth SDK.

### 8. Deploy the mixed comparison mode

Mixed mode uses the sidecar for Concierge A2A calls and the direct Python
provider for Availability-to-Inventory MCP:

```powershell
.\scripts\Deploy-AksWorkloads.ps1 `
  -AuthMode mixed `
  -ImageTag $imageTag
```

This is the recommended demonstration topology because both implementations
are visible in one end-to-end interaction.

## Access and operational checks

```powershell
kubectl get pods,services -n apps
kubectl get service web -n apps
kubectl logs deployment/web-api -n apps --tail=100
```

Open the external address of the `web` LoadBalancer and submit a vegetarian
request. The timeline should show Concierge orchestration, Meal Planner RAG,
Meal Planner inference, Availability A2A, Inventory MCP, Availability
inference, citations, and substitutions. It must not show bearer tokens,
assertions, authorization headers, raw prompts, or raw model responses.

Application telemetry uses each pod's UAMI with the `Monitoring Metrics
Publisher` role; Application Insights local authentication remains disabled.
The public web API is intentionally one replica because live SSE events are
stored in memory. Use a shared event store before scaling it horizontally.
All single-replica deployments use `maxSurge: 0` so updates fit on the small PoC
node pool; this permits a brief interruption during rollout.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `401` from A2A/MCP | Issuer, audience, tenant, sidecar/direct contract, and Agent ID token type |
| `403` from A2A/MCP | Exact app role and caller Agent ID assignment |
| Search returns no recipes | Run `Initialize-SampleData.ps1`; verify requested dietary tags exist |
| Foundry request fails | Region/model deployment, quota, endpoint, and UAMI RBAC |
| Model output rejected | Inspect schema-validation telemetry and verify returned recipe IDs/SKUs exist in Search/MCP evidence |
| Rollout pod stays Pending | Check node CPU; the checked-in strategy uses zero surge for the constrained PoC cluster |
| Image pull fails | ACR build tag and AKS kubelet `AcrPull` assignment |
| No Application Insights traces | UAMI client ID, `Monitoring Metrics Publisher`, and connection string |
| UI stays in progress | Inspect the anonymous SSE connection and `web-api` logs |

## Cost considerations

AKS worker nodes, Foundry model tokens/capacity, Azure AI Search, Log Analytics
ingestion/retention, Application Insights, ACR storage/builds, and the public
load balancer all incur charges. The baseline uses a two-node AKS pool and a
Basic Search service and a single-node PoC AKS pool for clarity and controlled
cost rather than production resilience. Before deployment:

- confirm regional model pricing and quotas;
- reduce model capacity and AKS node count only after checking availability and
  resilience requirements;
- set Azure budgets and alerts;
- limit Log Analytics retention and avoid recording prompt or token content;
- delete the resource group when the PoC is not in use.

## Cleanup

Delete only the Entra objects recorded in the non-secret provisioning output:

```powershell
Connect-MgGraph -TenantId <tenant-id> -Scopes `
  'AgentIdentity.Read.All',`
  'AgentIdentity.DeleteRestore.All',`
  'AgentIdentityBlueprint.Read.All',`
  'AgentIdentityBlueprint.DeleteRestore.All',`
  'Application.ReadWrite.All'

.\scripts\Remove-EntraAgentIdResources.ps1 `
  -TenantId <tenant-id> `
  -Prefix mealpoc `
  -EntraOutputsPath .\entra-outputs.json
```

The cleanup script verifies immutable IDs, application IDs, object types,
display names, deterministic app roles, and Agent ID-to-blueprint relationships
before deletion. Remove the Azure resource group separately:

```powershell
az group delete --name rg-agentid-poc
```

## Known PoC limitations

- Anonymous public customer experience; add ingress, TLS, WAF, rate limiting,
  and customer authentication before broader exposure.
- Seeded read-only inventory; no basket, order, payment, or profile flow.
- One in-memory web API replica for live interaction events.
- Public Azure endpoints and a public AKS API server in the baseline.
- Direct Python Agent ID authentication is experimental.
- Sidecar image and HTTP contract are intentionally supplied at deployment time
  because Microsoft can revise preview packaging and endpoint contracts.
