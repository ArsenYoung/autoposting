-- Align schema with arch.md + workflows.md (production-oriented baseline)
-- Safe/idempotent migration: additive changes, no destructive drops.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Channels: add missing routing/scheduling fields from architecture.
-- ---------------------------------------------------------------------------
ALTER TABLE public.channels
  ADD COLUMN IF NOT EXISTS timezone text,
  ADD COLUMN IF NOT EXISTS route_filter jsonb;

ALTER TABLE public.channels
  ALTER COLUMN route_filter SET DEFAULT '{}'::jsonb;

UPDATE public.channels
SET route_filter = '{}'::jsonb
WHERE route_filter IS NULL;

ALTER TABLE public.channels
  ALTER COLUMN route_filter SET NOT NULL;

-- ---------------------------------------------------------------------------
-- Workspace endpoints: pull source mapping and stronger uniqueness/indexing.
-- ---------------------------------------------------------------------------
ALTER TABLE public.workspace_endpoints
  ADD COLUMN IF NOT EXISTS source_id text;

CREATE INDEX IF NOT EXISTS ix_endpoints_kind_secret_active
  ON public.workspace_endpoints(kind, secret_hash)
  WHERE enabled = true;

-- Global active uniqueness for ingress secret resolution.
CREATE UNIQUE INDEX IF NOT EXISTS ux_endpoints_kind_active_secret
  ON public.workspace_endpoints(kind, secret_hash)
  WHERE enabled = true;

-- For pull endpoints, one active endpoint per source within workspace.
CREATE UNIQUE INDEX IF NOT EXISTS ux_endpoints_pull_source_active
  ON public.workspace_endpoints(workspace_id, source_id)
  WHERE enabled = true AND kind = 'pull_source';

-- ---------------------------------------------------------------------------
-- Messages: align payload/tags/first-seen semantics.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'messages'
      AND column_name = 'source'
      AND data_type <> 'jsonb'
  ) THEN
    ALTER TABLE public.messages
      ALTER COLUMN source TYPE jsonb
      USING CASE
        WHEN source IS NULL THEN '{}'::jsonb
        ELSE jsonb_build_object('value', source)
      END;
  END IF;
END$$;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS normalization_version integer,
  ADD COLUMN IF NOT EXISTS tags text[],
  ADD COLUMN IF NOT EXISTS first_seen_trace_id text,
  ADD COLUMN IF NOT EXISTS first_ingest_run_id text,
  ADD COLUMN IF NOT EXISTS last_ingest_run_id text,
  ADD COLUMN IF NOT EXISTS seen_count bigint;

ALTER TABLE public.messages
  ALTER COLUMN payload SET DEFAULT '{}'::jsonb,
  ALTER COLUMN source SET DEFAULT '{}'::jsonb,
  ALTER COLUMN seen_count SET DEFAULT 1;

UPDATE public.messages
SET source = '{}'::jsonb
WHERE source IS NULL;

UPDATE public.messages
SET seen_count = 1
WHERE seen_count IS NULL;

ALTER TABLE public.messages
  ALTER COLUMN source SET NOT NULL,
  ALTER COLUMN seen_count SET NOT NULL;

CREATE INDEX IF NOT EXISTS ix_messages_tags_gin
  ON public.messages USING gin(tags);

-- ---------------------------------------------------------------------------
-- Deliveries: align attempt/lease/rendering/hash fields and indexes.
-- ---------------------------------------------------------------------------
ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS hash_version integer,
  ADD COLUMN IF NOT EXISTS content_hash text,
  ADD COLUMN IF NOT EXISTS scheduled_for timestamptz,
  ADD COLUMN IF NOT EXISTS attempt integer,
  ADD COLUMN IF NOT EXISTS sending_lease_until timestamptz,
  ADD COLUMN IF NOT EXISTS rendered_text text,
  ADD COLUMN IF NOT EXISTS render_meta jsonb,
  ADD COLUMN IF NOT EXISTS template_version text,
  ADD COLUMN IF NOT EXISTS trace_id text,
  ADD COLUMN IF NOT EXISTS enqueue_batch_id uuid;

-- Backfill from legacy columns when present.
UPDATE public.deliveries
SET attempt = COALESCE(attempt, attempt_count, 0)
WHERE attempt IS NULL;

UPDATE public.deliveries
SET sending_lease_until = COALESCE(sending_lease_until, lease_until)
WHERE sending_lease_until IS NULL;

UPDATE public.deliveries d
SET hash_version = m.hash_version,
    content_hash = m.content_hash
FROM public.messages m
WHERE d.workspace_id = m.workspace_id
  AND d.message_id = m.message_id
  AND (d.hash_version IS NULL OR d.content_hash IS NULL);

UPDATE public.deliveries
SET hash_version = 1
WHERE hash_version IS NULL;

UPDATE public.deliveries
SET not_before = COALESCE(not_before, created_at, now())
WHERE not_before IS NULL;

UPDATE public.deliveries
SET render_meta = '{}'::jsonb
WHERE render_meta IS NULL;

ALTER TABLE public.deliveries
  ALTER COLUMN attempt SET DEFAULT 0,
  ALTER COLUMN hash_version SET DEFAULT 1,
  ALTER COLUMN not_before SET DEFAULT now(),
  ALTER COLUMN render_meta SET DEFAULT '{}'::jsonb;

ALTER TABLE public.deliveries
  ALTER COLUMN attempt SET NOT NULL,
  ALTER COLUMN hash_version SET NOT NULL,
  ALTER COLUMN not_before SET NOT NULL,
  ALTER COLUMN render_meta SET NOT NULL;

CREATE INDEX IF NOT EXISTS ix_deliveries_sent_dedup
  ON public.deliveries(workspace_id, channel_id, hash_version, content_hash, sent_at)
  WHERE status = 'sent'::public.delivery_status AND sent_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_deliveries_inflight_dedup
  ON public.deliveries(workspace_id, channel_id, hash_version, content_hash, created_at)
  WHERE status IN ('queued'::public.delivery_status, 'claimed'::public.delivery_status, 'sending'::public.delivery_status, 'retry'::public.delivery_status);

CREATE INDEX IF NOT EXISTS ix_deliveries_sent_or_deduped_lookup
  ON public.deliveries(workspace_id, channel_id, hash_version, content_hash)
  WHERE status IN ('sent'::public.delivery_status, 'deduped'::public.delivery_status);

CREATE UNIQUE INDEX IF NOT EXISTS ux_deliveries_enqueue_batch_guard
  ON public.deliveries(workspace_id, enqueue_batch_id, channel_id, hash_version, content_hash)
  WHERE enqueue_batch_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- New tables required by architecture/workflows.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.media_origin (
  workspace_id uuid NOT NULL,
  blob_ref text NOT NULL,
  origin_url text NOT NULL,
  sha256 text,
  content_type text,
  size_bytes bigint,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  ref_count bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, blob_ref),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.media_blobs (
  workspace_id uuid NOT NULL,
  blob_ref text NOT NULL,
  provider text NOT NULL,
  file_id text,
  url text,
  expires_at timestamptz,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, blob_ref, provider),
  FOREIGN KEY (workspace_id, blob_ref) REFERENCES public.media_origin(workspace_id, blob_ref) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_media_blobs_provider
  ON public.media_blobs(workspace_id, provider, blob_ref);

CREATE TABLE IF NOT EXISTS public.pull_sources (
  workspace_id uuid NOT NULL,
  source_id text NOT NULL,
  endpoint_id uuid,
  kind text NOT NULL,
  config_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, source_id),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE,
  FOREIGN KEY (workspace_id, endpoint_id) REFERENCES public.workspace_endpoints(workspace_id, endpoint_id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_pull_sources_enabled
  ON public.pull_sources(workspace_id, enabled);

CREATE TABLE IF NOT EXISTS public.pull_cursors (
  workspace_id uuid NOT NULL,
  source_id text NOT NULL,
  cursor_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, source_id),
  FOREIGN KEY (workspace_id, source_id) REFERENCES public.pull_sources(workspace_id, source_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.ingest_runs (
  workspace_id uuid NOT NULL,
  run_id text NOT NULL,
  kind text NOT NULL,
  endpoint_id uuid,
  source_id text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  stats_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (workspace_id, run_id),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_ingest_runs_recent
  ON public.ingest_runs(workspace_id, started_at DESC);

CREATE TABLE IF NOT EXISTS public.ingress_receipts (
  workspace_id uuid NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_kind text NOT NULL,
  source_ref text,
  payload_hash text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, endpoint_id, payload_hash, received_at),
  FOREIGN KEY (workspace_id, endpoint_id) REFERENCES public.workspace_endpoints(workspace_id, endpoint_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_ingress_receipts_source_ref
  ON public.ingress_receipts(workspace_id, endpoint_id, source_ref)
  WHERE source_ref IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_ingress_receipts_payload_window
  ON public.ingress_receipts(workspace_id, endpoint_id, payload_hash, received_at DESC);

CREATE INDEX IF NOT EXISTS ix_ingress_receipts_expires
  ON public.ingress_receipts(expires_at);

CREATE TABLE IF NOT EXISTS public.pull_receipts (
  workspace_id uuid NOT NULL,
  source_id text NOT NULL,
  source_ref text,
  payload_hash text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, source_id, payload_hash, received_at),
  FOREIGN KEY (workspace_id, source_id) REFERENCES public.pull_sources(workspace_id, source_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_pull_receipts_source_ref
  ON public.pull_receipts(workspace_id, source_id, source_ref)
  WHERE source_ref IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_pull_receipts_payload_window
  ON public.pull_receipts(workspace_id, source_id, payload_hash, received_at DESC);

CREATE INDEX IF NOT EXISTS ix_pull_receipts_expires
  ON public.pull_receipts(expires_at);

CREATE TABLE IF NOT EXISTS public.events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  delivery_id uuid,
  message_id uuid,
  channel_id text,
  ts timestamptz NOT NULL DEFAULT now(),
  action text NOT NULL,
  attempt integer NOT NULL DEFAULT 0,
  result public.event_result NOT NULL,
  error jsonb,
  payload_ref text,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_events_ws_ts
  ON public.events(workspace_id, ts DESC);

CREATE INDEX IF NOT EXISTS ix_events_ws_action_ts
  ON public.events(workspace_id, action, ts DESC);

CREATE INDEX IF NOT EXISTS ix_events_ws_result_ts
  ON public.events(workspace_id, result, ts DESC);

CREATE INDEX IF NOT EXISTS ix_events_ws_delivery_ts
  ON public.events(workspace_id, delivery_id, ts DESC)
  WHERE delivery_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_events_ws_message_ts
  ON public.events(workspace_id, message_id, ts DESC)
  WHERE message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_events_ws_channel_ts
  ON public.events(workspace_id, channel_id, ts DESC)
  WHERE channel_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.bot_inbox (
  workspace_id uuid NOT NULL,
  provider text NOT NULL,
  chat_id text NOT NULL,
  provider_message_id text NOT NULL,
  ts timestamptz NOT NULL DEFAULT now(),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (workspace_id, provider, chat_id, provider_message_id),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.bot_outbox (
  workspace_id uuid NOT NULL,
  chat_id text NOT NULL,
  inbound_provider_message_id text NOT NULL,
  response_hash text NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  provider_message_id text,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (workspace_id, chat_id, inbound_provider_message_id),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.bot_rules (
  workspace_id uuid NOT NULL,
  rule_id text NOT NULL,
  version integer NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  priority integer NOT NULL DEFAULT 100,
  match_type text NOT NULL DEFAULT 'keywords',
  pattern text,
  keywords jsonb,
  response_template text NOT NULL,
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, rule_id, version),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_bot_rules_one_enabled
  ON public.bot_rules(workspace_id, rule_id)
  WHERE enabled = true;

CREATE TABLE IF NOT EXISTS public.bot_state (
  workspace_id uuid NOT NULL,
  chat_id text NOT NULL,
  state text NOT NULL DEFAULT 'default',
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  turns integer NOT NULL DEFAULT 0,
  expires_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, chat_id),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.bot_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  chat_id text NOT NULL,
  inbound_provider_message_id text,
  matched_rule_id text,
  matched_rule_version integer,
  action text NOT NULL,
  result public.event_result NOT NULL DEFAULT 'ok',
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_bot_logs_recent
  ON public.bot_logs(workspace_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Generic updated_at trigger reuse for newly added tables.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_channels_updated_at ON public.channels;
CREATE TRIGGER trg_channels_updated_at
BEFORE UPDATE ON public.channels
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_messages_updated_at ON public.messages;
CREATE TRIGGER trg_messages_updated_at
BEFORE UPDATE ON public.messages
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_workspace_endpoints_updated_at ON public.workspace_endpoints;
CREATE TRIGGER trg_workspace_endpoints_updated_at
BEFORE UPDATE ON public.workspace_endpoints
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_pull_sources_updated_at ON public.pull_sources;
CREATE TRIGGER trg_pull_sources_updated_at
BEFORE UPDATE ON public.pull_sources
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_media_blobs_updated_at ON public.media_blobs;
CREATE TRIGGER trg_media_blobs_updated_at
BEFORE UPDATE ON public.media_blobs
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_platform_limits_updated_at ON public.platform_limits;
CREATE TRIGGER trg_platform_limits_updated_at
BEFORE UPDATE ON public.platform_limits
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_bot_rules_updated_at ON public.bot_rules;
CREATE TRIGGER trg_bot_rules_updated_at
BEFORE UPDATE ON public.bot_rules
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_bot_state_updated_at ON public.bot_state;
CREATE TRIGGER trg_bot_state_updated_at
BEFORE UPDATE ON public.bot_state
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- ---------------------------------------------------------------------------
-- Helper functions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._jsonb_text_array(p_json jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(array_agg(value), ARRAY[]::text[])
  FROM jsonb_array_elements_text(COALESCE(p_json, '[]'::jsonb)) AS t(value);
$$;

CREATE OR REPLACE FUNCTION public._route_match(p_tags text[], p_route_filter jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_include text[] := public._jsonb_text_array(COALESCE(p_route_filter->'include', '[]'::jsonb));
  v_exclude text[] := public._jsonb_text_array(COALESCE(p_route_filter->'exclude', '[]'::jsonb));
  v_tags text[] := COALESCE(p_tags, ARRAY[]::text[]);
BEGIN
  IF p_route_filter IS NULL OR p_route_filter = '{}'::jsonb THEN
    RETURN true;
  END IF;

  IF cardinality(v_include) > 0 AND NOT (v_tags && v_include) THEN
    RETURN false;
  END IF;

  IF cardinality(v_exclude) > 0 AND (v_tags && v_exclude) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public._next_retry_at(
  p_attempt integer,
  p_now timestamptz DEFAULT now(),
  p_retry_after_ms integer DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
AS $$
DECLARE
  v_delay_seconds double precision;
  v_jitter_factor double precision;
BEGIN
  IF p_retry_after_ms IS NOT NULL AND p_retry_after_ms > 0 THEN
    v_delay_seconds := p_retry_after_ms::double precision / 1000.0;
  ELSE
    -- base=2s, cap=10m, formula with attempt as send number (attempt=1 -> 2s)
    v_delay_seconds := LEAST(600.0, 2.0 * power(2.0, GREATEST(COALESCE(p_attempt, 1), 1) - 1));
  END IF;

  -- jitter = +/-20%
  v_jitter_factor := 0.8 + random() * 0.4;

  RETURN p_now + make_interval(secs => GREATEST(0.1, v_delay_seconds * v_jitter_factor));
END;
$$;

CREATE OR REPLACE FUNCTION public._emit_event(
  p_workspace_id uuid,
  p_action text,
  p_result public.event_result,
  p_delivery_id uuid DEFAULT NULL,
  p_message_id uuid DEFAULT NULL,
  p_channel_id text DEFAULT NULL,
  p_attempt integer DEFAULT 0,
  p_error jsonb DEFAULT NULL,
  p_meta jsonb DEFAULT '{}'::jsonb,
  p_payload_ref text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.events (
    workspace_id, delivery_id, message_id, channel_id,
    ts, action, attempt, result, error, payload_ref, meta
  ) VALUES (
    p_workspace_id, p_delivery_id, p_message_id, p_channel_id,
    now(), p_action, COALESCE(p_attempt, 0), p_result, p_error, p_payload_ref, COALESCE(p_meta, '{}'::jsonb)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Core SQL boundary functions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enqueue_messages_and_deliveries(
  p_workspace_id uuid,
  p_endpoint_id uuid,
  p_kind text,
  p_raw_payload_json jsonb,
  p_now_ts timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_hash_version integer := COALESCE((p_raw_payload_json->>'hash_version')::integer, 1);
  v_payload jsonb := COALESCE(p_raw_payload_json->'payload', p_raw_payload_json);
  v_content_hash text := COALESCE(
    NULLIF(p_raw_payload_json->>'content_hash', ''),
    encode(digest(v_payload::text, 'sha256'), 'hex')
  );
  v_tags text[] := public._jsonb_text_array(COALESCE(p_raw_payload_json->'tags', '[]'::jsonb));
  v_source_ref text := NULLIF(p_raw_payload_json->>'source_ref', '');
  v_source jsonb := COALESCE(
    p_raw_payload_json->'source',
    jsonb_build_object('kind', p_kind, 'endpoint_id', p_endpoint_id)
  );
  v_rendered_text text := COALESCE(
    NULLIF(p_raw_payload_json->>'rendered_text', ''),
    NULLIF(v_payload->>'text', ''),
    ''
  );
  v_render_meta jsonb := COALESCE(p_raw_payload_json->'render_meta', '{}'::jsonb);
  v_trace_id text := NULLIF(p_raw_payload_json->>'trace_id', '');
  v_ingest_run_id text := NULLIF(p_raw_payload_json->>'ingest_run_id', '');
  v_message_id uuid;
  v_msg_exists boolean;
  v_queued integer := 0;
  v_deduped integer := 0;
  v_failed integer := 0;
  v_skipped_inflight integer := 0;
  v_error jsonb;
  r_channel record;
  v_is_dedup boolean;
  v_is_inflight boolean;
BEGIN
  IF v_content_hash IS NULL THEN
    RAISE EXCEPTION 'content_hash cannot be resolved';
  END IF;

  -- Upsert message: keep first-seen payload/tags, update seen counters only.
  INSERT INTO public.messages (
    workspace_id,
    hash_version,
    content_hash,
    payload,
    tags,
    source,
    source_ref,
    first_seen_trace_id,
    first_ingest_run_id,
    last_ingest_run_id,
    first_seen_at,
    last_seen_at,
    seen_count,
    created_at
  ) VALUES (
    p_workspace_id,
    v_hash_version,
    v_content_hash,
    v_payload,
    v_tags,
    v_source,
    v_source_ref,
    v_trace_id,
    v_ingest_run_id,
    v_ingest_run_id,
    p_now_ts,
    p_now_ts,
    1,
    p_now_ts
  )
  ON CONFLICT (workspace_id, hash_version, content_hash)
  DO UPDATE
     SET last_seen_at = EXCLUDED.last_seen_at,
         last_ingest_run_id = EXCLUDED.last_ingest_run_id,
         seen_count = public.messages.seen_count + 1
  RETURNING message_id, (xmax = 0) INTO v_message_id, v_msg_exists;

  IF v_message_id IS NULL THEN
    SELECT m.message_id INTO v_message_id
    FROM public.messages m
    WHERE m.workspace_id = p_workspace_id
      AND m.hash_version = v_hash_version
      AND m.content_hash = v_content_hash;
  END IF;

  FOR r_channel IN
    SELECT
      c.channel_id,
      c.platform,
      c.dedup_ttl_hours,
      c.route_filter,
      c.max_parallel,
      c.rate_group
    FROM public.channels c
    WHERE c.workspace_id = p_workspace_id
      AND c.enabled = true
      AND COALESCE(c.paused_until, '-infinity'::timestamptz) <= p_now_ts
      AND public._route_match(v_tags, c.route_filter)
    ORDER BY c.channel_id
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM public.deliveries d
      WHERE d.workspace_id = p_workspace_id
        AND d.channel_id = r_channel.channel_id
        AND d.hash_version = v_hash_version
        AND d.content_hash = v_content_hash
        AND d.status IN ('queued'::public.delivery_status, 'claimed'::public.delivery_status, 'sending'::public.delivery_status, 'retry'::public.delivery_status)
    ) INTO v_is_inflight;

    IF v_is_inflight THEN
      v_skipped_inflight := v_skipped_inflight + 1;
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM public.deliveries d
      WHERE d.workspace_id = p_workspace_id
        AND d.channel_id = r_channel.channel_id
        AND d.hash_version = v_hash_version
        AND d.content_hash = v_content_hash
        AND d.status = 'sent'::public.delivery_status
        AND d.sent_at IS NOT NULL
        AND d.sent_at >= p_now_ts - make_interval(hours => COALESCE(r_channel.dedup_ttl_hours, 168))
    ) INTO v_is_dedup;

    IF v_is_dedup THEN
      INSERT INTO public.deliveries (
        workspace_id, message_id, channel_id, hash_version, content_hash,
        status, not_before, attempt, rendered_text, render_meta,
        trace_id, created_at, updated_at
      ) VALUES (
        p_workspace_id, v_message_id, r_channel.channel_id, v_hash_version, v_content_hash,
        'deduped'::public.delivery_status, p_now_ts, 0, v_rendered_text, v_render_meta,
        v_trace_id, p_now_ts, p_now_ts
      );

      v_deduped := v_deduped + 1;
      PERFORM public._emit_event(
        p_workspace_id, 'dedup_suppressed', 'ok', NULL, v_message_id, r_channel.channel_id,
        0, NULL,
        jsonb_build_object('endpoint_id', p_endpoint_id, 'kind', p_kind, 'trace_id', v_trace_id)
      );
      CONTINUE;
    END IF;

    -- Preflight validation baseline.
    IF r_channel.platform = 'max'::public.channel_platform AND char_length(COALESCE(v_rendered_text, '')) > 4000 THEN
      v_error := jsonb_build_object(
        'category', 'PERMANENT',
        'scope', 'delivery',
        'code', 'message_too_long',
        'message', 'MAX text limit exceeded (4000)'
      );

      INSERT INTO public.deliveries (
        workspace_id, message_id, channel_id, hash_version, content_hash,
        status, not_before, attempt, rendered_text, render_meta,
        trace_id, last_error_json, created_at, updated_at
      ) VALUES (
        p_workspace_id, v_message_id, r_channel.channel_id, v_hash_version, v_content_hash,
        'failed_permanent'::public.delivery_status, p_now_ts, 0, v_rendered_text, v_render_meta,
        v_trace_id, v_error, p_now_ts, p_now_ts
      );

      v_failed := v_failed + 1;
      PERFORM public._emit_event(
        p_workspace_id, 'validation_failed', 'error', NULL, v_message_id, r_channel.channel_id,
        0, v_error,
        jsonb_build_object('endpoint_id', p_endpoint_id, 'kind', p_kind, 'trace_id', v_trace_id)
      );
      CONTINUE;
    END IF;

    IF r_channel.platform = 'telegram'::public.channel_platform AND char_length(COALESCE(v_rendered_text, '')) > 4096 THEN
      v_error := jsonb_build_object(
        'category', 'PERMANENT',
        'scope', 'delivery',
        'code', 'message_too_long',
        'message', 'Telegram text limit exceeded (4096)'
      );

      INSERT INTO public.deliveries (
        workspace_id, message_id, channel_id, hash_version, content_hash,
        status, not_before, attempt, rendered_text, render_meta,
        trace_id, last_error_json, created_at, updated_at
      ) VALUES (
        p_workspace_id, v_message_id, r_channel.channel_id, v_hash_version, v_content_hash,
        'failed_permanent'::public.delivery_status, p_now_ts, 0, v_rendered_text, v_render_meta,
        v_trace_id, v_error, p_now_ts, p_now_ts
      );

      v_failed := v_failed + 1;
      PERFORM public._emit_event(
        p_workspace_id, 'validation_failed', 'error', NULL, v_message_id, r_channel.channel_id,
        0, v_error,
        jsonb_build_object('endpoint_id', p_endpoint_id, 'kind', p_kind, 'trace_id', v_trace_id)
      );
      CONTINUE;
    END IF;

    INSERT INTO public.deliveries (
      workspace_id, message_id, channel_id, hash_version, content_hash,
      status, not_before, attempt, rendered_text, render_meta,
      trace_id, created_at, updated_at
    ) VALUES (
      p_workspace_id, v_message_id, r_channel.channel_id, v_hash_version, v_content_hash,
      'queued'::public.delivery_status, p_now_ts, 0, v_rendered_text, v_render_meta,
      v_trace_id, p_now_ts, p_now_ts
    );

    v_queued := v_queued + 1;

    PERFORM public._emit_event(
      p_workspace_id, 'enqueue', 'ok', NULL, v_message_id, r_channel.channel_id,
      0, NULL,
      jsonb_build_object('endpoint_id', p_endpoint_id, 'kind', p_kind, 'trace_id', v_trace_id)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'message_id', v_message_id,
    'queued', v_queued,
    'deduped', v_deduped,
    'failed_permanent', v_failed,
    'skipped_inflight', v_skipped_inflight
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.enqueue_messages_and_deliveries_batch(
  p_workspace_id uuid,
  p_endpoint_id uuid,
  p_kind text,
  p_raw_payloads_jsonb jsonb,
  p_now_ts timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_item jsonb;
  v_result jsonb;
  v_items integer := 0;
  v_queued integer := 0;
  v_deduped integer := 0;
  v_failed integer := 0;
  v_skipped_inflight integer := 0;
BEGIN
  IF jsonb_typeof(p_raw_payloads_jsonb) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_raw_payloads_jsonb must be array';
  END IF;

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(p_raw_payloads_jsonb)
  LOOP
    v_items := v_items + 1;
    v_result := public.enqueue_messages_and_deliveries(
      p_workspace_id,
      p_endpoint_id,
      p_kind,
      v_item,
      p_now_ts
    );

    v_queued := v_queued + COALESCE((v_result->>'queued')::integer, 0);
    v_deduped := v_deduped + COALESCE((v_result->>'deduped')::integer, 0);
    v_failed := v_failed + COALESCE((v_result->>'failed_permanent')::integer, 0);
    v_skipped_inflight := v_skipped_inflight + COALESCE((v_result->>'skipped_inflight')::integer, 0);
  END LOOP;

  RETURN jsonb_build_object(
    'items', v_items,
    'queued', v_queued,
    'deduped', v_deduped,
    'failed_permanent', v_failed,
    'skipped_inflight', v_skipped_inflight
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.ingest_pull_chunk(
  p_workspace_id uuid,
  p_source_id text,
  p_endpoint_id uuid,
  p_items_jsonb jsonb,
  p_now_ts timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_item jsonb;
  v_source_ref text;
  v_payload_hash text;
  v_window_sec integer := 10;
  v_cursor_to text;
  v_processed integer := 0;
  v_accepted integer := 0;
  v_dropped integer := 0;
  v_inserted boolean;
BEGIN
  IF jsonb_typeof(p_items_jsonb) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_items_jsonb must be array';
  END IF;

  SELECT COALESCE(we.hash_drop_window_sec, 10)
  INTO v_window_sec
  FROM public.workspace_endpoints we
  WHERE we.workspace_id = p_workspace_id
    AND we.endpoint_id = p_endpoint_id
    AND we.enabled = true
  LIMIT 1;

  FOR v_item IN
    SELECT value FROM jsonb_array_elements(p_items_jsonb)
  LOOP
    v_processed := v_processed + 1;
    v_source_ref := NULLIF(v_item->>'source_ref', '');
    v_payload_hash := COALESCE(NULLIF(v_item->>'payload_hash', ''), encode(digest(v_item::text, 'sha256'), 'hex'));
    v_cursor_to := COALESCE(NULLIF(v_item->>'cursor_to', ''), NULLIF(v_item->>'cursor', ''), v_source_ref, v_cursor_to);

    IF v_source_ref IS NOT NULL THEN
      INSERT INTO public.pull_receipts (
        workspace_id, source_id, source_ref, payload_hash, received_at, expires_at
      ) VALUES (
        p_workspace_id, p_source_id, v_source_ref, v_payload_hash, p_now_ts, p_now_ts + interval '3 days'
      )
      ON CONFLICT (workspace_id, source_id, source_ref)
      DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      IF NOT v_inserted THEN
        v_dropped := v_dropped + 1;
        CONTINUE;
      END IF;
    ELSE
      IF EXISTS (
        SELECT 1
        FROM public.pull_receipts pr
        WHERE pr.workspace_id = p_workspace_id
          AND pr.source_id = p_source_id
          AND pr.source_ref IS NULL
          AND pr.payload_hash = v_payload_hash
          AND pr.received_at >= p_now_ts - make_interval(secs => v_window_sec)
      ) THEN
        v_dropped := v_dropped + 1;
        CONTINUE;
      END IF;

      INSERT INTO public.pull_receipts (
        workspace_id, source_id, source_ref, payload_hash, received_at, expires_at
      ) VALUES (
        p_workspace_id, p_source_id, NULL, v_payload_hash, p_now_ts, p_now_ts + interval '3 days'
      );
    END IF;

    PERFORM public.enqueue_messages_and_deliveries(
      p_workspace_id,
      p_endpoint_id,
      'pull',
      v_item,
      p_now_ts
    );

    v_accepted := v_accepted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed,
    'accepted', v_accepted,
    'dropped', v_dropped,
    'cursor_to', v_cursor_to
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_deliveries(
  p_workspace_id uuid,
  p_run_id text,
  p_limit integer,
  p_lease_seconds integer DEFAULT 300,
  p_now_ts timestamptz DEFAULT now()
)
RETURNS TABLE (
  workspace_id uuid,
  delivery_id uuid,
  message_id uuid,
  channel_id text,
  status public.delivery_status,
  attempt integer,
  claim_token uuid,
  sending_lease_until timestamptz,
  not_before timestamptz,
  platform public.channel_platform,
  rate_group text,
  rendered_text text
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_effective_limit integer := GREATEST(COALESCE(p_limit, 0), 0);
BEGIN
  IF v_effective_limit = 0 THEN
    RETURN;
  END IF;

  -- Deadlock-avoidance lock order.
  PERFORM 1
  FROM public.platform_limits pl
  WHERE pl.workspace_id = p_workspace_id
  ORDER BY pl.platform, pl.rate_group
  FOR UPDATE;

  PERFORM 1
  FROM public.channels c
  WHERE c.workspace_id = p_workspace_id
  ORDER BY c.channel_id
  FOR UPDATE;

  RETURN QUERY
  WITH sending_counts AS (
    SELECT d.channel_id, count(*)::integer AS sending_count
    FROM public.deliveries d
    WHERE d.workspace_id = p_workspace_id
      AND d.status = 'sending'::public.delivery_status
      AND COALESCE(d.sending_lease_until, 'infinity'::timestamptz) > p_now_ts
    GROUP BY d.channel_id
  ),
  channel_caps AS (
    SELECT
      c.workspace_id,
      c.channel_id,
      c.platform,
      c.rate_group,
      c.rate_rps,
      c.max_parallel,
      c.next_allowed_at,
      COALESCE(sc.sending_count, 0) AS sending_count,
      GREATEST(c.max_parallel - COALESCE(sc.sending_count, 0), 0) AS parallel_slots,
      pl.rate_rps AS platform_rate_rps,
      pl.next_allowed_at AS platform_next_allowed_at
    FROM public.channels c
    LEFT JOIN sending_counts sc
      ON sc.channel_id = c.channel_id
    LEFT JOIN public.platform_limits pl
      ON pl.workspace_id = c.workspace_id
     AND pl.platform = c.platform
     AND pl.rate_group = c.rate_group
    WHERE c.workspace_id = p_workspace_id
      AND c.enabled = true
      AND COALESCE(c.paused_until, '-infinity'::timestamptz) <= p_now_ts
  ),
  ready_caps AS (
    SELECT cc.*
    FROM channel_caps cc
    WHERE cc.parallel_slots > 0
      AND (
        cc.rate_rps IS NULL
        OR cc.rate_rps <= 0
        OR COALESCE(cc.next_allowed_at, '-infinity'::timestamptz) <= p_now_ts
      )
      AND (
        cc.platform_rate_rps IS NULL
        OR cc.platform_rate_rps <= 0
        OR COALESCE(cc.platform_next_allowed_at, '-infinity'::timestamptz) <= p_now_ts
      )
  ),
  due_locked AS (
    SELECT d.workspace_id, d.delivery_id, d.message_id, d.channel_id, d.priority, d.created_at, d.not_before
    FROM public.deliveries d
    WHERE d.workspace_id = p_workspace_id
      AND (
        d.status = 'queued'::public.delivery_status
        OR (d.status = 'retry'::public.delivery_status AND COALESCE(d.next_retry_at, '-infinity'::timestamptz) <= p_now_ts)
      )
      AND COALESCE(d.not_before, d.created_at, p_now_ts) <= p_now_ts
    ORDER BY d.priority, d.created_at
    FOR UPDATE SKIP LOCKED
    LIMIT GREATEST(v_effective_limit * 20, 200)
  ),
  ranked AS (
    SELECT
      dl.*,
      rc.platform,
      rc.rate_group,
      row_number() OVER (PARTITION BY dl.channel_id ORDER BY dl.priority, dl.created_at) AS rn_channel,
      rc.parallel_slots
    FROM due_locked dl
    JOIN ready_caps rc
      ON rc.workspace_id = dl.workspace_id
     AND rc.channel_id = dl.channel_id
  ),
  selected AS (
    SELECT r.*
    FROM ranked r
    WHERE r.rn_channel <= r.parallel_slots
    ORDER BY r.priority, r.created_at
    LIMIT v_effective_limit
  ),
  updated AS (
    UPDATE public.deliveries d
    SET status = 'sending'::public.delivery_status,
        attempt = d.attempt + 1,
        claim_token = gen_random_uuid(),
        claimed_at = COALESCE(d.claimed_at, p_now_ts),
        sending_started_at = p_now_ts,
        lease_owner = COALESCE(NULLIF(p_run_id, ''), 'dispatcher'),
        sending_lease_until = p_now_ts + make_interval(secs => p_lease_seconds),
        lease_until = p_now_ts + make_interval(secs => p_lease_seconds),
        updated_at = p_now_ts
    FROM selected s
    WHERE d.workspace_id = s.workspace_id
      AND d.delivery_id = s.delivery_id
    RETURNING d.workspace_id, d.delivery_id, d.message_id, d.channel_id,
              d.status, d.attempt, d.claim_token, d.sending_lease_until, d.not_before
  ),
  per_channel AS (
    SELECT u.workspace_id, u.channel_id, count(*)::integer AS n
    FROM updated u
    GROUP BY u.workspace_id, u.channel_id
  ),
  upd_channels AS (
    UPDATE public.channels c
    SET next_allowed_at =
      CASE
        WHEN c.rate_rps IS NULL OR c.rate_rps <= 0 THEN c.next_allowed_at
        ELSE GREATEST(COALESCE(c.next_allowed_at, p_now_ts), p_now_ts)
             + ((pc.n::double precision / c.rate_rps::double precision) * interval '1 second')
      END,
      updated_at = p_now_ts
    FROM per_channel pc
    WHERE c.workspace_id = pc.workspace_id
      AND c.channel_id = pc.channel_id
    RETURNING c.workspace_id, c.channel_id
  ),
  per_group AS (
    SELECT c.workspace_id, c.platform, c.rate_group, count(*)::integer AS n
    FROM updated u
    JOIN public.channels c
      ON c.workspace_id = u.workspace_id
     AND c.channel_id = u.channel_id
    GROUP BY c.workspace_id, c.platform, c.rate_group
  ),
  upd_platform AS (
    UPDATE public.platform_limits pl
    SET next_allowed_at =
      CASE
        WHEN pl.rate_rps IS NULL OR pl.rate_rps <= 0 THEN pl.next_allowed_at
        ELSE GREATEST(COALESCE(pl.next_allowed_at, p_now_ts), p_now_ts)
             + ((pg.n::double precision / pl.rate_rps::double precision) * interval '1 second')
      END,
      updated_at = p_now_ts
    FROM per_group pg
    WHERE pl.workspace_id = pg.workspace_id
      AND pl.platform = pg.platform
      AND pl.rate_group = pg.rate_group
    RETURNING pl.workspace_id
  )
  SELECT
    u.workspace_id,
    u.delivery_id,
    u.message_id,
    u.channel_id,
    u.status,
    u.attempt,
    u.claim_token,
    u.sending_lease_until,
    u.not_before,
    c.platform,
    c.rate_group,
    d.rendered_text
  FROM updated u
  JOIN public.channels c
    ON c.workspace_id = u.workspace_id
   AND c.channel_id = u.channel_id
  JOIN public.deliveries d
    ON d.workspace_id = u.workspace_id
   AND d.delivery_id = u.delivery_id
  ORDER BY d.priority, d.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_sent(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_provider_message_id text,
  p_sent_at timestamptz,
  p_raw_meta_json jsonb,
  p_claim_token uuid
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.deliveries;
BEGIN
  IF p_claim_token IS NULL THEN
    RAISE EXCEPTION 'claim_token is required';
  END IF;

  UPDATE public.deliveries d
  SET status = 'sent'::public.delivery_status,
      sent_at = COALESCE(p_sent_at, now()),
      provider_message_id = p_provider_message_id,
      provider_meta = COALESCE(d.provider_meta, '{}'::jsonb) || COALESCE(p_raw_meta_json, '{}'::jsonb),
      last_error_json = NULL,
      next_retry_at = NULL,
      claim_token = NULL,
      lease_owner = NULL,
      sending_lease_until = NULL,
      lease_until = NULL,
      updated_at = now()
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status
    AND d.claim_token = p_claim_token
  RETURNING d.* INTO v_row;

  IF v_row.delivery_id IS NULL THEN
    RAISE EXCEPTION 'mark_sent conflict: delivery not in sending with matching claim_token';
  END IF;

  UPDATE public.channels c
  SET error_streak = 0,
      updated_at = now()
  WHERE c.workspace_id = v_row.workspace_id
    AND c.channel_id = v_row.channel_id;

  PERFORM public._emit_event(
    v_row.workspace_id,
    'sent',
    'ok',
    v_row.delivery_id,
    v_row.message_id,
    v_row.channel_id,
    v_row.attempt,
    NULL,
    jsonb_build_object('provider_message_id', p_provider_message_id)
  );

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_sent(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_provider_message_id text,
  p_sent_at timestamptz,
  p_raw_meta_json jsonb
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_claim_token uuid;
BEGIN
  SELECT d.claim_token INTO v_claim_token
  FROM public.deliveries d
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status;

  RETURN public.mark_sent(
    p_workspace_id,
    p_delivery_id,
    p_provider_message_id,
    p_sent_at,
    p_raw_meta_json,
    v_claim_token
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.schedule_retry(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_next_retry_at timestamptz,
  p_error_json jsonb,
  p_claim_token uuid,
  p_retry_after_ms integer DEFAULT NULL
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.deliveries;
  v_next_retry_at timestamptz;
  v_max_attempts integer := 5;
BEGIN
  IF p_claim_token IS NULL THEN
    RAISE EXCEPTION 'claim_token is required';
  END IF;

  SELECT d.* INTO v_row
  FROM public.deliveries d
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status
    AND d.claim_token = p_claim_token
  FOR UPDATE;

  IF v_row.delivery_id IS NULL THEN
    RAISE EXCEPTION 'schedule_retry conflict: delivery not in sending with matching claim_token';
  END IF;

  IF v_row.attempt >= v_max_attempts THEN
    UPDATE public.deliveries d
    SET status = 'dead'::public.delivery_status,
        claim_token = NULL,
        lease_owner = NULL,
        sending_lease_until = NULL,
        lease_until = NULL,
        next_retry_at = NULL,
        last_error_json = p_error_json,
        updated_at = now()
    WHERE d.workspace_id = v_row.workspace_id
      AND d.delivery_id = v_row.delivery_id
    RETURNING d.* INTO v_row;

    PERFORM public._emit_event(
      v_row.workspace_id,
      'dead_letter',
      'error',
      v_row.delivery_id,
      v_row.message_id,
      v_row.channel_id,
      v_row.attempt,
      p_error_json,
      jsonb_build_object('reason', 'max_attempts')
    );

    RETURN v_row;
  END IF;

  v_next_retry_at := COALESCE(
    p_next_retry_at,
    public._next_retry_at(v_row.attempt, now(), p_retry_after_ms)
  );

  UPDATE public.deliveries d
  SET status = 'retry'::public.delivery_status,
      next_retry_at = v_next_retry_at,
      last_error_json = p_error_json,
      claim_token = NULL,
      lease_owner = NULL,
      sending_lease_until = NULL,
      lease_until = NULL,
      updated_at = now()
  WHERE d.workspace_id = v_row.workspace_id
    AND d.delivery_id = v_row.delivery_id
  RETURNING d.* INTO v_row;

  PERFORM public._emit_event(
    v_row.workspace_id,
    'retry_scheduled',
    'error',
    v_row.delivery_id,
    v_row.message_id,
    v_row.channel_id,
    v_row.attempt,
    p_error_json,
    jsonb_build_object('next_retry_at', v_next_retry_at)
  );

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.schedule_retry(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_next_retry_at timestamptz,
  p_error_json jsonb
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_claim_token uuid;
BEGIN
  SELECT d.claim_token INTO v_claim_token
  FROM public.deliveries d
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status;

  RETURN public.schedule_retry(
    p_workspace_id,
    p_delivery_id,
    p_next_retry_at,
    p_error_json,
    v_claim_token,
    NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_permanent(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_error_json jsonb,
  p_claim_token uuid
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.deliveries;
  v_scope text := COALESCE(p_error_json->>'scope', 'delivery');
  v_channel_disable_threshold integer := 3;
BEGIN
  IF p_claim_token IS NULL THEN
    RAISE EXCEPTION 'claim_token is required';
  END IF;

  UPDATE public.deliveries d
  SET status = 'failed_permanent'::public.delivery_status,
      last_error_json = p_error_json,
      next_retry_at = NULL,
      claim_token = NULL,
      lease_owner = NULL,
      sending_lease_until = NULL,
      lease_until = NULL,
      updated_at = now()
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status
    AND d.claim_token = p_claim_token
  RETURNING d.* INTO v_row;

  IF v_row.delivery_id IS NULL THEN
    RAISE EXCEPTION 'fail_permanent conflict: delivery not in sending with matching claim_token';
  END IF;

  IF v_scope = 'channel' THEN
    UPDATE public.channels c
    SET error_streak = c.error_streak + 1,
        paused_until = CASE
          WHEN c.error_streak + 1 >= v_channel_disable_threshold THEN c.paused_until
          ELSE GREATEST(COALESCE(c.paused_until, now()), now()) + interval '1 hour'
        END,
        enabled = CASE
          WHEN c.error_streak + 1 >= v_channel_disable_threshold THEN false
          ELSE c.enabled
        END,
        updated_at = now()
    WHERE c.workspace_id = v_row.workspace_id
      AND c.channel_id = v_row.channel_id;

    PERFORM public._emit_event(
      v_row.workspace_id,
      'channel_paused',
      'error',
      v_row.delivery_id,
      v_row.message_id,
      v_row.channel_id,
      v_row.attempt,
      p_error_json,
      '{}'::jsonb
    );

    IF EXISTS (
      SELECT 1
      FROM public.channels c
      WHERE c.workspace_id = v_row.workspace_id
        AND c.channel_id = v_row.channel_id
        AND c.enabled = false
    ) THEN
      PERFORM public._emit_event(
        v_row.workspace_id,
        'channel_disabled',
        'error',
        v_row.delivery_id,
        v_row.message_id,
        v_row.channel_id,
        v_row.attempt,
        p_error_json,
        '{}'::jsonb
      );
    END IF;
  END IF;

  PERFORM public._emit_event(
    v_row.workspace_id,
    'failed_permanent',
    'error',
    v_row.delivery_id,
    v_row.message_id,
    v_row.channel_id,
    v_row.attempt,
    p_error_json,
    '{}'::jsonb
  );

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.fail_permanent(
  p_workspace_id uuid,
  p_delivery_id uuid,
  p_error_json jsonb
)
RETURNS public.deliveries
LANGUAGE plpgsql
AS $$
DECLARE
  v_claim_token uuid;
BEGIN
  SELECT d.claim_token INTO v_claim_token
  FROM public.deliveries d
  WHERE d.workspace_id = p_workspace_id
    AND d.delivery_id = p_delivery_id
    AND d.status = 'sending'::public.delivery_status;

  RETURN public.fail_permanent(
    p_workspace_id,
    p_delivery_id,
    p_error_json,
    v_claim_token
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.recover_sending_leases(
  p_workspace_id uuid DEFAULT NULL,
  p_now_ts timestamptz DEFAULT now()
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_row record;
  v_recovered integer := 0;
  v_max_attempts integer := 5;
  v_next_retry_at timestamptz;
BEGIN
  FOR v_row IN
    SELECT d.workspace_id, d.delivery_id, d.message_id, d.channel_id, d.attempt
    FROM public.deliveries d
    WHERE d.status = 'sending'::public.delivery_status
      AND COALESCE(d.sending_lease_until, d.lease_until, '-infinity'::timestamptz) < p_now_ts
      AND (p_workspace_id IS NULL OR d.workspace_id = p_workspace_id)
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_row.attempt >= v_max_attempts THEN
      UPDATE public.deliveries d
      SET status = 'dead'::public.delivery_status,
          next_retry_at = NULL,
          claim_token = NULL,
          lease_owner = NULL,
          sending_lease_until = NULL,
          lease_until = NULL,
          updated_at = p_now_ts
      WHERE d.workspace_id = v_row.workspace_id
        AND d.delivery_id = v_row.delivery_id;

      PERFORM public._emit_event(
        v_row.workspace_id,
        'dead_letter',
        'error',
        v_row.delivery_id,
        v_row.message_id,
        v_row.channel_id,
        v_row.attempt,
        jsonb_build_object('code', 'sending_lease_expired_max_attempts'),
        '{}'::jsonb
      );
    ELSE
      v_next_retry_at := public._next_retry_at(v_row.attempt, p_now_ts, NULL);

      UPDATE public.deliveries d
      SET status = 'retry'::public.delivery_status,
          next_retry_at = v_next_retry_at,
          claim_token = NULL,
          lease_owner = NULL,
          sending_lease_until = NULL,
          lease_until = NULL,
          updated_at = p_now_ts
      WHERE d.workspace_id = v_row.workspace_id
        AND d.delivery_id = v_row.delivery_id;

      PERFORM public._emit_event(
        v_row.workspace_id,
        'sending_lease_expired',
        'error',
        v_row.delivery_id,
        v_row.message_id,
        v_row.channel_id,
        v_row.attempt,
        jsonb_build_object('next_retry_at', v_next_retry_at),
        '{}'::jsonb
      );
    END IF;

    v_recovered := v_recovered + 1;
  END LOOP;

  RETURN v_recovered;
END;
$$;

COMMIT;
