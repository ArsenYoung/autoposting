# agents.md — Autopost (n8n + Postgres) for Codex

This repository implements **production-minded reference** workflows for:
1) **Autoposting** to **Telegram + MAX** across ~40 channels
2) **MAX shop chat bot** (FAQ + deterministic сценарии, “без магии”)

Source-of-truth docs: architecture + workflow contracts. :contentReference[oaicite:0]{index=0} :contentReference[oaicite:1]{index=1}

---

## 0) What you are (and are not) allowed to do

### Non-goals (do not expand scope)
- **No LLM**. Only rule engine + state machine.
- **No admin UI**. Config is via DB tables + seed examples.
- **No “framework” refactor**. Keep it minimal, reproducible, demo-ready.
- Delivery semantics: **at-least-once** with **idempotency best-effort** + **per-channel dedup**.

### Hard boundaries (must not violate)
- **No n8n loops over channels** to enqueue deliveries. Enqueue is set-based SQL only.
- **No `Wait` nodes** for scheduling/retries.
- **All queue invariants live in Postgres** (dedup, inflight guard, slotting, leases, max_parallel, transitions).
- n8n role: **orchestration only** (trigger → call DB → call adapter → commit).

---

## 1) System guarantees (must remain true)

- **Config-driven**: add/disable channel via `channels` row; workflows unchanged.
- **Scales to N channels**: `messages` stores payload once; `deliveries` stores per-channel state.
- **Per-channel dedup**: same message can go to 40 channels, but repeat to the same channel within TTL is blocked.
- **Rate limits + retries**: 429/5xx/timeouts → backoff + retry, recorded in `events`.
- **Bad-channel isolation**: one broken channel never blocks the rest.
- **Observability**: `events` audit log + monitor alerts, DLQ (`dead`) and `failed_permanent`.

---

## 2) Key data model (do not “simplify” away)

### Core tables
- `workspaces`, `workspace_endpoints`
- `channels`, `platform_limits`
- `messages`, `media_origin`, `media_blobs`
- `deliveries`, `events`
- `pull_sources`, `pull_cursors`, `ingest_runs`, `ingress_receipts`

### Bot tables
- `bot_inbox`, `bot_outbox`, `bot_rules`, `bot_state`, `bot_logs`

### Workspace scoping is mandatory
Every core row is workspace-scoped and every query must filter by `workspace_id`.

---

## 3) State machines & invariants

### Delivery statuses (allowed transitions only)
- `queued|retry -> claimed -> sending -> sent`
- `sending -> retry` (TRANSIENT)
- `sending -> failed_permanent` (PERMANENT)
- `* -> dead` (max attempts)
- Optional enqueue-time: `queued|retry -> deduped` (audit)

Any other transition is a bug.

### Attempt semantics (do not break)
- `attempt` increments **only** on `claimed -> sending` inside `claim_deliveries`.
- `schedule_retry` / monitor recovery **must not** increment attempt.

### Leases
- Dispatcher must lease `sending` before external call.
- Monitor recovers stale `sending/claimed` by lease timeouts (no double-commit).

---

## 4) Adapter contract (central artifact)

Implement adapters to **return normalized outcomes**:
- Success: `{ ok: true, provider_message_id, raw }`
- Error: `{ ok: false, error: { category, scope, code, retry_after_ms?, message, raw } }`

Where:
- `category`: `TRANSIENT | PERMANENT`
- `scope`: `delivery | channel | platform`

Notes:
- **MAX** requires upload flow (create upload session → upload binary → send message with attachment token).
- Media series degradation (if MAX doesn’t support grouped media) must persist progress and retry tail-only.

---

## 5) DB function boundaries (preferred design)

Critical operations must be Postgres functions (single source of truth):
- `enqueue_messages_and_deliveries(...)` (+ batch variants for pull)
- `claim_deliveries(workspace_id, run_id, limit)`
- `mark_sent(workspace_id, delivery_id, provider_message_id, sent_at, raw_meta)`
- `schedule_retry(workspace_id, delivery_id, next_retry_at, error_json)`
- `fail_permanent(workspace_id, delivery_id, error_json)`
- (optional) `recover_*_leases(...)`

Rules:
- Commit functions must verify `status='sending'` and matching `claim_token`.
- Lock ordering in `claim_deliveries` must be deterministic to avoid deadlocks.

---

## 6) n8n workflows (must match contracts)

### Autoposting
- `01_ingest`: push+pull → ingress guard → normalize → media origin → **one DB enqueue boundary** → finalize `ingest_runs`
- `02_dispatcher`: advisory-lock guard → workspace round-robin → `claim_deliveries` → adapter send → commit
- `03_monitor`: lease recovery + alerts + snapshot

### Bot
- `11_bot_ingest`: endpoint resolve → inbound dedup (`bot_inbox`) → call engine
- `12_bot_engine`: load state → match rule → outbox idempotency → send via same MAX adapter → persist logs/state
- `13_bot_monitor`: alerts + fallback rate

---

## 7) Error classification defaults (do not improvise silently)

- `429`, `5xx`, network/timeouts → `TRANSIENT` (`scope=platform` usually)
- MAX `attachment.not.ready` → `TRANSIENT`, `scope=delivery`
- Validation / format / too-long → `PERMANENT`, `scope=delivery`
- Auth/access/chat-not-found → `PERMANENT`, `scope=channel`

Permanent failure policy:
- `scope=delivery`: fail only this delivery (no channel penalty)
- `scope=channel`: increment `channels.error_streak`, pause channel, auto-disable after threshold
- `scope=platform`: apply group cooldown via `platform_limits` (no channel disable)

---

## 8) Retry policy (centralized)
- Applies only to `TRANSIENT`.
- Backoff: base 2s, factor 2, cap 10m, jitter ±20%.
- Respect `retry_after_ms` when present.
- Max attempts (default): 5 → then `dead` + `dead_letter` event.

---

## 9) Dedup rules (must remain correct)

Dedup key (logical):
`workspace_id + channel_id + hash_version + content_hash`

Enqueue must **skip creating delivery** when:
- A `sent` exists within TTL (`dedup_ttl_hours`, default 168)
- An inflight delivery exists (`queued|claimed|sending|retry`) for same key

Important:
- `deduped` entries must not extend TTL (TTL is anchored to `sent_at`).

---

## 10) Media storage rules

- Payload stores logical `blob_ref`.
- `media_origin` stores stable object storage URL.
- `media_blobs` stores provider materialization (TG file_id / MAX token) with expiry handling.
- GC policy exists (don’t remove “for simplicity”).

---

## 11) Coding style and PR rules for Codex

### Always do
- Keep changes **small and surgical**.
- Add/adjust DB migration + seeds when introducing schema/config changes.
- Preserve deterministic normalization + hashing behavior (bump `hash_version` if needed).
- Add events for important transitions and errors (no silent drops).
- Redact secrets/PII in `events` (store only snippets; raw goes to external storage if implemented).

### Never do
- Don’t add new runtime dependencies unless unavoidable.
- Don’t implement queue logic in n8n node chains.
- Don’t add “smart heuristics” without recording them in docs + tests.

---

## 12) When uncertain: decision checklist (fast)

1) Does this change break any guarantee in sections 1–3? If yes, stop.
2) Can it be done inside Postgres boundary instead of n8n? If yes, do it in SQL.
3) Is behavior deterministic and reproducible? If no, redesign.
4) Are we storing enough info in `events` to debug it? If no, add an event.

---

## 13) Deliverables expected in repo

- `workflows/*.json` (exports)
- `db/schema.sql` + `db/seed.sql`
- `docs/architecture.png`
- `README.md` with 5-minute run + demo script + adapter contract

---
