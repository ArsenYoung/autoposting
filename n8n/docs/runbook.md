# n8n Runbook (Stage 0)

## Scope
This runbook covers Stage 0 preparation from `plan.md`:
- repository structure for n8n artifacts
- workflow naming
- baseline env/secret variables

## Repository structure
- `n8n/workflows/` - exported workflow JSON files
- `n8n/env/.env.example` - baseline env/secrets template
- `n8n/docs/runbook.md` - this document

## Workflow naming (fixed)
- `01_ingest`
- `02_dispatcher`
- `03_monitor`
- `11_bot_ingest`
- `12_bot_engine`
- `13_bot_monitor`
- `adapter_telegram_send`
- `adapter_max_send`

## Required credentials in n8n
- `Neon Autoposting DB` (Postgres)
- `AutoPostAssistantBot` (Telegram)
- `Autopost S3` (S3)

## Required headers/secrets
- `N8N_WEBHOOK_AUTH_HEADER` / `N8N_WEBHOOK_AUTH_VALUE`
- `INGEST_SECRET_HEADER` / `INGEST_SECRET_VALUE`
- `BOT_SECRET_HEADER` / `BOT_SECRET_VALUE`

## Runtime knobs
Keep runtime thresholds in env (see `n8n/env/.env.example`):
- ingest limits and pull chunking
- dispatcher cadence, claim size, lease duration
- monitor alert thresholds
- adapter limits and upstream API base URLs

## Stage 0 verification checklist
1. Folder structure exists under `n8n/`.
2. `.env.example` includes webhook/auth and runtime threshold variables.
3. Workflow names are fixed and consistent with `plan.md`.
4. Credential display names are documented and stable.
