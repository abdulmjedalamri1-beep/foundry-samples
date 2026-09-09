# Coding Agent Instructions

This project is a LangGraph agent hosted in Responses protocol. It can run in Microsoft Foundry or on-premises.
This sample demonstrates how to customize all the stateful parts of the agent so users have full control over the stores
in order to be flexible to host on Foundry or on-prem.

## Key files

- `azure.yaml` - Foundry hosted-agent manifest.
- `src/custom-store/main.py` - agent and host lifecycle
- `src/custom-store/model.py` - Foundry
  model authentication using `AZURE_AI_API_KEY` when set, otherwise Azure credentials.
- `src/custom-store/sqlite_conversation_chain_store.py`
  - custom conversation-chain store.
- `src/custom-store/sqlite_response_store.py`
- `src/custom-store/requirements.in` -
  direct dependencies.

## Development workflow

Run from the sample root:

```bash
azd ai agent run --no-client
azd deploy
```

For on-premises runs, use `python main.py` from the source directory with
the model settings and `AZURE_AI_API_KEY` in `.env`.

Before working on this Foundry agent, read the microsoft-foundry skill. If you
are in VS Code, read the vscode-microsoft-foundry skill first.