# n8n Runbook (Deploy/Test/Rollback)

## Scope
Operational runbook for Autoposting workflows:
- P0: `01_ingest`, `02_dispatcher`, `03_monitor`, `adapter_telegram_send`, `adapter_max_send`
- P1: `11_bot_ingest`, `12_bot_engine`, `13_bot_monitor`

Source of truth for workflow exports:
- `n8n/workflows/*.json`
- mirror copy: `workflows/*.json`

## Prerequisites
1. n8n instance is reachable and API/UI auth is configured.
2. DB schema/migrations are applied (`db/schema.sql`, `db/migrations/*`).
3. n8n credentials exist:
   - `Neon Autoposting DB`
   - `AutoPostAssistantBot`
   - `Autopost S3`
4. Runtime env is set from `n8n/env/.env.example`.
5. For full test suite without skips, `tests/workflows/.env` contains `ADAPTER_TG_TARGET_ID`.

## Deploy
1. Apply DB migrations (if not applied yet):
```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/migrations/<migration>.sql
```
2. Import/update workflows in n8n from `n8n/workflows/*.json`.
3. Ensure workflows are active:
   - `01_ingest`
   - `02_dispatcher`
   - `03_monitor`
   - `11_bot_ingest`
   - `12_bot_engine`
   - `13_bot_monitor`
   - `adapter_telegram_send`
   - `adapter_max_send`
4. Verify webhook paths resolve (from `.env` values used by tests).

## Test
1. Fill `tests/workflows/.env`:
   - `DATABASE_URL`
   - `WF01_*`, `WF02_*`, `WF03_*`, `WF11_*`, `WF12_*`, `WF13_*`, `WF_ADAPTER_*`
   - `N8N_WEBHOOK_AUTH_HEADER` / `N8N_WEBHOOK_AUTH_VALUE`
   - `ADAPTER_TG_TARGET_ID` (required for Telegram success/cache test)
2. Run full suite without filters:
```bash
make wf-tests
```
3. Useful targeted checks:
```bash
make wf03-monitor
make wf11-bot-ingest
make wf12-bot-engine
make wf13-bot-monitor
```
4. Strict P1 checks (state/idempotency + alert logic):
```bash
cd tests/workflows
./.venv/bin/python -m pytest -q \
  test_workflows_webhooks.py::test_workflow_12_bot_engine_state_outbox_idempotent \
  test_workflows_webhooks.py::test_workflow_13_bot_monitor_alert_logic
```

## CI Gate
`make wf-tests` is enforced in GitHub Actions:
- workflow file: `.github/workflows/wf-tests.yml`
- triggers: `pull_request`, `push` to `main`/`master`
- gate behavior: build `tests/workflows/.env` from repo secrets, then run full suite

## DB Invariants
Run after deploy/tests:

```sql
-- No stuck claimed/sending leases
SELECT
  COUNT(*) FILTER (
    WHERE status = 'sending'::public.delivery_status
      AND COALESCE(sending_lease_until, '-infinity'::timestamptz) < now()
  ) AS stuck_sending,
  COUNT(*) FILTER (
    WHERE status = 'claimed'::public.delivery_status
      AND COALESCE(lease_until, '-infinity'::timestamptz) < now()
  ) AS stuck_claimed
FROM public.deliveries;

-- Delivery status field consistency
SELECT
  COUNT(*) FILTER (
    WHERE status = 'sent'::public.delivery_status
      AND sent_at IS NULL
  ) AS sent_without_sent_at,
  COUNT(*) FILTER (
    WHERE status = 'retry'::public.delivery_status
      AND next_retry_at IS NULL
  ) AS retry_without_next_retry_at,
  COUNT(*) FILTER (
    WHERE status IN ('queued'::public.delivery_status, 'retry'::public.delivery_status)
      AND claim_token IS NOT NULL
  ) AS queued_retry_with_claim_token,
  COUNT(*) FILTER (
    WHERE status = 'sending'::public.delivery_status
      AND claim_token IS NULL
  ) AS sending_without_claim_token
FROM public.deliveries;

-- Events should be produced by monitor/dispatcher/ingest paths
SELECT COUNT(*) AS events_last_60m
FROM public.events
WHERE ts >= now() - interval '60 minutes';
```
Note: after full pytest teardown on ephemeral test workspaces, `events_last_60m` may be `0` on a clean DB. Verify event emission inside monitor/dispatcher scenario checks as well.

## Export / Freeze
1. Export current active workflows from n8n.
2. Save to:
   - `n8n/workflows/<name>.json`
   - `workflows/<name>.json`
3. Commit only synchronized exports.

Recommended names:
- `01_ingest.json`
- `02_dispatcher.json`
- `03_monitor.json`
- `11_bot_ingest.json`
- `12_bot_engine.json`
- `13_bot_monitor.json`
- `adapter_telegram_send.json`
- `adapter_max_send.json`

## Rollback
1. Deactivate broken workflow in n8n UI/API.
2. Restore previous version:
   - Preferred: n8n UI `Versions` -> restore selected version.
   - Fallback: import synchronized JSON from git (`n8n/workflows/<name>.json`) and save.
3. Re-activate restored workflow.
4. Re-run smoke:
```bash
make wf03-monitor
make wf11-bot-ingest
make wf12-bot-engine
make wf13-bot-monitor
```
5. Re-run full regression:
```bash
make wf-tests
```
6. If rollback was done by manual import/patch, re-export and synchronize:
   - `n8n/workflows/<name>.json`
   - `workflows/<name>.json`

## Pre-Prod Rehearsal (2026-02-17)
Executed rollback drill on `12_bot_engine` (`x6SbMsgRue9eQP39`, node `Call adapter_max_send`):
1. Injected controlled fault (`workflowId=NON_EXISTENT_WORKFLOW_ID`).
2. Verified failure via strict test:
   - `test_workflow_12_bot_engine_state_outbox_idempotent` -> failed (`ok=false`, `Workflow does not exist`).
3. Restored working `workflowId` (`Vmk0MqDaJDFos5sM`) and reran strict test -> passed.
4. Final full regression after rollback:
   - `make wf-tests` -> `21 passed`.
