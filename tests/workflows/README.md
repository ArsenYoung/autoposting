# Workflow Webhook Autotests

Python e2e tests for n8n workflows, executed through webhook endpoints and validated via Postgres state.

## Covered workflows
- `01_ingest` (push)
- `01_ingest` (pull test hook)
- `02_dispatcher` (test hook)
- `03_monitor` (test hook)
- `11_bot_ingest`
- `12_bot_engine` (optional smoke test)
- `13_bot_monitor` (optional smoke test)
- `adapter_telegram_send` (optional smoke test)
- `adapter_max_send` (optional smoke test)

## Important assumptions
- `02_dispatcher` and `03_monitor` are cron workflows in production.  
  For automated tests, expose dedicated **test webhook** triggers that execute the same logic path.
- `01_ingest` pull path should also have a test webhook (or a test branch) that accepts `items[]`.
- Webhook handlers must read endpoint secret from headers configured in `.env`:
  - `INGEST_SECRET_HEADER`
  - `BOT_SECRET_HEADER`

## Setup
```bash
cd tests/workflows
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Fill `.env`:
- `DATABASE_URL` for the target DB
- workflow webhook URLs (`WF01_*`, `WF02_*`, `WF03_*`, `WF11_*`)
- optional global webhook auth header/value for n8n ingress auth

## Run
```bash
cd tests/workflows
pytest -q
```

Notes:
- If you have a `tests/workflows/.env`, it will be loaded automatically.
- Alternatively, you can still `set -a; source .env; set +a`, but make sure to quote values with spaces (e.g. `N8N_WEBHOOK_AUTH_VALUE="Bearer ..."`).

## Test strategy
- Each test creates an isolated workspace + endpoints + channels in DB.
- Test calls workflow webhook with unique payload markers.
- Test polls DB and asserts expected artifacts:
  - `messages` / `deliveries` for ingest
  - delivery status transition for dispatcher
  - lease recovery + event for monitor
  - inbound dedup in `bot_inbox` for bot ingest
- Cleanup is automatic (`DELETE workspaces ... CASCADE`).

## Notes
- If a webhook URL is not set, the corresponding test is skipped.
- If you already have fixed workspace fixtures, adapt `workspace_ctx` fixture in `conftest.py`.
