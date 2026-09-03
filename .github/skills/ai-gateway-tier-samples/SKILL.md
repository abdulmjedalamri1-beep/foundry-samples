---
name: ai-gateway-tier-samples
description: 'Create, edit, and validate Azure API Management AI Gateway tier (preview) Bicep samples for Microsoft Foundry. Two canonical samples: the public golden-path module (infrastructure/infrastructure-setup-bicep/01-connections/ai-gateway-tier) with a hub (main.bicep: account + model + gateway) and a spoke ModelGateway "Admin-connected models" connection (connection.bicep), and its self-contained network-secured VNet variant (16-private-network-standard-agent-apim-setup/extensions/ai-gateway-tier-private). USE WHEN building or modifying samples that use the AIGateway SKU (Microsoft.ApiManagement/service@2025-09-01-preview), the preview Foundry modelProviders/models/apiKeys resources, token-limit policies, ModelGateway ApiKey connections, or prompt agents that consume a gateway model via the Responses API. Includes verified resource shapes, Foundry role GUIDs, region/preview gating, VNet integration (inbound-public + outbound-private), soft-delete purge, and the exact gotchas: BCP081 warnings, runtimeKey.listSecrets(), output_text vs choices, api-key vs x-api-key header, gpt-5.4 naming, slow token-limit throttling, the NSG-required-on-integration-subnet rule, the hub-account private-endpoint → model-deploy ordering, and CI-safe low model capacity.'
---

# AI Gateway tier (preview) samples

Build Bicep samples for the **AI Gateway tier** of Azure API Management — the dedicated,
release-gated preview SKU (`Microsoft.ApiManagement/service` with `sku.name: 'AIGateway'`),
**not** the classic Developer/Basic/Standard/Premium or v2 (StandardV2/PremiumV2) tiers.

## When to use

- Creating or editing the AI Gateway tier golden-path module under
  `infrastructure/infrastructure-setup-bicep/01-connections/ai-gateway-tier/` (public) or its
  network-secured VNet variant under
  `.../16-private-network-standard-agent-apim-setup/extensions/ai-gateway-tier-private/`.
- Wiring a Foundry `modelProvider` (managed-identity import), a gateway `models` registration
  with a `tokenLimit` policy, a runtime `apiKeys`, or a `ModelGateway` connection.
- Writing the Python test that consumes a gateway model (direct OpenAI call **or** a prompt
  agent via the Responses API).

## The canonical samples — copy these

Start from the closest existing sample; keep the verified resource shapes and API versions.

| Sample | Copy from | What it builds |
|--------|-----------|----------------|
| **Public (Path A)** — golden-path AI Gateway tier | `infrastructure/infrastructure-setup-bicep/01-connections/ai-gateway-tier/` | `main.bicep` = hub (account + hub project + model + gateway + provider + `tokenLimit` policy + runtime key), deployed once; `connection.bicep` = spoke ModelGateway "Admin-connected models" connection on an **existing** project (golden-path steps 1-2). Agent = shared `public-byom-apim/samples/create-agent.py`. |
| **VNet (Path B)** — network-secured variant | `.../16-private-network-standard-agent-apim-setup/extensions/ai-gateway-tier-private/` | **self-contained one-shot**: one `main.bicep` stands up the full template-16 private foundation (VNet, private account + project, Cosmos/Search/Storage, capability host — via the shared `modules-network-secured/*`) **plus** a private hub account (`publicNetworkAccess: Disabled`) + gateway with **inbound-public + outbound-VNet-integrated** networking + the connection on the created project. |

Both consume the model as `<connectionName>/<modelName>` from a prompt agent via the Responses API.

## Verified building blocks (exact shapes)

All preview API versions below are load-bearing — do not "upgrade" them blindly.

### Gateway (AIGateway SKU) — regions eastus2 / swedencentral only

```bicep
resource aiGateway 'Microsoft.ApiManagement/service@2025-09-01-preview' = {
  name: effectiveGatewayName
  location: gatewayLocation     // own param; the CI overrides `location` but not `gatewayLocation`
  identity: { type: 'SystemAssigned' }
  sku: { name: 'AIGateway', capacity: 1 }
  properties: { publisherEmail: publisherEmail, publisherName: publisherName }
}
```

Declare the gateway region separately so the live-deploy CI (which overrides `location`, not
`gatewayLocation`) deploys the account/model/project/spoke in its region while the gateway stays
supported — see gotcha #8:

```bicep
@allowed([ 'eastus2', 'swedencentral' ])
param gatewayLocation string = 'eastus2'
```

> This split is the **public (Path A)** recipe, where the account/model/project are public and can
> deploy in the CI's region. The **network-secured (Path B)** sample instead uses a single `region`
> param (no `location`, no `gatewayLocation`): its private foundation (AI Search + capability host) and
> the co-regional VNet requirement force every resource into one supported region, so it defaults to
> `swedencentral` and the CI cannot relocate it. See gotcha #8.

### Hub account + model + project

```bicep
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }        // no user-assigned MI needed
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    disableLocalAuth: true                     // keyless/Entra; gateway leg uses the connection key
  }
  // sku S0, networkAcls defaultAction Allow, publicNetworkAccess Enabled
}
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: account
  name: modelName                              // gpt-5.4 (DOT, not gpt-5-4)
  sku: { name: 'GlobalStandard', capacity: modelCapacity }
  properties: { model: { name: modelName, format: 'OpenAI', version: modelVersion } }
}
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  identity: { type: 'SystemAssigned' }
}
```

### Keyless backend: gateway MI → Foundry User on the account

```bicep
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'   // Foundry User
resource foundryUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, aiGateway.id, foundryUserRoleId)
  properties: {
    principalId: aiGateway.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
  }
}
```

### Provider + gateway model (token-limit policy) + runtime key

```bicep
// The AIGateway SKU auto-creates the 'default' workspace.
resource defaultWorkspace 'Microsoft.ApiManagement/service/workspaces@2025-09-01-preview' existing = {
  parent: aiGateway
  name: 'default'
}
var hubEndpoint = endsWith(account.properties.endpoint, '/') ? account.properties.endpoint : '${account.properties.endpoint}/'
resource foundryProvider 'Microsoft.ApiManagement/service/workspaces/modelProviders@2025-09-01-preview' = {
  parent: defaultWorkspace
  name: 'foundry'
  properties: {
    kind: 'Foundry'
    displayName: 'Foundry'
    foundry: {
      endpoint: hubEndpoint                    // MUST end with '/'
      resourceIds: [ account.id ]
      authentication: { kind: 'ManagedIdentity', managedIdentity: { resource: 'https://cognitiveservices.azure.com/' } }
    }
  }
  dependsOn: [ foundryUserRole, modelDeployment ]
}
resource gatewayModel 'Microsoft.ApiManagement/service/workspaces/modelProviders/models@2025-09-01-preview' = {
  parent: foundryProvider
  name: modelName
  properties: {
    displayName: modelName
    apiFormat: 'OpenAIChatCompletions'
    supportedEndpoints: [ '/openai/v1/chat/completions', '/openai/v1/responses' ]
    deployment: { resourceId: modelDeployment.id, modelName: modelDeployment.name, modelVersion: modelVersion }
    policies: [ { type: 'tokenLimit', period: 'minute', count: tokensPerMinute, counterKey: 'Identity' } ]
  }
}
resource runtimeKey 'Microsoft.ApiManagement/service/apiKeys@2025-09-01-preview' = {
  parent: aiGateway
  name: 'default'
  properties: { displayName: 'runtime key' }
}
// OpenAI base URL callers/connections use:
output gatewayModelsBaseUrl string = '${aiGateway.properties.gatewayUrl}/default/models/openai/v1'
```

### Network-secured (VNet) gateway — inbound-public + outbound-private (Path B)

For the `ai-gateway-tier-private` variant the gateway integrates **outbound** into a delegated
subnet to reach a **private** hub account, while staying **inbound-public** so the managed Agent
Service inference plane can still reach it. The integration subnet needs an NSG (gotcha #14).

```bicep
resource aiGateway 'Microsoft.ApiManagement/service@2025-09-01-preview' = {
  // ...sku AIGateway, SystemAssigned identity, publisherEmail/publisherName
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'                                        // required with vnetCfg ('None' is rejected)
    virtualNetworkConfiguration: { subnetResourceId: apimOutboundSubnet.id }  // subnet delegated Microsoft.Web/serverFarms + NSG
    publicNetworkAccess: 'Enabled'                                        // inbound stays public
  }
}
```

The hub account is `publicNetworkAccess: 'Disabled'` with a private endpoint (groupId `account`)
into the VNet, reusing the `privatelink.cognitiveservices/openai/services.ai` zones. **The hub-account
PE must `dependsOn` the model deployment** or the deploy races into `AccountProvisioningStateInvalid`
(gotcha #15). The sample is **self-contained**: one deployment stands up template 16's foundation
(via the shared `modules-network-secured/*` modules) — VNet, pe-subnet, private project, DNS zones —
**and** the gateway layer, so no separate template-16 run is needed, and everything deploys in one
region (`region` param, default `swedencentral`). Because the private project has no public data
plane, verify the agent from a client **inside** the VNet (e.g. a jumpbox VM).

### The "Admin-connected models" connection (Path A: `connection.bicep`; Path B: inline in `main.bicep`)

```bicep
resource gatewayConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project                              // Path A: an existing spoke project (parsed from projectResourceId). Path B: the project the self-contained main.bicep just created.
  name: connectionName                         // callers reference <connectionName>/<modelName>
  properties: {
    category: 'ModelGateway'
    target: '${aiGateway.properties.gatewayUrl}/default/models/openai/v1'
    authType: 'ApiKey'
    isSharedToAll: true                         // => shows in portal "Admin-connected models" picker
    credentials: { key: runtimeKey.listSecrets().primaryKey }   // symbol form — see gotchas
    metadata: {
      models: string([ { name: modelName, properties: { model: { name: modelName, version: modelVersion, format: 'OpenAI' } } } ])
      deploymentInPath: 'false'                 // model name goes in the request body
      authHeaderName: 'api-key'                 // AI Gateway tier authenticates the api-key header
      authHeaderFormat: '{api_key}'
      customHeaders: '{}'
    }
  }
  dependsOn: [ gatewayModel ]
}
```

### Persona role grants are out-of-band (not in the sample bicep)

The samples grant only the **gateway MI → Foundry User** role (above); they do **not** bake in a
developer or consumer role. ARM Owner does **not** grant Foundry data-plane access — grant the
developer/consumer roles separately per the persona RBAC in
`infrastructure/infrastructure-setup-bicep/golden-path/README.md` (developer and invoke-only consumer
both need **Foundry User** on the project — see gotcha #13).

### Consumption: prompt agent + Responses API (the ONLY path that resolves `<connection>/<model>`)

```python
# pip install "azure-ai-projects>=2.0.0" azure-identity
project = AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())
agent = project.agents.create_version(agent_name="gateway-agent",
    definition=PromptAgentDefinition(model="ai-gateway/gpt-5.4", instructions="You are a helpful assistant."))
client = project.get_openai_client()
conv = client.conversations.create()
resp = client.responses.create(conversation=conv.id, input=prompt,
    extra_body={"agent_reference": {"name": agent.name, "type": "agent_reference"}})
print(resp.output_text)   # Responses API — NOT resp.choices[0].message.content
```

- `PROJECT_ENDPOINT` = `https://<account>.services.ai.azure.com/api/projects/<project>`.
- Role GUIDs: Foundry User `53ca6127-db72-4b80-b1b0-d745d6d5456d` (gateway MI + developer/consumer),
  Foundry Account Owner `e47c6f54-e4a2-4754-9501-8e0985b135e1` (admin), Foundry Agent Consumer
  `eed3b665-ab3a-47b6-8f48-c9382fb1dad6` (see gotcha #13); Azure: API Management Service Contributor
  `312a565d-c81f-4fd8-895a-4e21e48d571c`.

## Non-obvious gotchas — get these right

1. **BCP081 is expected.** `modelProviders`, `models`, and `apiKeys@2025-09-01-preview` have "no
   types available" — `az bicep build` warns but deploys fine. Say so in the README; don't chase it.
2. **`listSecrets` on the runtime key:** use the resource-symbol form `runtimeKey.listSecrets().primaryKey`
   (not `listSecrets(id, apiVersion)`) — avoids the `use-resource-symbol-reference` linter warning and
   builds the dependency graph.
3. **Responses API returns `output_text`, not `.choices`.** `resp.choices[0].message.content` (Chat
   Completions shape) raises `AttributeError: 'Response' object has no attribute 'choices'`.
4. **BYOM `<connection>/<model>` resolves ONLY via a prompt agent + Responses API.** The classic
   Assistants API (`create_agent` + threads + runs) fails `invalid_engine_error: Failed to resolve model info`.
5. **Connection header is `api-key`** (the tier authenticates the api-key header) — NOT `x-api-key`
   (which the generic `foundry-modelgateway-connection-apikey.bicep` uses for a different, non-gateway target).
6. **Model name is `gpt-5.4` (dot).** The gateway may display `gpt-5-4`, but callers use `gpt-5.4`.
7. **Token-limit throttling is slow to trip** (v2 token-bucket + completion tokens counted after the
   response). Keep a low `tokensPerMinute` default (e.g. 100) so the policy visibly 429s under a short
   burst — the first call usually passes, later ones throttle. The 429 surfaces as HTTP 429 directly and
   as `openai.RateLimitError` ("Token limit is exceeded") through the agent path.
8. **Region + preview gating — the proven CI-green recipe.** The AIGateway SKU deploys only in **eastus2 /
   swedencentral** with the preview enrolled. The live-deploy CI (`.azure-pipelines/private-bicep-pr-ci.yml`)
   force-overrides `location` to its RG region (e.g. westus), also overrides `aiServicesName`/`modelName`/
   `modelVersion`, requires a full successful deploy + data-plane diagnostics, and `exit 1`s on the first
   failed sample. What makes the public `ai-gateway-tier` sample pass in westus:
   - **Decouple the gateway region** onto a `gatewayLocation` param (`@allowed(['eastus2','swedencentral'])`,
     default eastus2). The CI overrides `location` but NOT `gatewayLocation`, so the gateway stays supported
     while account/model/project/spoke deploy in the CI region (cross-region import works fine).
   - **Do NOT `@allowed`-restrict `location`** — the CI's region must be accepted; guard `gatewayLocation` only.
   - **`aiServicesName` `@maxLength` ≥ 37** (use `@maxLength(40)`) — the CI overrides it with a ~37-char name;
     a tight `@maxLength(9)` fails template validation.
   - **Never hardcode `principalType: 'User'`** on a deployer-default role assignment (gotcha #12).
   - **Keep `modelCapacity` low (default `1`).** The CI overrides `modelName`/`modelVersion` but NOT
     `modelCapacity`, and the CI sub's gpt-5-mini GlobalStandard quota runs tight (seen ~38 free) — a high
     default (e.g. 40) fails preflight `InsufficientQuota`. 1k TPM is plenty for validation; users raise it
     for real gpt-5.4 workloads.

   **Network-secured (Path B) uses the opposite recipe — a single `region` param, no `location`.** Because
   the CI only rewrites `param location = …`, omitting `location` entirely means the CI cannot relocate the
   sample — every resource deploys in `region` (`@allowed(['eastus2','swedencentral'])`, default
   `swedencentral`). This is required, not cosmetic: the private foundation's AI Search + capability host
   must run in a supported region (AI Search hit capacity in eastus2, so swedencentral), and the AIGateway's
   outbound VNet integration needs the VNet co-regional. Keep `modelCapacity` at `1` here too. Verified end
   to end in swedencentral (full foundation + capability host + AIGateway + connection).

   These samples live under `infrastructure/`, so no `sample.yaml` is needed (the central ADO validation
   pipeline only discovers `sample.yaml` under `samples/`).
9. **Foundry data-plane roles ≠ ARM Owner.** The sample assigns **Foundry User** to the gateway MI in
   bicep; developer/consumer roles are granted out-of-band (gotcha #13 + the persona RBAC table).
10. **`disableLocalAuth: true`** on hub and consumer accounts is fine — the connection's stored gateway
    key handles the gateway leg; account local auth is unrelated.
11. **Deterministic naming ↔ soft-delete collisions.** `uniqueString(resourceGroup().id)` avoids recreation
    churn but means redeploying into the same RG after a delete collides with the **soft-deleted** leftovers:
    the account fails `FlagMustBeSetForRestore`, and the gateway (APIM) fails `ServiceAlreadyExists: Api
    service already exists: <name>`. **Deleting the whole RG does NOT purge them** — soft-deleted accounts and
    APIM services persist by name (globally, for APIM, so a soft-deleted gateway in one region blocks the same
    name in another) and must be purged explicitly (see below). Purge first; prefer deterministic naming and
    document the purge.
12. **`deployer()` is a SERVICE PRINCIPAL in CI.** If you add a role assignment that defaults its
    principal to `deployer().objectId`, do NOT hardcode `principalType: 'User'` — the live-deploy CI
    service connection is an SP, so ARM fails `UnmatchedPrincipalType`. Set `principalType` only when an
    explicit principal is passed; omit it for the deployer default so ARM infers it. Managed-identity
    grants (e.g. the gateway → Foundry User grant these samples use) are always `ServicePrincipal` and
    stay hardcoded.
13. **Persona RBAC — verified minimums (preview).** The **admin** needs only **Foundry Account Owner
    + API Management Service Contributor** — *not* User Access Administrator: Account Owner's
    `roleAssignments/write` is ABAC-conditioned to an allow-list that already includes **Foundry User**
    and **Foundry Agent Consumer** (verified with a UAMI — it granted both, and was blocked from
    Reader). The **developer** needs only **Foundry User** on the project (no Reader). **Foundry Agent
    Consumer does NOT work for invoke:** the prompt-agent Responses path (`create_version` +
    `responses.create` `agent_reference`) authorizes against `…/AIServices/agents/write`, but Agent
    Consumer grants only `…/AIServices/endpoints/interact/action` → **403** on both create and invoke.
    Use **Foundry User** for invoke-only callers until a narrower role covers the agent Responses path.
14. **VNet-integrating the AIGateway needs an NSG on the outbound subnet.** For a network-secured
    (Path B) gateway — `virtualNetworkType: 'External'` + `virtualNetworkConfiguration.subnetResourceId`
    into a subnet delegated to `Microsoft.Web/serverFarms` — that subnet MUST have an associated NSG,
    or the deploy fails `NetworkSecurityGroupNotFound`. Add an NSG allowing outbound 443 to the
    `Storage` and `AzureKeyVault` service tags. Keep the gateway **inbound-public**
    (`publicNetworkAccess: Enabled`) so the managed Agent Service inference plane can reach it while
    the gateway reaches the private hub over the VNet. See `16-.../extensions/ai-gateway-tier-private`.
15. **Path B: the hub-account private endpoint must depend on the model deployment.** In the VNet
    variant the hub-account PE and the model (`accounts/deployments`) both implicitly depend only on the
    account, so ARM builds them in parallel. A model-deployment PUT flips the account into a transient
    `Accepted` state, so the concurrent PE create fails `AccountProvisioningStateInvalid … in state
    Accepted` — and it recurs on every retry because the incremental deploy re-asserts the model PUT. Give
    the hub-account PE an explicit `dependsOn` on the model deployment so the chain serializes
    `account → model → PE → DNS zone group → provider`.
16. **Path B self-contained: serialize the gateway's VNet writes after the foundation.** When the
    AIGateway layer deploys in the SAME deployment as the foundation (the self-contained
    `ai-gateway-tier-private`), the `apim-outbound` subnet (a standalone `virtualNetworks/subnets` PUT)
    and the hub-account PE both write the VNet / pe-subnet concurrently with the foundation's private
    endpoints (creating a PE disables network policies on the pe-subnet — also a VNet write). Give both an
    explicit `dependsOn` on `privateEndpointAndDNS` (the apim-outbound subnet also on the `vnet` module) or
    the deploy intermittently fails `AnotherOperationInProgress` on the VNet. The old thin extension never
    hit this because template 16 was already fully deployed before it ran.

## Purge soft-deleted resources (before redeploying into the same RG)

```powershell
az cognitiveservices account purge -l <location> -g <rg> -n <accountName>
az apim deletedservice purge -l <location> -n <gatewayName>
# list what's soft-deleted:
az cognitiveservices account list-deleted -o table
az apim deletedservice list -o table
```

Both auto-purge after ~48h; manual purge frees the names immediately. Purge only ever touches
**already-deleted** resources — it cannot affect anything live.

## Procedure: create a new AI Gateway tier sample

1. **Pick the base** — the public `ai-gateway-tier/` (Path A) or the VNet `ai-gateway-tier-private/`
   (Path B) — and copy it to the new sample location.
2. **Keep the verified resource shapes** above (API versions, `foundry` provider block, `models`
   policy/deployment block, connection metadata, and the VNet networking shape for Path B). Adjust
   params (model, `tokensPerMinute`, names).
3. Wire the `ModelGateway`+`ApiKey` connection to the gateway via `runtimeKey.listSecrets()`; the agent
   is created out-of-band via the golden-path prompt-agent + Responses API flow.
4. **Write the sample files** (mirror the canonical samples):
   - `main.bicep` (+ `connection.bicep` for the public hub/spoke split), params (`samples/parameters.json`
     or `main.bicepparam`), `metadata.json`, `README.md`, and the compiled `azuredeploy.json`.
   - README front-matter: `description`, `page_type: sample`, `products: [azure, azure-resource-manager,
     azure-api-management]`, `urlFragment: <sample-name>`, `languages: [bicep, json, python]`.
   - README body: how-this-maps table, prereqs (**preview enrolled + eastus2/swedencentral**, quota,
     **Foundry Account Owner + API Management Service Contributor** for the gateway + role grants — no
     UAA (gotcha #13), `pip install`), single deploy, the agent step, params table, references.
   - `metadata.json`: `$schema` azure-quickstart-templates-metadata-schema, `type: QuickStart`,
     `itemDisplayName`, `description`, `summary`, `githubUsername`, `dateUpdated`, `environments: [AzureCloud]`.
5. **Validate** (see below).
6. **Deploy to eastus2/swedencentral to verify.** Purge soft-deleted accounts/gateways if redeploying.

## Validate

```powershell
az bicep build --file main.bicep --stdout 1>$null   # Path A: ONLY 3x BCP081. Path B (self-contained): 3x BCP081 + the shared modules-network-secured/* warnings (BCP318/BCP321/BCP037/no-unused-vars + no-hardcoded-env-urls for privatelink.blob.core.windows.net) — all inherited from template 16, benign.
python -m black --check samples\<test>.py
```

Ignore cosmetic cSpell squiggles (`cognitiveservices`, `swedencentral`, `deployer`, `openai`) — false positives.

## References

- Canonical samples: `infrastructure/infrastructure-setup-bicep/01-connections/ai-gateway-tier/`
  (public, Path A) and `.../16-private-network-standard-agent-apim-setup/extensions/ai-gateway-tier-private/`
  (VNet, Path B). Golden path: `infrastructure/infrastructure-setup-bicep/golden-path/README.md`.
- Bicep pattern source: [Azure-Samples/simple-foundry-hosted-agent-python-aigateway](https://github.com/Azure-Samples/simple-foundry-hosted-agent-python-aigateway).
- [Manage models and tools](https://learn.microsoft.com/azure/api-management/ai-gateway-manage-models-tools)
  · [Govern, secure, operate](https://learn.microsoft.com/azure/api-management/ai-gateway-govern-secure-assets)
  · [Quickstart: create an AI Gateway](https://learn.microsoft.com/azure/api-management/quickstart-ai-gateway-create)
- [RBAC for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
  · [Bring your own model (prompt agent + Responses API)](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
