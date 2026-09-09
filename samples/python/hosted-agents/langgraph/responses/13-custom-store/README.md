# What this sample demonstrates

A checkpointed LangGraph chat agent hosted over the **Responses protocol**. The
same code runs in Microsoft Foundry or on-premises. Both targets call a Foundry
model using `AZURE_AI_API_KEY` when provided, or `DefaultAzureCredential` otherwise.

The sample keeps Foundry-specific state services out of the application:

- `AsyncSqliteSaver` provides official LangGraph checkpoint persistence;
- `AsyncSqliteStore` provides official SQLite-backed long-term memory;
- LangMem provides ready-made `manage_memory` and `search_memory` tools;
- `SqliteConversationChainStore` implements `ConversationChainStoreProtocol`;
- `SqliteResponseStore` persists response records and items in both environments; and
- `ResponsesHostServer` provides the same `/responses` API in both environments.

State is stored under `$HOME` when hosted and the current directory otherwise. These
single-process stores are illustrative; use shared production stores for
multi-replica deployments.

## Run locally

```bash
cd src/custom-store
python -m venv .venv
# Windows: .venv\Scripts\Activate.ps1
# macOS/Linux: source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
az login
python main.py
```

Alternatively, run `azd ai agent run --no-client` from the sample root.

For on-premises deployment, create `.env` from `.env.example`, set
`FOUNDRY_PROJECT_ENDPOINT`,
`AZURE_AI_MODEL_DEPLOYMENT_NAME`, and `AZURE_AI_API_KEY`, then run from the
source directory with the virtual environment above activated. Azure CLI login
is not required for this profile:

```bash
python main.py
```

## Test memory

For a local demonstration, send two requests with different conversation IDs.
Restart the server between them to also demonstrate
SQLite persistence. No `previous_response_id` is needed for long-term memory:

```bash
curl -X POST http://127.0.0.1:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"conversation":"memory-first","input":"Remember that my project is Skylight."}'

curl -X POST http://127.0.0.1:8088/responses \
  -H "Content-Type: application/json" \
  -d '{"conversation":"memory-second","input":"Search your saved memories. What is my project?"}'
```

All users and conversations using the same database share one global memory.
This is intentional for the sample, not suitable for private per-user facts.
The sample uses plain SQLite retrieval, not semantic vector search, so no
embedding model is required. It does not implement inbound authentication.

## Deploy

From the sample root:

```bash
azd ext install microsoft.foundry
azd auth login
azd provision
azd deploy
```

The Foundry deployment uses managed identity through `DefaultAzureCredential`
when no API key is configured; no code changes are needed between environments.