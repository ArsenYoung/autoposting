# Autoposting Reference (A) + Bot Reference (B)
**Goal:** universal, production-minded reference implementation on n8n (config-driven, observable, maintainable) for:
1) Autoposting to **Telegram + MAX** across ~40 channels  
2) A **MAX shop chat bot** (FAQ + сценарии) “без магии”, расширяемый

---

## Non-goals (чтобы не превращалось в лабораторку/фреймворк)
- Нет LLM. Только rule engine + state machine (предсказуемость и поддерживаемость).
- Нет “универсального CMS”. Источник контента абстрактный (push/pull).
- Нет UI-админки: управление через таблицы + примеры seed.
- Гарантия доставки: **at-least-once**, но с **idempotency** на отправку и **per-channel dedup**.

---

## Key guarantees (то, что продаёт “production thinking”)
- **Config-driven:** добавление/отключение канала — через `channels`, без правок workflow.
- **Scales to N channels:** payload хранится один раз в `messages`, статусы — в `deliveries`; ingest использует set-based SQL без ветвления workflow.
- **Per-channel dedup:** один пост может уйти в 40 каналов, но повтор в тот же канал в пределах TTL (7 days) блокируется.
- **Rate limits + retries:** 429/503 → backoff + retry, с записью в audit log.
- **Bad-channel isolation:** недоступный/забаненный канал не стопорит очередь.
- **Observability:** таблица `events` (аудит) + алерты + контроль `paused/dead` (при переходе в `dead` пишем event `dead_letter`).

---

## Architecture overview

### Components (минимум, но взрослый)
- **n8n workflows (3)**
  1. `01_ingest` — push+pull → normalize → write `messages` → enqueue `deliveries` (set-based SQL + routing + dedup)
  2. `02_dispatcher` — iterate active `workspaces` and call `claim_deliveries(workspace_id, ...)` per workspace (fairness best-effort) → rate/parallel → adapter → events/`deliveries` updates
  3. `03_monitor` — alerts + retry scheduler + health snapshot

- **DB tables (core + aux)**
  - `workspaces`, `workspace_endpoints` — tenant boundary and ingress mapping
  - `channels`, `platform_limits` — routing and rate gates (including shared `rate_group` throttles)
  - `messages`, `media_origin`, `media_blobs` — content + media origin + provider materialization
  - `deliveries`, `events` — queue state and audit
  - `pull_sources`, `pull_cursors`, `ingest_runs` — pull state/watermarks and observability

- **Adapters (2)**
  - `telegram` — реальный отправщик
  - `max` — реальный отправщик по API MAX (или временно stub с тем же контрактом)

---

## Adapter contract (центральный артефакт, анти-“магия”)

### sendText
Input:
- `channel` (workspace_id, platform, channel_id, auth_ref, rate_group, settings)
- `text` (string)
- `meta` (`parse_mode` internal=`HTML|Markdown|None`, disable_preview, buttons, trace_id, idempotency_key, etc.)

Output:
- `provider_message_id` (string)
- `raw` (json)

Errors (normalized):
- `category`: `TRANSIENT | PERMANENT`
- `scope`: `delivery | channel | platform`
- `code`: string (HTTP code / provider code)
- `retry_after_ms?`: number (если есть)
- `message`: string
- `raw`: json

### sendMedia
Input:
- `channel`
- `media[]` (ordered array; each item: `type`, `url|file_id|blob_ref|attachment_token`, optional per-item caption/meta)
  - if `blob_ref` provided on item → resolve via `media_blobs`
- `text?` (optional post text/caption shared for batch where platform supports it)
- `links?` (optional array)
- `meta`

Output / Errors — same as `sendText`

Batch send semantics:
- Telegram: `media[].length > 1` should use media-group API (`sendMediaGroup`); single item may use regular single-media send
- Telegram album caption fallback (deterministic): if `media[].length > 1` and full text/caption may exceed 1024, send separate `sendText` first, then `sendMediaGroup` without caption (or with fixed short caption policy)
- `provider_message_id` for batch stores provider group id (if available) or primary/first message id; full per-item ids live in adapter `raw`/event `meta`
- For MAX degrade-to-series, delivery keeps series progress in `deliveries.render_meta.series_progress` (e.g., `sent_items`, `provider_message_ids`) and retries only unsent tail items

### MAX adapter profile (required before non-stub production)
- Media flow (MAX official docs): request upload session via `POST https://platform-api.max.ru/uploads?type=...`, upload binary to returned upload URL, then send `POST https://platform-api.max.ru/messages` with `attachments` token/payload from upload response
- Attachment type mapping: for images use `type=image` (not legacy `photo`)
- Upload strategy policy switch (required config): central map by media type (`image|video|file|audio|other`) -> `upload_required|url_allowed`; default for production is `upload_required`
- Text/format contract (MAX): text length <= 4000; message `format` must be `html|markdown`
- Parse-mode mapping (required): internal `meta.parse_mode=HTML -> format=html`, `Markdown -> format=markdown`, `None -> send without format/plain`
- Mandatory format rule: if `meta.parse_mode != None`, MAX adapter must always set `format` and validate compatibility before send; if `meta.parse_mode=None`, send plain text without `format`
- Fallback rule: if payload/entities are incompatible with selected format, preflight must fail (`validation_failed`) or sanitize to plain text by explicit adapter policy (no implicit mixed behavior)
- Multi-media behavior: if MAX supports native grouped media, send one grouped payload; otherwise deterministically degrade to a series of messages in `media[]` order (same trace/idempotency context)
- If degraded series is partially sent and then fails, persist acknowledged item indexes in `render_meta.series_progress` and schedule retry for remaining items only (no full-series resend)
- Limits: shared throttle via `platform_limits` keyed by (`workspace_id`, `platform='max'`, `rate_group`), per-chat throttles via `channels.rate_rps` / `channels.max_parallel`
- MAX error scope baseline:
  - auth/access/chat-not-found → `PERMANENT`, `scope=channel`
  - payload/validation/media-format errors → `PERMANENT`, `scope=delivery`
  - `429` / `5xx` / network timeouts → `TRANSIENT`, `scope=platform`
  - upload-processing `attachment.not.ready` (MAX docs) → `TRANSIENT`, `scope=delivery` (short retry)
- MAX attachment tokens may be short-lived; `media_blobs(provider='max')` should be treated as near-term retry cache, not long-term guarantee

---

## Outgoing idempotency (best-effort)
- `idempotency_key = delivery_id` передаётся в адаптер, если API поддерживает
- Если платформа не поддерживает, ключ всё равно логируется в `events.meta`
- При `at-least-once` и отсутствии provider idempotency возможен редкий дубль: API принял сообщение, но воркер упал до фиксации `sent` в БД
- Baseline mitigation:
  - писать `events.action='send_attempt'` **до** вызова API
  - после ответа API как можно быстрее фиксировать `provider_message_id` / `sent_at` и result-event
  - optional: reconcile job/manual tooling для бизнес-критичных кейсов

---

## Data model requirements

Workspace/tenant scope (required):
- Core tables are workspace-scoped: `channels`, `platform_limits`, `messages`, `media_origin`, `media_blobs`, `deliveries`, `events`, `pull_sources`, `pull_cursors`, `ingest_runs` (and bot tables below)
- Operational PK model (fixed): composite primary keys for queue core tables — `channels(workspace_id, channel_id)`, `messages(workspace_id, message_id)`, `deliveries(workspace_id, delivery_id)`
- Uniqueness/dedup/index keys must include `workspace_id`
- Cross-table references must be composite by workspace (`deliveries -> (workspace_id, message_id)/(workspace_id, channel_id)`); for `events` the same ids are stored as logical references (`workspace_id` + entity id), write-path may skip hard FKs in high-throughput mode
- Ingest/dispatcher/monitor queries must always filter by `workspace_id`

### Table: workspaces
**Purpose:** tenant registry and lifecycle.

Required fields:
- `workspace_id` (uuid/text, pk)
- `name` (string)
- `status` (`active|paused|disabled`)
- `created_at`

### Table: workspace_endpoints
**Purpose:** map inbound entrypoints to a workspace with isolated secrets.

Required fields:
- `endpoint_id` (uuid/text)
- `workspace_id` (fk -> workspaces)
- `kind` (`webhook_push|bot_webhook`)
- `secret_hash` (string, e.g. sha256 of incoming secret/token)
- `enabled` (bool)
- `ingress_rps` (number, default 5) — per-endpoint flood gate
- `max_payload_bytes` (int, default 262144) — hard payload size limit
- `hash_drop_window_sec` (int, default 10) — duplicate-hash drop window when `source_ref` is absent
- `meta` (jsonb: endpoint name/description/config hints; no secrets)
- `created_at`, `updated_at`

Constraints:
- primary key (`workspace_id`, `endpoint_id`)
- partial unique (`kind`, `secret_hash`) where `enabled=true` — only one active endpoint per secret/kind; disabled history allowed

Indexes:
- partial `(kind, secret_hash)` where `enabled=true` — fast ingress lookup for active endpoint resolution

Rules:
- Incoming request/source must resolve exactly one enabled endpoint row (`workspace_id`, `endpoint_id`) via `workspace_endpoints`
- Requests/sources without a valid enabled endpoint are rejected (no implicit default workspace)
- `workspace_id` from inbound payload/headers/query is not trusted for routing; if present, treat it as optional hint in `meta` and ignore for tenant resolution
- Ingress guard must enforce `ingress_rps` and `max_payload_bytes` before enqueue path
- Ingress dedup/rate identity uses resolved `endpoint_id` (not just `kind`)
- Endpoint secret rotation: create new endpoint row (`enabled=true`) and then disable previous row; keep old row for audit/history without uniqueness conflicts

### Table: channels
**Purpose:** config-driven routing, per-channel limits, enable/disable, quarantine.

Required fields:
- `workspace_id` (uuid/text)
- `channel_id` (text/uuid)
- `platform` (`telegram` | `max`)
- `target_id` (tg chat/channel id or max chat id)
- `auth_ref` (string) — stable logical credential key (not raw n8n credential ID); resolved to actual secret via credential binding
- `rate_group` (string) — shared throttle bucket id (usually equals `auth_ref`, but explicit field is preferred)
- `enabled` (bool)
- `title` (string, optional)
- `send_mode` (`text` | `media` | `mixed`)
- `rate_rps` (number, per-channel, default 1; null/0 disables rate limit)
- `max_parallel` (int, per-channel)
- `next_allowed_at` (timestamp, nullable) — DB-rate limit gate
- `paused_until` (timestamp, nullable)
- `timezone` (text, IANA, optional) — для окон/расписаний
- `window_mode` (`immediate|windowed`, default `immediate`)
- `posting_window` (jsonb, nullable) — описание окон по дням
- `dedup_ttl_hours` (int, nullable, default 168) — per-channel TTL override for dedup window
- `error_streak` (int, default 0) — подряд идущие `PERMANENT` ошибки канала (`scope=channel`); reset на `sent`
- `settings` (jsonb: parse_mode, disable_preview, etc.)
- `tags` (text[], optional) — сегментация каналов
- `route_filter` (jsonb, optional) — include/exclude правила по `message.tags`
- `created_at`, `updated_at`

Constraints:
- primary key (`workspace_id`, `channel_id`)
- unique (`workspace_id`, `platform`, `target_id`) — предотвращает дубли каналов и двойные доставки в один и тот же destination

Indexes:
- `(workspace_id, enabled)`
- GIN (`tags`)

Optional (rotation-friendly auth storage):
- `channel_auth(workspace_id, channel_id, auth_ref, rotated_at, updated_at)`
- `channel_auth` key/constraint: primary key (`workspace_id`, `channel_id`)
- adapter читает актуальный `auth_ref` из `channel_auth`; `channels.auth_ref` можно оставлять как baseline/MVP
- optional credential registry: `credential_bindings(workspace_id, auth_ref, platform, secret_ref, rotated_at, updated_at)` where `secret_ref` points to n8n/external secret store

Operational rules:
- if `enabled=false` → dispatcher skips
- if `paused_until > now()` → dispatcher skips until time passes
- `next_allowed_at` управляется allocator’ом при назначении слотов
- `route_filter` применяется в ingest при выборе каналов
- `window_mode=windowed` активирует правила окон (см. Scheduling hooks)

---

### Table: platform_limits
**Purpose:** shared rate ceiling per provider credential/group (e.g., общий лимит токена TG/MAX).

Required fields:
- `workspace_id` (uuid/text)
- `platform` (`telegram` | `max`)
- `rate_group` (string)
- `rate_rps` (number, nullable; null/0 disables platform ceiling)
- `next_allowed_at` (timestamp, nullable)
- `updated_at`

Constraints:
- primary key (`workspace_id`, `platform`, `rate_group`)

Operational rules:
- allocator applies group ceiling by `(workspace_id, platform, rate_group)` only if `rate_rps > 0`
- update `next_allowed_at` выполняется атомарно под group-level lock (`FOR UPDATE` на строку `platform_limits` или advisory lock per (`workspace_id`, `platform`, `rate_group`))

---

### Table: messages
**Purpose:** store normalized payload once; reusable across deliveries.

Required fields:
- `workspace_id` (uuid/text)
- `message_id` (uuid)
- `hash_version` (int, default 1)
- `content_hash` (string) — hash(normalized payload) under `hash_version`; for multi-media includes ordered `payload.media[]`
- `normalization_version` (int, optional)
- `payload` (jsonb) — normalized send payload (`type=text|media`, body; media payload uses ordered `media[]`)
- `tags` (text[], optional) — deterministic routing tags derived from normalized payload (no source/time/context drift)
- `source` (jsonb, optional) — origin info (webhook/feed/etc.)
- `source_ref` (string, optional) — id from source (if available)
- `first_seen_trace_id` (uuid or text) — trace id at first insert of this `content_hash`
- `first_ingest_run_id` (uuid or text) — ingest batch/run id at first insert of this `content_hash`
- `last_seen_at` (timestamp) — updated on each repeated ingest of same (`workspace_id`, `hash_version`, `content_hash`)
- `last_ingest_run_id` (uuid or text) — latest ingest run that saw this message
- `seen_count` (bigint, default 1) — number of times this normalized message was seen
- `created_at`

Constraints:
- primary key (`workspace_id`, `message_id`)

Indexes:
- `(workspace_id, hash_version, content_hash)`
- `(workspace_id, created_at)`
- GIN (`tags`)
- unique (`workspace_id`, `hash_version`, `content_hash`) (см. Dedup)

---

### Table: media_origin
**Purpose:** stable origin storage for media binaries (provider-agnostic).

Required fields:
- `workspace_id` (uuid/text)
- `blob_ref` (string)
- `origin_url` (string) — stable object-storage URL (S3/Yandex/MinIO), not temporary source URL
- `sha256` (string, nullable)
- `content_type` (string, nullable)
- `size_bytes` (bigint, nullable)
- `last_seen_at` (timestamp, default `now()`) — updated when `blob_ref` is seen in normalized payload
- `ref_count` (bigint, default 0) — optional cached live-reference count (can be recomputed by cron)
- `created_at`

Constraints:
- primary key (`workspace_id`, `blob_ref`)

Rules:
- ingest (push/pull) stores incoming media in object storage, writes/upserts `media_origin`, and updates `last_seen_at`
- adapter uploads to provider from `media_origin.origin_url` when provider materialization is missing
- Object-storage GC policy (required):
  - run cron (daily/hourly) to compute live refs from `messages.payload.media[*].blob_ref` per `workspace_id` (or maintain `ref_count` incrementally and periodically reconcile)
  - delete origin object only when live refcount is `0` and `last_seen_at < now() - origin_retention_days` (default 30 days)
  - after successful object deletion, remove or mark the `media_origin` row as deleted
  - large-video override: for `content_type like 'video/%'` and `size_bytes >= large_video_bytes_threshold`, use shorter retention `origin_retention_large_video_days` (default 7 days)

---

### Table: media_blobs
**Purpose:** provider-specific media materialization for logical `blob_ref` (cross-post friendly).

Required fields:
- `workspace_id` (uuid/text)
- `blob_ref` (string) — logical asset id stored in payload
- `provider` (string) — e.g., `telegram|max|s3`
- `file_id` (string, nullable) — provider file id (preferred)
- `url` (string, nullable) — temporary URL if no `file_id`
- `expires_at` (timestamp, nullable)
- `meta` (jsonb, nullable)
- `created_at`, `updated_at`

Constraints:
- primary key (`workspace_id`, `blob_ref`, `provider`)

Rules:
- `payload.media[*].blob_ref` is logical; adapter resolves provider record by (`workspace_id`, `blob_ref`, `provider=channel.platform`)
- if provider-specific row is missing, adapter reads binary via `media_origin.origin_url`, uploads for target provider, and UPSERTs row into `media_blobs`
- send uses resolved `file_id` if present, otherwise `url`
- if provider materialization expired (`expires_at < now()`) and no `file_id`:
  - attempt rematerialization from `media_origin.origin_url` (upload + UPSERT)
  - if `media_origin` is missing/unavailable: set delivery `failed_permanent` with error `media_missing_origin`

---

### Table: deliveries
**Purpose:** per-channel delivery state with retry scheduling and idempotency (payload lives in `messages`).

Required fields:
- `workspace_id` (uuid/text)
- `delivery_id` (uuid)
- `message_id` (fk -> messages)
- `channel_id` (fk -> channels)
- `hash_version` (int) — copied from `messages.hash_version` for fast dedup checks
- `content_hash` (string, denormalized for dedup index)
- `not_before` (timestamp, default `now()` at enqueue)
- `scheduled_for` (timestamp, nullable) — future precise time
- `status` (`queued|claimed|sending|sent|retry|deduped|failed_permanent|dead`)
- `attempt` (int, default 0) — increment on each `claimed -> sending`
- `next_retry_at` (timestamp, nullable)
- `provider_message_id` (string, nullable)
- For batch media sends, `provider_message_id` stores group/primary id; full per-item ids are kept in adapter raw/event meta
- `sent_at` (timestamp, nullable) — set on `sending -> sent`; anchor for dedup TTL window
- `last_error` (jsonb, nullable) — normalized error
- `rendered_text` (text)
- `render_meta` (jsonb) — includes rendering params + optional series progress (`series_progress.sent_items`, `series_progress.provider_message_ids`)
- `template_version` (int or text)
- `trace_id` (uuid or text) — correlation id from current ingest for быстрых выборок
- `enqueue_batch_id` (uuid, optional) — защита от двойного enqueue в одном батче
- `claimed_at` (timestamp, nullable)
- `claim_token` (text, nullable)
- `sending_started_at` (timestamp, nullable) — set on `claimed -> sending`
- `created_at`, `updated_at`

Constraints (integrity):
- primary key (`workspace_id`, `delivery_id`)
- fk (`workspace_id`, `channel_id`) -> `channels(workspace_id, channel_id)`
- fk (`workspace_id`, `message_id`) -> `messages(workspace_id, message_id)`

Indexes:
- `(workspace_id, status, next_retry_at)`
- `(workspace_id, status, not_before, next_retry_at)`
- partial `(workspace_id, channel_id, hash_version, content_hash, sent_at)` where `status='sent'` and `sent_at is not null`
- partial `(workspace_id, channel_id, hash_version, content_hash, created_at)` where `status in ('queued','claimed','sending','retry')` — inflight duplicate guard
- partial `(workspace_id, channel_id, hash_version, content_hash)` where `status in ('sent','deduped')` — audit/lookup helper
- optional unique (`workspace_id`, `enqueue_batch_id`, `channel_id`, `hash_version`, `content_hash`) — guard against double enqueue in one batch

---

### Table: events
**Purpose:** audit log (что происходило и почему).

Required fields:
- `workspace_id` (uuid/text)
- `id` (uuid, pk)
- `delivery_id` (uuid, nullable)
- `message_id` (uuid, nullable)
- `channel_id` (nullable)
- `ts` (timestamp)
- `action` (`enqueue|validation_failed|send_attempt|sent|retry_scheduled|dedup_suppressed|failed_permanent|dead_letter|channel_paused|channel_disabled|channel_enabled|message_tag_mismatch|sending_lease_expired|claimed_lease_expired|manual_requeue|auth_rotated|ingress_rate_limited|ingress_payload_rejected|ingress_dedup_dropped`)
- `attempt` (int) — snapshot of current `deliveries.attempt` for delivery-scoped events; `0` when event has no delivery context
- `result` (`ok|error`)
- `error` (jsonb, nullable) — normalized error + short snippet only
- `payload_ref` (string, nullable) — pointer to full raw payload/log in object storage
- `meta` (jsonb: trace_id, workflow_run_id, etc.)

Constraints (write-path baseline):
- no hard FKs from `events` to `deliveries/messages/channels` (to keep high-throughput inserts cheap)
- logical integrity contract: writer must persist correct `workspace_id` + referenced ids

Indexes:
- `(workspace_id, ts desc)`
- `(workspace_id, action, ts desc)`
- `(workspace_id, result, ts desc)`
- partial `(workspace_id, delivery_id, ts desc)` where `delivery_id is not null`
- partial `(workspace_id, message_id, ts desc)` where `message_id is not null`
- partial `(workspace_id, channel_id, ts desc)` where `channel_id is not null`

Notes:
- Демо: в `events.error` хранить нормализованный error + короткий raw snippet (без полноразмерных raw)
- Для прод: full raw хранить вне БД; в `events` сохранять snippet + `payload_ref`
- `events.attempt` contract: if `delivery_id` is present, write current `deliveries.attempt`; if event has no delivery context, write `attempt=0`
- For actions before first send attempt (`enqueue`, `dedup_suppressed`) current `deliveries.attempt` is `0`
- Integrity reconciliation job (required for no-FK mode): periodic query detects orphan `events` references and emits alert/report
- Optional strict mode (low-volume/staging): enable composite FKs from `events` to `deliveries/messages/channels`

---

### Table: pull_sources
**Purpose:** pull-source registry per workspace.

Required fields:
- `workspace_id` (uuid/text)
- `source_id` (string)
- `kind` (string, e.g. `rss|db|api`)
- `config_json` (jsonb)
- `enabled` (bool)
- `created_at`

Constraints:
- primary key (`workspace_id`, `source_id`)

### Table: pull_cursors
**Purpose:** watermarks/cursors for pull sources.

Required fields:
- `workspace_id` (uuid/text)
- `source_id` (string)
- `cursor_json` (jsonb: `last_seen_ts`, `last_seen_id`, `etag`, ...)
- `updated_at`

Constraints:
- primary key (`workspace_id`, `source_id`)

### Table: ingest_runs
**Purpose:** ingest observability/debug for push and pull.

Required fields:
- `workspace_id` (uuid/text)
- `run_id` (uuid/text)
- `kind` (`push|pull`)
- `started_at`
- `finished_at` (nullable)
- `stats_json` (jsonb)

Constraints:
- primary key (`workspace_id`, `run_id`)

### Table: ingress_receipts
**Purpose:** ingress flood/dedup gate ledger (before message enqueue).

Required fields:
- `workspace_id` (uuid/text)
- `endpoint_id` (uuid/text) — resolved ingress endpoint identity
- `endpoint_kind` (`webhook_push|bot_webhook`)
- `source_ref` (string, nullable) — provider/source message id if available
- `payload_hash` (string) — hash of minimally normalized inbound payload for short-window dedup
- `received_at` (timestamp)
- `expires_at` (timestamp) — TTL cleanup for ledger rows

Constraints:
- partial unique (`workspace_id`, `endpoint_id`, `source_ref`) where `source_ref is not null`

Indexes:
- `(workspace_id, endpoint_id, payload_hash, received_at desc)` — duplicate-hash window checks
- `(expires_at)` — cleanup scan

Rules:
- If `source_ref` is present: `INSERT ... ON CONFLICT DO NOTHING`; conflict means duplicate inbound request and must be dropped before enqueue
- If `source_ref` is absent: drop inbound request when same (`workspace_id`, `endpoint_id`, `payload_hash`) exists in last `hash_drop_window_sec`
- Cron cleanup deletes expired rows (`expires_at < now()`) to keep table bounded

---

## Dedup requirements (fixed defaults)
- **Baseline:** per-channel dedup
- `dedup_key = workspace_id + channel_id + hash_version + content_hash` (логически, без отдельного поля)
- Для multi-media `content_hash` обязан учитывать порядок элементов `payload.media[]` (перестановка элементов = другой hash)
- Default **TTL window:** 7 days (`channels.dedup_ttl_hours`, default 168)

TTL механика (обязательная):
- `deliveries` хранит фактическую историю доставок
- В enqueue запросе **не создавать delivery для отправки**, если в том же `workspace_id` есть `sent` с `sent_at >= now() - interval '1 hour' * coalesce(ch.dedup_ttl_hours, 168)`
- В enqueue запросе **не создавать delivery для отправки**, если уже есть inflight delivery с тем же (`workspace_id`, `channel_id`, `hash_version`, `content_hash`) и `status in ('queued','claimed','sending','retry')` (optional bounded window: `created_at >= now()-interval '24 hours'`)
  - опционально: вставить `delivery` со `status=deduped` для аудита
- `deduped` записи не должны “продлевать TTL окно”; TTL считается от последнего фактического `sent_at`
- Нет “уникального индекса без TTL” (иначе таблица растёт бесконечно и блокирует легитимные повторы)

Индексы для dedup:
- partial `(workspace_id, channel_id, hash_version, content_hash, sent_at)` where `status='sent'` and `sent_at is not null`
- partial `(workspace_id, channel_id, hash_version, content_hash, created_at)` where `status in ('queued','claimed','sending','retry')` — inflight guard index
- partial `(workspace_id, channel_id, hash_version, content_hash)` where `status in ('sent','deduped')` — audit/helper index; TTL check must use `sent_at` index above

Фиксация для `messages` (чтобы не ломать дедуп):
- `messages` должны быть **UPSERT** по ключу (`workspace_id`, `hash_version`, `content_hash`)
- Это корректно при строгой и единой нормализации для всех источников
- On conflict (по (`workspace_id`, `hash_version`, `content_hash`)):
  - `payload`, `source`, `source_ref`, `first_seen_trace_id`, `first_ingest_run_id`, `tags` — **оставляем first-seen**
  - update `last_seen_at`, `last_ingest_run_id`, `seen_count = seen_count + 1`
- Если новые `tags` отличаются от first-seen, не мутировать `messages.tags`; писать событие `message_tag_mismatch` (или считать в `ingest_runs.stats_json`)
- Текущую корреляцию для конкретной попытки/прогона хранить в `deliveries.trace_id` и `events.meta.trace_id`
Защита от двойного enqueue:
- транзакция ingest + `NOT EXISTS` по дедуп-окну `sent_at` + `NOT EXISTS` по inflight статусам (`queued|claimed|sending|retry`)
- optional `enqueue_batch_id` + unique (`workspace_id`, `enqueue_batch_id`, `channel_id`, `hash_version`, `content_hash`)

Expected behavior:
- Same content → 2 different channels: **allowed**
- Same content → same channel повторно: **suppressed** (event `dedup_suppressed`, optional `status=deduped`)
- Same content → same channel while first delivery is inflight (`queued|claimed|sending|retry`): **suppressed**
- Same content → same channel after TTL (7 days): **allowed**

---

## Routing rules / segmentation (масштаб без ветвлений)
- `channels.tags` (text[]) и/или `channels.route_filter` (jsonb include/exclude)
- `message.tags` вычисляется в ingest детерминированно из normalized payload
- Теги, зависящие от source/time/context, не должны записываться в `messages.tags`
- Выбор каналов — SQL-фильтр по пересечению `message.tags` и `route_filter`

Физический формат (fixed):
- `messages.tags`: `text[]`, canonical lowercase, deduplicated
- `channels.tags`: `text[]`, canonical lowercase, deduplicated
- `channels.route_filter`: `jsonb` with keys `include_any`, `include_all`, `exclude`; each key contains JSON array of lowercase strings
- Indexing: GIN on `messages.tags` and GIN on `channels.tags`

Формат `route_filter` (jsonb, фиксированный контракт):
```json
{
  "include_any": ["crypto", "ru"],
  "include_all": ["listing"],
  "exclude": ["nsfw"]
}
```

Правила:
- `include_any`: пересечение непустое
- `include_all`: все теги должны присутствовать
- `exclude`: ни один не должен присутствовать
- если `channel.route_filter` is null → канал получает **все** сообщения
- если `message.tags` is null/empty → считается пустым множеством; тогда проходят только каналы без include-условий

SQL matching template (Postgres):
```sql
with ch as (
  select
    c.*,
    coalesce(array(select jsonb_array_elements_text(c.route_filter->'include_any')), '{}'::text[]) as rf_any,
    coalesce(array(select jsonb_array_elements_text(c.route_filter->'include_all')), '{}'::text[]) as rf_all,
    coalesce(array(select jsonb_array_elements_text(c.route_filter->'exclude')), '{}'::text[]) as rf_ex
  from channels c
  where c.workspace_id = :workspace_id
    and c.enabled = true
)
select ch.channel_id
from ch
join messages m
  on m.workspace_id = ch.workspace_id
 and m.message_id = :message_id
where (cardinality(ch.rf_any) = 0 or coalesce(m.tags, '{}'::text[]) && ch.rf_any)
  and (cardinality(ch.rf_all) = 0 or coalesce(m.tags, '{}'::text[]) @> ch.rf_all)
  and (cardinality(ch.rf_ex) = 0 or not (coalesce(m.tags, '{}'::text[]) && ch.rf_ex));
```

---

## Scheduling hooks (без Wait-узлов)
Цель: иметь расписания/окна без переписывания логики (immediate по умолчанию).

Хуки в `channels`:
- `timezone` (IANA)
- `window_mode = immediate | windowed` (default `immediate`)
- `posting_window` (jsonb) — окна по дням

Хуки в `deliveries`:
- `not_before` (default `now()` при enqueue)
- `scheduled_for` (nullable, для точного времени в будущем)

Правило выбора в dispatcher:
- `deliveries.not_before <= now()`

Демо-упрощение (hooks present, logic disabled):
- windowed расписания выключены
- `not_before` может выставляться allocator’ом для `rate_rps`
- `scheduled_for` не используется

Позже (для `windowed`):
- ingest или dispatcher сдвигает `not_before` на ближайшее окно в `posting_window`
- Никаких `Wait` узлов в workflow

---

## Templates / rendering (фиксированная точка истины)
Где рендерится:
- baseline (demo/prod-path): один раз при enqueue
- future option: render после claim перед send (не для текущего demo-контракта)

Что хранится:
- результат рендера сохраняется в `deliveries.rendered_text` + `deliveries.render_meta`
- `template_version` фиксирует, чем именно рендерили

Правило ретраев:
- retry использует **те же** `rendered_text` + `render_meta`, не пересчитывает
- иначе “один и тот же delivery” может отправиться разным текстом

Опционально (если нужен “enterprise”):
- `templates(template_id, version, body, defaults, created_at)`
- `channels.template_ref`

---

## Ingest requirements (push + pull)

### Ingress flood control (required before normalize/enqueue)
- Resolve endpoint by (`kind`, `secret_hash`), require `workspace_endpoints.enabled=true`, and use resolved `endpoint_id`
- Enforce payload size gate per endpoint: if request size exceeds `max_payload_bytes`, reject/drop and emit `events.action='ingress_payload_rejected'` (`attempt=0`)
- Enforce per-endpoint rate gate: if incoming RPS exceeds `ingress_rps`, reject/drop and emit `events.action='ingress_rate_limited'` (`attempt=0`)
- Inbound dedup gate:
  - if source provides `source_ref`: write `ingress_receipts` with key (`workspace_id`, `endpoint_id`, `source_ref`) using `ON CONFLICT DO NOTHING`; on conflict drop request and emit `events.action='ingress_dedup_dropped'`
  - if no `source_ref`: compute `payload_hash`; if same hash seen in last `hash_drop_window_sec` for same (`workspace_id`, `endpoint_id`), drop request and emit `events.action='ingress_dedup_dropped'`
- Dropped ingress requests must not create `messages`/`deliveries`
- Count drops/accepts in `ingest_runs.stats_json` (`rate_limited`, `payload_rejected`, `dedup_dropped`, `accepted`)

### Preflight validation (required before enqueue)
- Run preflight validation in ingest path (or inside `enqueue_messages_and_deliveries`) before creating sendable `deliveries`
- Telegram preflight baseline:
  - text length <= 4096
  - caption length <= 1024
  - validate parse mode / entities (invalid HTML/Markdown/entities -> fail)
  - for `media[]`: validate media-group constraints (allowed item count/types/caption rules) and preserve declared order
  - if `media[].length > 1` and candidate caption may exceed 1024: apply deterministic fallback (`sendText` first, then `sendMediaGroup` without caption/with fixed short caption policy)
  - reject unsupported payload combinations for selected send method
  - preflight is best-effort: Telegram final length check is effectively after entities parsing; final truth is API response (`400 message is too long`)
- MAX preflight baseline:
  - text length <= 4000
  - validate allowed media/content types
  - validate MAX attachment schema (`attachments` token/payload from upload flow)
  - enforce attachment type mapping (`image|video|file`; for images use `type=image`, not `photo`)
  - enforce upload strategy policy by media type (`upload_required|url_allowed`) from central config
  - if `meta.parse_mode != None`: require derived `format` (`html|markdown`) and validate format/entity compatibility
  - validate media size limits (from adapter/profile config)
  - for `media[]`: validate whether native grouped send is supported; if not, validate deterministic degrade-to-series path
  - validate message payload shape required by MAX API
- If preflight fails:
  - set `deliveries.status='failed_permanent'`, `scope=delivery`, `code='validation_failed'`
  - emit `events.action='validation_failed'`
  - do **not** schedule retries for this delivery

### Push mode (webhook)
- Endpoint принимает raw payload (text/link/media) + optional routing hints
- `workspace_id` is derived only from resolved `workspace_endpoints` row (`kind=webhook_push`, `secret_hash` -> `workspace_id`, `endpoint_id`); inbound `workspace_id` is ignored (hint-only)
- Normalizes into internal payload format
- Computes `hash_version` + `content_hash`
- Computes deterministic `message.tags` from normalized payload
- Writes **one** row in `messages`
- Inserts `deliveries` in a **set-based SQL** query:
  - only channels in same `workspace_id` matching routing rules
  - skip channels with recent `sent` in channel TTL window (based on `sent_at` + `coalesce(ch.dedup_ttl_hours, 168)`)
  - skip channels with inflight duplicate (`status in ('queued','claimed','sending','retry')`) for same (`workspace_id`, `channel_id`, `hash_version`, `content_hash`)
  - sets `not_before = now()` (demo); allocator может сдвинуть для `rate_rps`
  - renders payload and stores in `deliveries.rendered_text` + `deliveries.render_meta`
  - stores media into object storage and writes `media_origin` (when media exists)

### Pull mode (cron)
- On schedule, fetches new items from enabled `pull_sources` (DB/RSS/etc.)
- Pull execution is allowed only for enabled `pull_sources` rows (workspace-scoped)
- Uses and updates `pull_cursors` (`last_seen_ts`, `last_seen_id`, `etag`, etc.) per source
- Each run writes `ingest_runs(workspace_id, run_id, kind='pull', started_at, finished_at, stats_json)` for observability
- Same normalize → `hash_version` + hash → write `messages` → insert `deliveries`

Normalization requirements:
- Trim + collapse spaces
- Canonicalize URL when possible
- Media fingerprint strategy: prefer stable IDs/URLs if file hash not available
- Ensure deterministic JSON (sorted keys) before hashing (conceptually)
- For multi-media payloads, preserve and hash `media[]` order exactly (order-sensitive hash input)
- `hash_version` must be bumped when normalization/hash strategy changes
- Нормализация должна быть **одинаковой для всех источников**, иначе дедуп бессмысленен
- If media present: write `media_origin` + set `payload.media[*].blob_ref`; provider-specific `media_blobs` created lazily by adapters

---

## Transactional SQL boundary (required for n8n)
- All delivery guarantees must live in Postgres functions, not in n8n node chains
- Guarantees that must be enforced in DB layer:
  - dedup TTL + inflight guard
  - claim/slotting/rate gates (`next_allowed_at`, platform ceiling)
  - `max_parallel` gate and status transitions
  - attempt accounting, retry scheduling, terminal transitions
- n8n role is orchestration only: call DB function -> call adapter -> call DB function
- Required minimum functions:
  - `enqueue_messages_and_deliveries(workspace_id, endpoint_id, kind, raw_payload_json, now_ts)` — includes normalization, preflight, dedup/inflight suppression, enqueue writes, immediate `failed_permanent` on validation errors
  - `claim_deliveries(workspace_id, run_id, limit)` — performs locks, slotting, and atomic updates of `channels.next_allowed_at` / `platform_limits.next_allowed_at` per `rate_group`
  - `mark_sent(workspace_id, delivery_id, provider_message_id, sent_at, raw_meta_json)`
  - `schedule_retry(workspace_id, delivery_id, next_retry_at, error_json)`
  - `fail_permanent(workspace_id, delivery_id, error_json)`
- Deadlock-avoidance contract for `claim_deliveries`:
  - lock `platform_limits` in deterministic order by (`platform`, `rate_group`)
  - lock `channels` in deterministic order by `channel_id`
  - only then claim/update `deliveries` (`FOR UPDATE SKIP LOCKED`)

---

## Dispatcher requirements

### Workspace scheduler (required)
- Dispatcher runs in global mode (across all tenants) and selects active workspaces (`workspaces.status='active'`)
- Baseline strategy (fixed): variant A — iterate workspaces and call `claim_deliveries(workspace_id, run_id, limit)` per workspace
- Fairness is best-effort (no strict global FIFO across workspaces)
- Empty workspace claim is allowed (returns 0 rows); dispatcher continues to next workspace
- Scale option (many workspaces): keep persistent round-robin cursor `dispatch_cursor(workspace_id_last)` (e.g., in `dispatcher_state`) and start next run from the following workspace to avoid starvation

### Core loop (2-phase)

Phase 1: Allocate
- All selects/locks/updates are scoped by `workspace_id`
- Select candidates where:
  - `status=queued` OR (`status=retry` AND `next_retry_at <= now()`)
  - channel `enabled=true`, `coalesce(paused_until, '-infinity') <= now()`
  - `not_before <= now()`
- Group by `channel_id`, pick up to `K` deliveries per channel (order by `created_at` ASC)
- **Concurrency safety:** use `FOR UPDATE SKIP LOCKED`
- Реализация Allocate допускает 2-шаговый подход: (1) lock кандидатов `FOR UPDATE SKIP LOCKED` в CTE, (2) внутри locked-набора — window/rank и выбор top-`K` per channel
- **Demo/prod required path:** при апдейте `channels.next_allowed_at` брать lock на строки `channels` (`FOR UPDATE`) или advisory lock per (`workspace_id`, `channel_id`); расчёт `base/step` и update `next_allowed_at` делать атомарно в одной транзакции
- Assign slots (if `rate_rps > 0`):
  - `base = greatest(now(), coalesce(ch.next_allowed_at, now()))`
  - `step = 1 / rate_rps`
  - `not_before = base + (i-1)*step`
  - `channels.next_allowed_at = base + N*step` (N = фактически выделенные deliveries)
- If `rate_rps` is null/0:
  - do **not** slot; do **not** touch `next_allowed_at`
- Set:
  - `status='claimed'`
  - `claimed_at=now()`, `claim_token=<run_id>`

Phase 2: Send
- Select `claimed` where:
  - `not_before <= now()`
  - `sending_count(channel_id) < channels.max_parallel`
- **Concurrency safety:** use `FOR UPDATE SKIP LOCKED`
- Atomically set `status='sending'`, `attempt = attempt + 1`, `sending_started_at = now()`
- **Demo/prod required path for parallel gate:** проверка `max_parallel` и переход `claimed -> sending` должны быть атомарными под channel-level lock/guard
- For each item:
  - load channel + message payload
  - use stored `deliveries.rendered_text` + `deliveries.render_meta` for send (no re-render)
  - write pre-call `events` with action `send_attempt` (attempt metadata)
  - call adapter method by payload type (for media use ordered `media[]`; TG may send media group, MAX may degrade to ordered series) and pass `idempotency_key = delivery_id` if supported
  - for MAX degraded series: after each acknowledged item, atomically persist progress in `deliveries.render_meta.series_progress`; on failure set `retry` and keep progress
  - immediately persist adapter outcome (`provider_message_id`, `sent_at`, normalized error) and write result-event (`sent|retry_scheduled|failed_permanent`)

### Rate limiting
- **Per-channel** `rate_rps` and `max_parallel`
- `rate_rps` rules:
  - if `rate_rps` is null or `0` → **no rate limit**; allocator **does not slot** and **does not touch** `next_allowed_at`
  - otherwise allocator assigns slots exactly as described in **Phase 1: Allocate** (`channels.next_allowed_at = base + N*step`, where `N` = фактически выделенные deliveries)
- `max_parallel` enforced **in SQL** in Send phase:
  - MVP: `sending_count` subquery acceptable
  - Demo/default path (required): lock строки `channels` (`FOR UPDATE`) или advisory lock per (`workspace_id`, `channel_id`) при `claimed -> sending`; проверка `sending_count < max_parallel` под этим lock’ом и атомарный переход
  - Scale option (1k+ каналов): replace `sending_count` subquery with `channel_counters` (atomic increment/decrement in the same transaction as status transitions)
- Platform ceiling hook (required schema): `platform_limits(workspace_id, platform, rate_group, rate_rps, next_allowed_at)`
- Platform ceiling works per `rate_group` (from `channels.rate_group`)
- If `platform_limits.rate_rps > 0`, allocator также назначает group-slot и атомарно обновляет `platform_limits.next_allowed_at` (та же lock/update семантика, что и для channel-level gate)
- Merge rule (required): сначала считаем `not_before` от channel slots, затем `not_before = greatest(not_before, platform_slot)`; `platform_limits.next_allowed_at = platform_base + M*platform_step`, где `M` = фактически выделенные deliveries в данном (`workspace_id`, `platform`, `rate_group`)
- Platform ceiling may reorder deliveries across channels; fairness is best-effort

### Error classification defaults (required)
- All adapters (`telegram`, `max`) use the same baseline classifier
- `429`, `5xx`, timeout/network errors → `TRANSIENT`, typically `scope=platform` (or `channel` if provider explicitly scopes limit)
- MAX `attachment.not.ready` (per upload/messages flow) → `TRANSIENT`, `scope=delivery`
- Telegram `400 message is too long` / `message_too_long` → `PERMANENT`, `scope=delivery`
- `400` (payload/validation/format errors, e.g. text too long/invalid markup) → `PERMANENT`, `scope=delivery`
- `401`, `403` (auth/channel access errors) → `PERMANENT`, `scope=channel`
- `404` (chat/channel not found; demo baseline) → `PERMANENT`, `scope=channel`
- provider materialization expired (`media_expired`) → attempt rematerialization first (delivery flow)
- `media_missing_origin` → `PERMANENT`, `scope=delivery`
- preflight payload validation fail (`validation_failed`) → `PERMANENT`, `scope=delivery` (no retry)

### Retry policy
- Applies only for `TRANSIENT`
- `validation_failed` never retries (immediate `failed_permanent`, `scope=delivery`)
- Backoff with jitter:
  - base: 2s, factor: 2, max: 5–10 min (config)
- For MAX `attachment.not.ready`: use short retry window (e.g., 1–5s + jitter) before normal exponential backoff
- For MAX degraded series with partial success: retry only unsent items using `render_meta.series_progress` (do not resend already acknowledged items)
- If provider gives `retry_after_ms` → respect it (plus jitter)
- Max attempts: 5 (config)
- `attempt=0` at enqueue
- `max attempts = 5` means maximum 5 transitions `claimed -> sending` per delivery
- After max attempts → set status `dead`, emit event `dead_letter`, raise alert

### Permanent failures
- **Policy (fixed for demo/prod baseline): Variant A**
- Any `PERMANENT` → `deliveries.status='failed_permanent'`
- If `scope=delivery`:
  - mark only this delivery as `failed_permanent`
  - do **not** increment `channels.error_streak`
  - do **not** pause/disable channel
- If `scope=channel`:
  - `channels.error_streak = channels.error_streak + 1`
  - set `channels.paused_until = now() + pause_on_permanent_for` (default 1h; configurable, e.g. 1–6h)
  - emit event `channel_paused`
  - if `error_streak >= disable_after_permanent_streak` (`Y`, default 3): set `channels.enabled=false` + event `channel_disabled`
- If `scope=platform`:
  - do **not** increment `channels.error_streak`
  - apply group-level cooldown via `platform_limits.next_allowed_at` for (`workspace_id`, `platform`, `rate_group`) (no channel disable)

### `error_streak` policy (required)
- On successful send (`sent`) → `channels.error_streak = 0`
- On `TRANSIENT` (`retry` path) → `error_streak` не изменяется
- On `PERMANENT` with `scope=delivery` → `error_streak` не изменяется
- On `PERMANENT` with `scope=channel` → `error_streak++`
- On `PERMANENT` with `scope=platform` → `error_streak` не изменяется (используется platform-level gate/cooldown)
- Threshold action: if `error_streak >= Y` → auto-disable channel (`enabled=false`) + event `channel_disabled`

### Status semantics / alerting
- **Alert**: status `dead` (event `dead_letter`) always; `failed_permanent` above threshold/window
- **Manual requeue allowed**: `failed_permanent` и `dead` (with explicit operator action + event)

---

## Delivery state machine (allowed transitions)
- `queued/retry -> claimed -> sending -> sent`
- `claimed -> queued` (lease expired / requeue)
- `claimed -> retry` (optional)
- `sending -> retry` (TRANSIENT)
- For MAX degraded series: `sent` only after all series items are acknowledged; partial success + error stays on `retry` with preserved `render_meta.series_progress`
- `queued/retry -> failed_permanent` (preflight `validation_failed`, scope=delivery, no retry)
- `sending -> failed_permanent` (PERMANENT; channel penalties apply only when `scope=channel`)
- `queued/retry -> deduped` (enqueue-time suppression)
- `* -> dead` (max attempts reached; emit `dead_letter`)

Любые другие переходы считаются некорректными и блокируются.

---

## Monitor requirements (anti-“лабораторка”)

### Responsibilities
- Alert if:
  - `dead` items > 0
  - `failed_permanent` in last 10 min > X
  - `channels.paused_until` active count > Y
- Retry scheduler:
  - optional: “kick” retries if n8n timing jitter occurs
- Stuck sending guard:
  - constant: `sending_lease_seconds` (demo default: 300s)
  - if `status='sending'` AND `sending_started_at < now()-sending_lease_seconds`:
    - set `status='retry'`
    - set `next_retry_at = now() + short_backoff` (e.g., 10–30s)
    - **attempt is NOT incremented** (фиксируем правило)
    - clear `claimed_at` / `claim_token`
    - clear `sending_started_at`
    - emit event `sending_lease_expired`
- Stuck claimed guard:
  - constant: `claimed_lease_seconds` (demo default: 300s)
  - if `status='claimed'` AND `not_before <= now()` AND `claimed_at < now()-claimed_lease_seconds`:
    - set `status='queued'` (or `retry`)
    - clear `claimed_at` / `claim_token`
    - **attempt is NOT incremented**
    - emit event `claimed_lease_expired`
- Health snapshot:
  - counts by status + top errors

Alert target:
- Telegram admin chat (or email) — configurable

---

## Prod checklist (required)
- `events` must store only snippet in `error`; full raw is externalized and referenced via `payload_ref`
- Retention job is mandatory:
  - `events` retention: 30 days (archive/purge or partition)
  - `deliveries` retention: 90 days (archive/purge or partition)
  - `ingress_receipts` retention: 1–3 days (TTL cleanup by `expires_at`)
- Object-storage GC job is mandatory:
  - refresh/reconcile `media_origin.ref_count` (or compute live refs directly from `messages.payload.media[*].blob_ref`)
  - delete origin files only when unreferenced (`ref_count=0`) and older than retention (`last_seen_at` window)
  - apply separate shorter retention policy for large videos

---

## Data privacy / PII (required baseline)
- `events.error` stores only normalized error + short snippet; no full payload dumps, tokens, or raw credentials
- Full raw payloads/logs are externalized via `payload_ref` in object storage; storage must be encrypted at rest and accessed via short-lived signed URLs or equivalent
- Access control: `events` snippet is ops-visible; `payload_ref` content is restricted to privileged roles (on-call/security) with workspace scoping
- Redaction: before writing `events.error`/`events.meta`, mask obvious PII/secrets (phone, email, access tokens, auth headers)
- Audit: access to external raw payload by `payload_ref` should be logged (who/when/workspace/reason)
- Retention: `payload_ref` raw data retention must be explicitly configured and usually shorter than `deliveries` retention

---

## Ops runbook (manual operations)
Prerequisite (required):
```sql
create extension if not exists pgcrypto;
```

Rules:
- Always filter by `workspace_id`; run updates in transaction
- Manual requeue does **not** increment `attempt` (it increments only on `claimed -> sending`)
- For manual events with `delivery_id`, write `attempt = current deliveries.attempt`; for channel/group/auth operations without delivery context write `attempt=0`

### 1) Queue snapshot by status
```sql
select workspace_id, status, count(*) as cnt
from deliveries
where workspace_id = :workspace_id
group by workspace_id, status
order by status;
```

### 2) Recent error stream (what broke)
```sql
select ts, action, result, channel_id, delivery_id, attempt, error, meta
from events
where workspace_id = :workspace_id
  and ts >= now() - interval '30 minutes'
  and result = 'error'
order by ts desc
limit 200;
```

### 3) Safe requeue for `dead`
```sql
with moved as (
  update deliveries d
  set status = 'retry',
      next_retry_at = now(),
      claimed_at = null,
      claim_token = null,
      sending_started_at = null,
      updated_at = now()
  where d.workspace_id = :workspace_id
    and d.status = 'dead'
    and d.delivery_id = any(:delivery_ids)
  returning d.workspace_id, d.delivery_id, d.message_id, d.channel_id, d.attempt
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), m.workspace_id, m.delivery_id, m.message_id, m.channel_id, now(),
       'manual_requeue', m.attempt, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'from_status', 'dead')
from moved m;
```

### 4) Requeue `failed_permanent` (only delivery-scope cases)
```sql
with moved as (
  update deliveries d
  set status = 'retry',
      next_retry_at = now(),
      claimed_at = null,
      claim_token = null,
      sending_started_at = null,
      updated_at = now()
  where d.workspace_id = :workspace_id
    and d.status = 'failed_permanent'
    and coalesce(d.last_error->>'scope', 'delivery') = 'delivery'
    and d.delivery_id = any(:delivery_ids)
  returning d.workspace_id, d.delivery_id, d.message_id, d.channel_id, d.attempt
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), m.workspace_id, m.delivery_id, m.message_id, m.channel_id, now(),
       'manual_requeue', m.attempt, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'from_status', 'failed_permanent')
from moved m;
```

### 5) Pause one channel (quarantine)
```sql
with ch as (
  update channels c
  set paused_until = now() + make_interval(secs => :pause_seconds),
      updated_at = now()
  where c.workspace_id = :workspace_id
    and c.channel_id = :channel_id
  returning c.workspace_id, c.channel_id
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), ch.workspace_id, null, null, ch.channel_id, now(),
       'channel_paused', 0, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'manual', true)
from ch;
```

### 6) Enable/resume one channel
```sql
with ch as (
  update channels c
  set enabled = true,
      paused_until = null,
      error_streak = 0,
      updated_at = now()
  where c.workspace_id = :workspace_id
    and c.channel_id = :channel_id
  returning c.workspace_id, c.channel_id
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), ch.workspace_id, null, null, ch.channel_id, now(),
       'channel_enabled', 0, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'manual', true)
from ch;
```

### 7) Disable channel group (`rate_group`)
```sql
with ch as (
  update channels c
  set enabled = false,
      updated_at = now()
  where c.workspace_id = :workspace_id
    and c.rate_group = :rate_group
  returning c.workspace_id, c.channel_id
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), ch.workspace_id, null, null, ch.channel_id, now(),
       'channel_disabled', 0, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'rate_group', :rate_group, 'manual', true)
from ch;
```

### 8) Enable channel group (`rate_group`)
```sql
with ch as (
  update channels c
  set enabled = true,
      paused_until = null,
      error_streak = 0,
      updated_at = now()
  where c.workspace_id = :workspace_id
    and c.rate_group = :rate_group
  returning c.workspace_id, c.channel_id
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), ch.workspace_id, null, null, ch.channel_id, now(),
       'channel_enabled', 0, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', :reason, 'rate_group', :rate_group, 'manual', true)
from ch;
```

### 9) Rotate `auth_ref` safely
```sql
begin;

-- Optional short pause to drain in-flight sends
update channels
set paused_until = now() + interval '2 minutes',
    updated_at = now()
where workspace_id = :workspace_id
  and channel_id = :channel_id;

-- Guard: no active sending before switch
select count(*) as sending_now
from deliveries
where workspace_id = :workspace_id
  and channel_id = :channel_id
  and status = 'sending';

insert into channel_auth (workspace_id, channel_id, auth_ref, rotated_at, updated_at)
values (:workspace_id, :channel_id, :new_auth_ref, now(), now())
on conflict (workspace_id, channel_id)
do update set auth_ref = excluded.auth_ref, rotated_at = excluded.rotated_at, updated_at = excluded.updated_at;

update channels
set auth_ref = :new_auth_ref,
    rate_group = coalesce(:new_rate_group, rate_group),
    updated_at = now()
where workspace_id = :workspace_id
  and channel_id = :channel_id;

insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
values (
  gen_random_uuid(), :workspace_id, null, null, :channel_id, now(),
  'auth_rotated', 0, 'ok', null, null,
  jsonb_build_object('operator', :operator, 'old_auth_ref', :old_auth_ref, 'new_auth_ref', :new_auth_ref)
);

commit;
```

### 10) Emergency release of stale `claimed/sending`
```sql
with moved as (
  update deliveries d
  set status = 'retry',
      next_retry_at = now() + interval '15 seconds',
      claimed_at = null,
      claim_token = null,
      sending_started_at = null,
      updated_at = now()
  where d.workspace_id = :workspace_id
    and d.status in ('claimed', 'sending')
    and coalesce(d.sending_started_at, d.claimed_at) < now() - interval '10 minutes'
  returning d.workspace_id, d.delivery_id, d.message_id, d.channel_id, d.attempt
)
insert into events (id, workspace_id, delivery_id, message_id, channel_id, ts, action, attempt, result, error, payload_ref, meta)
select gen_random_uuid(), m.workspace_id, m.delivery_id, m.message_id, m.channel_id, now(),
       'manual_requeue', m.attempt, 'ok', null, null,
       jsonb_build_object('operator', :operator, 'reason', 'manual_stuck_release')
from moved m;
```

Events to watch after manual actions:
- `manual_requeue`, `retry_scheduled`, `sent`, `dead_letter`
- `channel_paused`, `channel_disabled`, `channel_enabled`
- `auth_rotated`
- `sending_lease_expired`, `claimed_lease_expired`
- `ingress_rate_limited`, `ingress_payload_rejected`, `ingress_dedup_dropped`

---

## Demo criteria (must pass)

1) **Config-driven channel**
- Add row to `channels` → new channel receives next post **without workflow change**

2) **429 simulation**
- Simulate 429 → shows:
  - `events`: send_attempt error, retry_scheduled
  - `deliveries`: attempt++, `next_retry_at` increased
  - eventual success

3) **Per-channel dedup**
- Same post → 2 channels: sent both
- Same post повтор → same channel: suppressed (event `dedup_suppressed`, optional `deduped`)

4) **Bad-channel isolation**
- Simulate 403/404 for one channel:
  - delivery → `failed_permanent`
  - channel immediately paused (`channel_paused`), and after `Y` consecutive `PERMANENT` auto-disabled (`channel_disabled`)
  - other channels continue to send

---

# Bot Reference (B) — MAX shop chat bot

## Scope
- 5 FAQ scenarios:
  - delivery / payment / returns / warranty / contacts
- Rules/templates stored in DB
- Minimal state machine stored in DB
- Full logging: `matched_rule_id`, `rule_version`, state transitions

---

## Bot Architecture

### Workflows
1) `11_bot_ingest` — MAX webhook (`workspace_endpoints.kind=bot_webhook`) → normalize message → inbound dedup gate (`bot_inbox`) → route to engine
2) `12_bot_engine` — load state + match rule → respond → persist state + log
3) `13_bot_monitor` — alerts + error rate

### Tables (reuse or extend)
- `bot_inbox`
- `bot_outbox`
- `bot_rules`
- `bot_state`
- `bot_logs`

---

## Bot data requirements

### bot_inbox
- `workspace_id` (uuid/text)
- `provider` (string, e.g. `max`)
- `chat_id`
- `provider_message_id` (string)
- `ts` (timestamp)

Constraints:
- unique (`workspace_id`, `provider`, `chat_id`, `provider_message_id`)

### bot_outbox
- `workspace_id` (uuid/text)
- `chat_id`
- `inbound_provider_message_id` (string)
- `response_hash` (string)
- `sent_at` (timestamp, nullable)
- `provider_message_id` (string, nullable)

Constraints:
- unique (`workspace_id`, `chat_id`, `inbound_provider_message_id`)

### bot_rules
- `workspace_id` (uuid/text)
- `rule_id` (string)
- `version` (int)
- `enabled` (bool)
- `intent` (string)
- `pattern` (jsonb: `{ \"keywords\": [\"...\"], \"mode\": \"contains\" }`) — fixed demo matcher format
- `priority` (int)
- `max_turns` (int, default 5) — safety guard for multi-turn flows
- `response_template` (text)
- `next_state` (string, nullable)
- `created_at`

Constraints:
- primary key (`workspace_id`, `rule_id`, `version`)
- partial unique (`workspace_id`, `rule_id`) where `enabled=true` — only one active version per rule inside workspace

### bot_state
- `workspace_id` (uuid/text)
- `chat_id`
- `state` (string)
- `context` (jsonb, includes `turns` counter)
- `expires_at` (timestamp, nullable)
- `updated_at`

Constraints:
- primary key (`workspace_id`, `chat_id`)

### bot_logs
- `workspace_id` (uuid/text)
- `id` (pk)
- `ts`
- `chat_id`
- `message_text`
- `matched_rule_id` (nullable)
- `rule_version` (nullable, but required when `matched_rule_id` is set)
- `state_before`
- `state_after`
- `response_preview`
- `meta` (jsonb: `trace_id`, `idempotency_key`, adapter info)

Constraints:
- check `((matched_rule_id is null and rule_version is null) or (matched_rule_id is not null and rule_version is not null))`

---

## Bot behavior requirements
- Bot responses are sent via the same MAX adapter contract (`sendText` / `sendMedia`); no separate outbound path
- For outbound bot messages, `bot_logs.meta` includes `trace_id` and `idempotency_key`
- Inbound dedup (required): before engine execution, insert into `bot_inbox(workspace_id, provider, chat_id, provider_message_id, ts)`; continue only if insert succeeded
- If insert conflicts on unique key, skip engine/outbound response (webhook duplicate)
- Outbox dedup (required): before sending bot response, `INSERT INTO bot_outbox(workspace_id, chat_id, inbound_provider_message_id, response_hash, sent_at, provider_message_id) ON CONFLICT DO NOTHING`
- If outbox insert conflicts, skip outbound response (already answered for this inbound message)
- Rule matching mode (demo fixed): case-insensitive `contains` over `pattern.keywords` (no regex mode in demo)
- State timeout rule: if `bot_state.expires_at < now()`, reset state/context to default before matching
- Turn guard: increment `context.turns` per inbound message; if `turns >= max_turns` then force fallback/escalation (operator/contacts) and reset state
- If matched rule found:
  - render template (with context vars if needed)
  - update state if `next_state` defined
- If no match:
  - fallback: уточнение / эскалация (config)
- One multi-step scenario required (example: returns):
  - ask order number → ask reason → return instructions
- Production mode: MAX webhook (not long polling)

---

## Delivery artifacts (required)
- `docs/architecture.png` — short scheme
- `workflows/*.json` — exports:
  - ingest, dispatcher, monitor
  - bot ingest, bot engine, bot monitor
- `db/schema.sql` + `db/seed.sql`
- `README.md` — 1 page:
  - What it solves
  - Guarantees
  - 5-minute run
  - Demo script
  - Adapter contract
  - How to add a new platform/channel
