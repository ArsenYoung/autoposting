# Autoposting Workflows (n8n)

## 01_ingest (push + pull)
**Goal:** получить raw input из push/pull, провалидировать ingress, привести к детерминированному формату, и enqueue доставок через один SQL boundary.

### Triggers
- `Webhook Trigger` (push)
- `Cron Trigger` (pull)

### Flow (high-level)
1. Trigger fires -> set `kind` (`push|pull`), `run_id`, `now_ts`.
2. Branch by `kind`:
   - `push`: resolve endpoint -> create `ingest_run(workspace_id, ...)` -> run ingress guard.
   - `pull`: list active workspaces -> for each workspace create `ingest_run(workspace_id, ...)` -> fetch items from enabled sources and resolve per-source `endpoint_id`.
3. Normalize each accepted raw payload into internal deterministic format.
4. If media exists: materialize origin in object storage, upsert `media_origin`, keep only `blob_ref` in payload.
5. Enqueue in Postgres:
   - push: single-item call
   - pull: batch call per source/chunk (to reduce Neon round-trips and latency).
6. Finalize `ingest_runs` (`stats_json`, `finished_at`) for each created run.

### Stage details

#### 1) Bootstrap by trigger kind
- Push path:
  - resolve tenant only via `workspace_endpoints` by `(kind=webhook_push, secret_hash)` -> (`workspace_id`, `endpoint_id`)
  - then insert `ingest_runs(workspace_id, run_id, kind='push', started_at=now())`
- Pull path:
  - list active workspaces
  - inside workspace loop insert `ingest_runs(workspace_id, run_id, kind='pull', started_at=now())`
  - source-level `endpoint_id` is resolved later per `pull_source` via `workspace_endpoints(kind='pull_source', source_id, enabled=true)`

#### 2) Ingress guard (push)
- Validate request size (`max_payload_bytes`).
- Apply ingress rate gate (`ingress_rps`).
- Apply short-window dedup via `ingress_receipts`:
  - by `source_ref` (if provided)
  - else by `payload_hash` within `hash_drop_window_sec`.
- If dropped:
  - emit `events.action` in `ingress_*` family (`ingress_rate_limited|ingress_payload_rejected|ingress_dedup_dropped`)
  - update `ingest_runs.stats_json`
  - finalize run (`finished_at`)
  - stop processing.

#### 3) Pull fetcher (pull)
- For each active workspace (from bootstrap), load enabled `pull_sources` with mapped source endpoint.
- For each source:
  - resolve `source_endpoint_id` via `workspace_endpoints(kind='pull_source', source_id, enabled=true)`
  - if endpoint is missing/disabled -> emit `events.action='ingress_config_error'`, increment skipped counter, continue with next source
  - read `pull_cursors`
  - request source API/feed
  - build deterministic `source_ref` per item (source item id, or stable `url+ts` fallback)
  - convert each accepted item to the same raw payload envelope used by push path and attach resolved `source_endpoint_id`
  - group accepted items into pull-enqueue chunks (e.g., 50-200 items, tunable).
  - call DB function per chunk:
    - `ingest_pull_chunk(workspace_id, source_id, endpoint_id, items_jsonb, now_ts)`
    - inside DB function (single transaction): insert `pull_receipts` (`ON CONFLICT DO NOTHING`) -> enqueue accepted items via `enqueue_messages_and_deliveries_batch(...)` -> return `cursor_to`
  - advance `pull_cursors` only with returned `cursor_to` after successful function commit.
  - on failure, do not advance cursor; reprocessing is allowed, skipping is not.

#### 4) Normalize (Code node / sub-workflow)
- Single deterministic normalization contract for push and pull:
  - unified payload shape (`text|media`)
  - ordered `media[]`
  - canonical URLs
  - deterministic `tags`
  - stable hash input fields.

#### 5) Store media origin (if media)
- Download source media.
- Upload to object storage (S3/MinIO/etc).
- Upsert `media_origin(workspace_id, blob_ref, origin_url, ...)`.
- Replace source media refs in payload with logical `blob_ref`.

#### 6) ENQUEUE (Postgres, one boundary)
- Call:
  - push: `enqueue_messages_and_deliveries(workspace_id, endpoint_id, kind, raw_payload_json, now_ts)`
  - pull: `ingest_pull_chunk(workspace_id, source_id, endpoint_id, items_jsonb, now_ts)` (internally uses `enqueue_messages_and_deliveries_batch`)
- `endpoint_id` is mandatory:
  - push: `endpoint_id` from `workspace_endpoints(kind='webhook_push', secret_hash)`
  - pull: `endpoint_id` from `workspace_endpoints(kind='pull_source', source_id)`
- Pull path must not call enqueue per item and must not split receipts/enqueue into separate n8n DB calls.
- Inside function (must be in DB):
  - UPSERT `messages`
  - routing by `channels.route_filter` / tags
  - per-channel dedup TTL (`sent_at`, default 7 days) + inflight guard
  - preflight validation (Telegram/MAX)
  - render -> `deliveries.rendered_text`, `deliveries.render_meta`
  - create `deliveries` rows.

#### 7) Finalize ingest_run (Postgres)
- Update `ingest_runs` for current run/workspace:
  - `stats_json` (accepted, dropped, deduped, validation_failed, enqueued, etc.)
  - `finished_at=now()`.

### Non-negotiable boundary (critical)
- Do not loop over channels in n8n to create deliveries.
- Do not implement dedup/inflight guard/rate-slot logic in n8n nodes.
- All guarantees (dedup, inflight guard, atomic enqueue/routing) must live in Postgres functions.
- n8n role here is orchestration only: trigger -> call DB function(s) -> move data -> finalize.

## 02_dispatcher (allocator + sender loop)
**Goal:** атомарно claim-ить готовые доставки, отправлять через adapter по платформе и коммитить результат в БД.

### Trigger
- `Cron Trigger` every 2–5 seconds (10s for demo).
- Single-run guard (must):
  - DB advisory lock for dispatcher run scope is mandatory (primary guarantee across workers/instances)
  - workflow-level `concurrency=1` is recommended as additional guard, but not sufficient alone.

### Flow (high-level)
1. Select workspace window by dispatcher cursor (round-robin).
2. Iterate selected workspaces (`Split in Batches`).
3. Claim due-now deliveries in DB (`claim_deliveries`) and get already-leased `sending` rows.
4. Send each leased delivery via platform adapter.
5. Commit outcome via DB function (`mark_sent` / `schedule_retry` / `fail_permanent`).

### Stage details

#### 1) Select workspace window (Postgres)
- Query `workspaces` with `status='active'` using cursor/round-robin strategy (production default).
- Persist progress in `dispatch_cursor` (or equivalent state row) so next run starts from next workspace.
- Update cursor only after window processing (or at least after successful claim stage), never at window start.
- Crash-safety rule: reprocessing current window is acceptable; skipping unseen workspace is not.

#### 2) For each workspace (`Split in Batches`)
- Fairness rule: round-robin by workspace is required for dispatcher; plain fixed-order scan is not enough at scale.

#### 3) CLAIM (Postgres) - Contract (must)
- Call:
  - `claim_deliveries(workspace_id, run_id, limit)`
- Returned batch guarantees:
  - only rows with `not_before <= now()` are selected
  - `status='sending'`
  - `claim_token` is set
  - `sending_lease_until > now()`
  - `attempt = attempt + 1` is applied atomically during transition to `sending`
  - future-slot rows remain `queued/retry` until due time (not claimed early)
  - channel/platform locks and gate updates handled atomically in DB.

#### 4) Send each delivery
- Route by `channels.platform`:
  - `telegram` -> `adapter_telegram_send`
  - `max` -> `adapter_max_send`
- Adapter output contract (always normalized):
  - success: `ok=true`, `provider_message_id`, `raw`
  - failure: normalized `error` (`category`, `scope`, `code`, `retry_after_ms?`, `message`, `raw`).

#### 5) Commit result (Postgres)
- On success:
  - `mark_sent(workspace_id, delivery_id, provider_message_id, sent_at, raw_meta_json)`
- On transient:
  - `schedule_retry(workspace_id, delivery_id, next_retry_at, error_json)`
  - `schedule_retry` must not modify `attempt` (it updates status/next retry/error only)
  - retry scheduling policy (must be centralized in SQL, fixed params):
    - `base=2s`, `cap=10m`, `jitter=+/-20%` (applied to computed delay)
    - attempt semantics: `attempt` is send number (`attempt=1` for first send)
    - `retry_after_ms` has priority when present:
      - `next_retry_at = now + retry_after_ms +/- jitter`
    - otherwise exponential:
      - `next_retry_at = now + min(10m, 2s * 2^(attempt-1)) +/- jitter`
- On permanent:
  - `fail_permanent(workspace_id, delivery_id, error_json)`
  - channel penalties for `scope=channel` should be applied inside `fail_permanent`.
- Commit functions must accept only `status='sending'` rows with matching `claim_token`.
- Max attempts / DLQ:
  - if `attempt >= max_attempts` -> transition to `dead` + emit `dead_letter` + alert
  - no automatic retries after `dead`; only manual SQL `requeue/skip` from runbook.

### Boundary rule
- Claim/slotting/max_parallel/rate updates and state transitions are DB responsibilities.
- Delivery transitions must be atomic (`queued|retry -> sending -> sent|retry|dead`) inside DB transaction boundaries.
- Sending lease is mandatory before external API call and must be set by `claim_deliveries`.
- `attempt` is incremented only in `claim_deliveries` during `-> sending`; commit/retry functions must not increment it.
- `mark_sent` / `schedule_retry` / `fail_permanent` must verify `status='sending'` and `claim_token` to prevent stale/double commit.
- n8n in this workflow only orchestrates: select workspace window -> claim -> call adapter -> commit.
- Delivery semantics: system is `at-least-once` for external side effects; duplicates are possible on crash between send and commit.
- If provider supports idempotency keys (`client_message_id`/equivalent), use `delivery_id`; otherwise duplicate risk is accepted by design.

## Sub-workflow: adapter_telegram_send
**Goal:** send Telegram messages/media with provider materialization cache and normalized error contract.

### Input
- `delivery`
- `channel`
- `rendered_text`
- `payload.media[]` (ordered, optional)
- `meta.parse_mode`

### Output (normalized)
- Success:
  - `ok=true`
  - `provider_message_id`
  - `raw`
- Error:
  - `ok=false`
  - normalized `error` (`category=TRANSIENT|PERMANENT`, `scope=delivery|channel|platform`, `code`, `retry_after_ms?`, `message`, `raw`)

### Flow

#### 1) Resolve Telegram media materialization
- For each media item, lookup `media_blobs(workspace_id, blob_ref, provider='telegram')`.
- If `file_id` exists -> use it directly.
- If missing:
  - read `media_origin.origin_url`
  - upload media to Telegram
  - upsert `media_blobs(provider='telegram', file_id, meta, updated_at)`.

#### 2) Send by payload type
- Text-only -> `sendMessage`.
- Multi-media -> `sendMediaGroup` with caption/limit rules from architecture contract.
- Single media -> regular media send method with caption policy.

#### 3) Normalize adapter errors
- Map provider/network errors to normalized contract:
  - `TRANSIENT|PERMANENT`
  - `scope=delivery|channel|platform`
  - include `retry_after_ms` when provider returns it.

## Sub-workflow: adapter_max_send (real upload flow)
**Goal:** safely send MAX messages with media materialization/upload, deterministic series behavior, and normalized adapter output.

### Input
- `delivery`
- `channel`
- `rendered_text`
- `payload.media[]` (ordered)
- `meta.parse_mode`

### Output (normalized)
- Success:
  - `ok=true`
  - `provider_message_id`
  - `raw`
- Error:
  - `ok=false`
  - normalized `error` (`category`, `scope`, `code`, `retry_after_ms?`, `message`, `raw`)

### Flow

#### 1) Resolve provider materialization (per media item)
- Lookup `media_blobs(workspace_id, blob_ref, provider='max')`.
- If valid provider ref exists (token/file id present and not expired) -> use it.
- Else (missing/expired):
  - read `media_origin.origin_url`
  - download binary with strict size/time limits
  - map media type for upload session (`type=image` for images; `type=photo` is deprecated/unsupported)
  - create MAX upload session: `POST /uploads?type=...` with `Authorization` header (no query-token auth)
  - upload binary to returned `upload_url` via `POST multipart/form-data` (`data=@file`) (not PUT)
  - TODO (must before production): verify finalize/confirm requirement per MAX media type (`image|video|file`) and add explicit step map in adapter implementation
  - upsert `media_blobs(provider='max', token/file_id, expires_at, meta)`

#### 2) Send message
- Build MAX `POST /messages` payload:
  - `attachments` from step 1
  - `text=rendered_text`
  - pre-send guard: MAX text length must be `<= 4000`; if exceeded -> return `PERMANENT`, `scope=delivery`, `code=message_too_long` (no retry)
  - `format` from `meta.parse_mode` (`html|markdown` when parse mode set, plain text otherwise)
  - send with `Authorization` header (no query-token auth)
- If MAX has native group send for current payload -> send once.
- If MAX has no native group send -> deterministic degrade-to-series in `payload.media[]` order.

#### 3) Series progress + retries (mandatory for degrade path)
- Adapter returns `series_progress_delta` (acked item indexes/ids); adapter itself does not write DB.
- Commit functions (`mark_sent`/`schedule_retry`) atomically merge `series_progress_delta` into `deliveries.render_meta.series_progress`.
- Idempotency rules for retries:
  - never re-upload already acknowledged items; reuse existing `media_blobs(workspace_id, blob_ref, provider='max')`
  - build retry attachments from tail-only set (items not present in acked progress)
- On partial failure:
  - return normalized transient/permanent error
  - `attachment.not.ready` must be normalized as `TRANSIENT` (`scope=delivery`)
  - scheduler commits via `schedule_retry(...)` with increasing backoff (no `Wait` nodes)
  - next retry sends only unsent tail items (never resends already acknowledged items).
- On full success:
  - return primary/group `provider_message_id` + per-item ids in `raw`.

### Main risk: large media files
- n8n binary handling may buffer large files in worker memory and crash on video/file-heavy loads.
- Recommended scale path (Variant B): use an upload-proxy microservice for `S3 -> MAX` transfer with streaming (no full buffering in n8n memory).
- n8n then calls proxy and receives attachment descriptor/token only.

## 03_monitor
**Goal:** автоматически чистить "залипшие" состояния, поднимать алерты по рисковым метрикам и давать короткий health snapshot.

### Trigger
- `Cron Trigger` every 1 minute

### Flow (high-level)
1. Run stuck guards in Postgres (lease recovery).
2. Evaluate alert conditions.
3. Optionally build health snapshot (status counts + top errors).
4. Send alert/snapshot to admin channel (Telegram) or other configured target.

### Stage details

#### 1) Stuck guards (Postgres)
- `sending lease expired`:
  - run DB recovery method (e.g., `recover_sending_leases(workspace_id, now_ts)`) instead of n8n-side updates
  - DB method finds `deliveries.status='sending'` older than lease threshold
  - if `attempt >= max_attempts` -> move to `dead` + emit `events.action='dead_letter'` + alert
  - else move to `retry` only via centralized retry policy (same policy as `schedule_retry`, no separate monitor backoff logic)
  - emit `events.action='sending_lease_expired'` for recovered rows
- `claimed lease expired` (compatibility guard for legacy/manual flows):
  - find stale `deliveries.status='claimed'`
  - move to `queued` (or `retry` by policy)
  - emit `events.action='claimed_lease_expired'`

#### 2) Alerts
- Trigger alert if any condition is true:
  - `dead > 0`
  - `failed_permanent` in last 10 minutes `> X`
  - active paused channels (`paused_until > now()`) `> Y`

#### 3) Health snapshot (optional)
- Build compact snapshot:
  - counts by `deliveries.status`
  - top error codes/messages for recent window
- Send to admin chat on schedule or only when thresholds breached (policy switch).

### Boundary rule
- Guard transitions and alert-source queries should run via SQL (single source of truth in DB).
- n8n in this workflow only schedules, calls DB steps, and sends notifications.

## Bot workflows (MAX shop bot without magic)
**Goal:** deterministic FAQ/scenario bot with explicit state, idempotency, and shared outbound adapter path.

## 11_bot_ingest (Webhook)
### Trigger
- `Webhook Trigger` (MAX bot webhook)

### Stage details
1. Resolve endpoint:
   - `workspace_endpoints(kind=bot_webhook, secret_hash)` -> (`workspace_id`, `endpoint_id`).
2. Inbound dedup:
   - insert into `bot_inbox` with unique key by message/chat identity (schema: `workspace_id, provider, chat_id, provider_message_id`).
   - on conflict -> stop (duplicate webhook).
3. Call `12_bot_engine` with normalized inbound payload/context.

## 12_bot_engine
### Stage details
1. Load `bot_state` for (`workspace_id`, `chat_id`).
2. Apply `bot_rules` (FAQ/scenario matching + priority).
3. Write `bot_outbox` idempotency record for current inbound message.
   - on conflict -> stop (already answered).
4. Send response via `adapter_max_send` (text path).
5. Update `bot_state` and write `bot_logs` (`matched_rule_id`, `rule_version`, state transition, meta).

## 13_bot_monitor (optional)
### Trigger
- `Cron Trigger` (e.g., every 1 minute)

### Responsibilities
- Alert on bot error spikes and repeated adapter failures.
- Report unmatched intents / fallback rate.

## Architecture safety checklist (must pass)
- No `Wait` nodes for schedules/retries.
- No n8n loops over channels for enqueue.
- Pull enqueue uses batch SQL calls (not per-item SQL calls).
- Claim/slotting only in SQL functions; keep transactions short (Neon-friendly).
- DB advisory lock is mandatory for dispatcher; `concurrency=1` is optional extra safety.
- Dispatcher fairness uses workspace cursor/round-robin.
- Retry path must not re-render content; reuse stored `deliveries.rendered_text` (and `render_meta`).

## Runtime config (baseline)
- `PULL_CHUNK_SIZE=100`
- `DISPATCHER_LIMIT_PER_WORKSPACE=100`
- `ALERT_DEAD_THRESHOLD=1`
- `ALERT_FAILED_PERM_10M=20`
- `ALERT_PAUSED_CHANNELS=10`
- `MAX_MEDIA_BYTES_IMAGE=10485760`
- `MAX_MEDIA_BYTES_VIDEO=52428800`
- `DOWNLOAD_TIMEOUT_MS=30000`
