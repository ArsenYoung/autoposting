--
-- PostgreSQL database dump
--

\restrict q1jF1u9SArUPe0uFWFPOr2iQDSmydGylyj6Wh5oX9NQT3mmOOhAv3iMyf8BTV3P

-- Dumped from database version 17.7 (bdd1736)
-- Dumped by pg_dump version 17.7 (Ubuntu 17.7-3.pgdg24.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: channel_platform; Type: TYPE; Schema: public; Owner: neondb_owner
--

CREATE TYPE public.channel_platform AS ENUM (
    'telegram',
    'max'
);


ALTER TYPE public.channel_platform OWNER TO neondb_owner;

--
-- Name: delivery_status; Type: TYPE; Schema: public; Owner: neondb_owner
--

CREATE TYPE public.delivery_status AS ENUM (
    'queued',
    'claimed',
    'sending',
    'sent',
    'retry',
    'deduped',
    'failed_permanent',
    'dead'
);


ALTER TYPE public.delivery_status OWNER TO neondb_owner;

--
-- Name: event_result; Type: TYPE; Schema: public; Owner: neondb_owner
--

CREATE TYPE public.event_result AS ENUM (
    'ok',
    'error'
);


ALTER TYPE public.event_result OWNER TO neondb_owner;

--
-- Name: workspace_status; Type: TYPE; Schema: public; Owner: neondb_owner
--

CREATE TYPE public.workspace_status AS ENUM (
    'active',
    'paused',
    'disabled'
);


ALTER TYPE public.workspace_status OWNER TO neondb_owner;

--
-- Name: _emit_event(uuid, text, public.event_result, uuid, uuid, text, integer, jsonb, jsonb, text); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public._emit_event(p_workspace_id uuid, p_action text, p_result public.event_result, p_delivery_id uuid DEFAULT NULL::uuid, p_message_id uuid DEFAULT NULL::uuid, p_channel_id text DEFAULT NULL::text, p_attempt integer DEFAULT 0, p_error jsonb DEFAULT NULL::jsonb, p_meta jsonb DEFAULT '{}'::jsonb, p_payload_ref text DEFAULT NULL::text) RETURNS void
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


ALTER FUNCTION public._emit_event(p_workspace_id uuid, p_action text, p_result public.event_result, p_delivery_id uuid, p_message_id uuid, p_channel_id text, p_attempt integer, p_error jsonb, p_meta jsonb, p_payload_ref text) OWNER TO neondb_owner;

--
-- Name: _jsonb_text_array(jsonb); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public._jsonb_text_array(p_json jsonb) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT COALESCE(array_agg(value), ARRAY[]::text[])
  FROM jsonb_array_elements_text(COALESCE(p_json, '[]'::jsonb)) AS t(value);
$$;


ALTER FUNCTION public._jsonb_text_array(p_json jsonb) OWNER TO neondb_owner;

--
-- Name: _next_retry_at(integer, timestamp with time zone, integer); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public._next_retry_at(p_attempt integer, p_now timestamp with time zone DEFAULT now(), p_retry_after_ms integer DEFAULT NULL::integer) RETURNS timestamp with time zone
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


ALTER FUNCTION public._next_retry_at(p_attempt integer, p_now timestamp with time zone, p_retry_after_ms integer) OWNER TO neondb_owner;

--
-- Name: _route_match(text[], jsonb); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public._route_match(p_tags text[], p_route_filter jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
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


ALTER FUNCTION public._route_match(p_tags text[], p_route_filter jsonb) OWNER TO neondb_owner;

--
-- Name: claim_deliveries(uuid, text, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.claim_deliveries(p_workspace_id uuid, p_run_id text, p_limit integer, p_lease_seconds integer DEFAULT 300, p_now_ts timestamp with time zone DEFAULT now()) RETURNS TABLE(workspace_id uuid, delivery_id uuid, message_id uuid, channel_id text, status public.delivery_status, attempt integer, claim_token uuid, sending_lease_until timestamp with time zone, not_before timestamp with time zone, platform public.channel_platform, rate_group text, rendered_text text)
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


ALTER FUNCTION public.claim_deliveries(p_workspace_id uuid, p_run_id text, p_limit integer, p_lease_seconds integer, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

--
-- Name: dispatcher_tick(uuid, text, integer, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.dispatcher_tick(p_forced_workspace_id uuid DEFAULT NULL::uuid, p_run_id text DEFAULT NULL::text, p_limit integer DEFAULT 20, p_lease_seconds integer DEFAULT 300, p_now_ts timestamp with time zone DEFAULT now()) RETURNS TABLE(workspace_id uuid, delivery_id uuid, message_id uuid, channel_id text, platform text, attempt integer, claim_token uuid, rendered_text text, target_id text, auth_ref text, channel_settings jsonb, render_meta jsonb, payload jsonb, content_hash text, source_ref text, claim_has_item boolean, lock_acquired boolean, lock_skipped boolean, is_forced boolean, is_empty boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lock_key text := 'autoposting_dispatcher_lock';
  v_lock_owner text := gen_random_uuid()::text;
  v_lock_acquired boolean := false;
  v_lock_ttl_seconds integer := 30;
  v_lock_now timestamptz := clock_timestamp();
  v_workspace_id uuid := NULL;
  v_is_forced boolean := false;
  v_now timestamptz := COALESCE(p_now_ts, now());
BEGIN
  WITH acquired AS (
    INSERT INTO public.workflow_locks (lock_key, locked_until, locked_by, updated_at)
    VALUES (
      v_lock_key,
      v_lock_now + make_interval(secs => v_lock_ttl_seconds),
      v_lock_owner,
      v_lock_now
    )
    ON CONFLICT (lock_key) DO UPDATE
    SET locked_until = EXCLUDED.locked_until,
        locked_by = EXCLUDED.locked_by,
        updated_at = EXCLUDED.updated_at
    WHERE public.workflow_locks.locked_until < v_lock_now
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM acquired)
    INTO v_lock_acquired;

  IF NOT v_lock_acquired THEN
    RETURN QUERY
    SELECT
      p_forced_workspace_id AS workspace_id,
      NULL::uuid AS delivery_id,
      NULL::uuid AS message_id,
      NULL::text AS channel_id,
      NULL::text AS platform,
      NULL::integer AS attempt,
      NULL::uuid AS claim_token,
      NULL::text AS rendered_text,
      NULL::text AS target_id,
      NULL::text AS auth_ref,
      '{}'::jsonb AS channel_settings,
      '{}'::jsonb AS render_meta,
      '{}'::jsonb AS payload,
      NULL::text AS content_hash,
      NULL::text AS source_ref,
      false AS claim_has_item,
      false AS lock_acquired,
      true AS lock_skipped,
      p_forced_workspace_id IS NOT NULL AS is_forced,
      p_forced_workspace_id IS NULL AS is_empty;
    RETURN;
  END IF;

  INSERT INTO public.dispatcher_state (id, last_workspace_id, updated_at)
  VALUES (1, NULL, v_now)
  ON CONFLICT (id) DO NOTHING;

  IF p_forced_workspace_id IS NOT NULL THEN
    v_workspace_id := p_forced_workspace_id;
    v_is_forced := true;
  ELSE
    SELECT picked.workspace_id
      INTO v_workspace_id
    FROM (
      SELECT w.workspace_id
      FROM public.workspaces w
      CROSS JOIN public.dispatcher_state ds
      WHERE ds.id = 1
        AND w.status = 'active'
      ORDER BY
        CASE
          WHEN ds.last_workspace_id IS NULL THEN 0
          WHEN w.workspace_id > ds.last_workspace_id THEN 0
          ELSE 1
        END,
        w.workspace_id
      LIMIT 1
    ) picked;
    v_is_forced := false;
  END IF;

  IF v_workspace_id IS NULL THEN
    UPDATE public.workflow_locks wl
    SET locked_until = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE wl.lock_key = v_lock_key
      AND wl.locked_by = v_lock_owner;

    RETURN QUERY
    SELECT
      NULL::uuid AS workspace_id,
      NULL::uuid AS delivery_id,
      NULL::uuid AS message_id,
      NULL::text AS channel_id,
      NULL::text AS platform,
      NULL::integer AS attempt,
      NULL::uuid AS claim_token,
      NULL::text AS rendered_text,
      NULL::text AS target_id,
      NULL::text AS auth_ref,
      '{}'::jsonb AS channel_settings,
      '{}'::jsonb AS render_meta,
      '{}'::jsonb AS payload,
      NULL::text AS content_hash,
      NULL::text AS source_ref,
      false AS claim_has_item,
      true AS lock_acquired,
      false AS lock_skipped,
      false AS is_forced,
      true AS is_empty;
    RETURN;
  END IF;

  IF NOT v_is_forced THEN
    UPDATE public.dispatcher_state ds
    SET last_workspace_id = v_workspace_id,
        updated_at = v_now
    WHERE ds.id = 1;
  END IF;

  RETURN QUERY
  WITH claimed AS (
    SELECT
      cd.workspace_id,
      cd.delivery_id,
      cd.message_id,
      cd.channel_id,
      cd.platform::text AS platform,
      cd.attempt,
      cd.claim_token,
      cd.rendered_text,
      c.target_id,
      c.auth_ref,
      c.settings AS channel_settings,
      COALESCE(d.render_meta, '{}'::jsonb) AS render_meta,
      COALESCE(m.payload, '{}'::jsonb) AS payload,
      m.content_hash,
      m.source_ref
    FROM public.claim_deliveries(
      v_workspace_id,
      p_run_id,
      GREATEST(1, COALESCE(p_limit, 20)),
      GREATEST(30, COALESCE(p_lease_seconds, 300)),
      v_now
    ) cd
    JOIN public.deliveries d
      ON d.workspace_id = cd.workspace_id
     AND d.delivery_id = cd.delivery_id
    JOIN public.messages m
      ON m.workspace_id = cd.workspace_id
     AND m.message_id = cd.message_id
    JOIN public.channels c
      ON c.workspace_id = cd.workspace_id
     AND c.channel_id = cd.channel_id
  ),
  rows AS (
    SELECT
      c.workspace_id,
      c.delivery_id,
      c.message_id,
      c.channel_id,
      c.platform,
      c.attempt,
      c.claim_token,
      c.rendered_text,
      c.target_id,
      c.auth_ref,
      c.channel_settings,
      c.render_meta,
      c.payload,
      c.content_hash,
      c.source_ref,
      true AS claim_has_item
    FROM claimed c
    UNION ALL
    SELECT
      v_workspace_id AS workspace_id,
      NULL::uuid AS delivery_id,
      NULL::uuid AS message_id,
      NULL::text AS channel_id,
      NULL::text AS platform,
      NULL::integer AS attempt,
      NULL::uuid AS claim_token,
      NULL::text AS rendered_text,
      NULL::text AS target_id,
      NULL::text AS auth_ref,
      '{}'::jsonb AS channel_settings,
      '{}'::jsonb AS render_meta,
      '{}'::jsonb AS payload,
      NULL::text AS content_hash,
      NULL::text AS source_ref,
      false AS claim_has_item
    WHERE NOT EXISTS (SELECT 1 FROM claimed)
  )
  SELECT
    r.workspace_id,
    r.delivery_id,
    r.message_id,
    r.channel_id,
    r.platform,
    r.attempt,
    r.claim_token,
    r.rendered_text,
    r.target_id,
    r.auth_ref,
    r.channel_settings,
    r.render_meta,
    r.payload,
    r.content_hash,
    r.source_ref,
    r.claim_has_item,
    true AS lock_acquired,
    false AS lock_skipped,
    v_is_forced AS is_forced,
    false AS is_empty
  FROM rows r;

  UPDATE public.workflow_locks wl
  SET locked_until = clock_timestamp(),
      updated_at = clock_timestamp()
  WHERE wl.lock_key = v_lock_key
    AND wl.locked_by = v_lock_owner;

  RETURN;
END;
$$;


ALTER FUNCTION public.dispatcher_tick(p_forced_workspace_id uuid, p_run_id text, p_limit integer, p_lease_seconds integer, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

--
-- Name: enqueue_messages_and_deliveries(uuid, uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.enqueue_messages_and_deliveries(p_workspace_id uuid, p_endpoint_id uuid, p_kind text, p_raw_payload_json jsonb, p_now_ts timestamp with time zone DEFAULT now()) RETURNS jsonb
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


ALTER FUNCTION public.enqueue_messages_and_deliveries(p_workspace_id uuid, p_endpoint_id uuid, p_kind text, p_raw_payload_json jsonb, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

--
-- Name: enqueue_messages_and_deliveries_batch(uuid, uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.enqueue_messages_and_deliveries_batch(p_workspace_id uuid, p_endpoint_id uuid, p_kind text, p_raw_payloads_jsonb jsonb, p_now_ts timestamp with time zone DEFAULT now()) RETURNS jsonb
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


ALTER FUNCTION public.enqueue_messages_and_deliveries_batch(p_workspace_id uuid, p_endpoint_id uuid, p_kind text, p_raw_payloads_jsonb jsonb, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.deliveries (
    workspace_id uuid NOT NULL,
    delivery_id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid NOT NULL,
    channel_id text NOT NULL,
    status public.delivery_status DEFAULT 'queued'::public.delivery_status NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    not_before timestamp with time zone DEFAULT now() NOT NULL,
    lease_owner text,
    lease_until timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_error text,
    last_http_status integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_at timestamp with time zone,
    sending_started_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    sent_at timestamp with time zone,
    claim_token uuid,
    provider_message_id text,
    provider_meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_error_json jsonb,
    hash_version integer DEFAULT 1 NOT NULL,
    content_hash text,
    scheduled_for timestamp with time zone,
    attempt integer DEFAULT 0 NOT NULL,
    sending_lease_until timestamp with time zone,
    rendered_text text,
    render_meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    template_version text,
    trace_id text,
    enqueue_batch_id uuid,
    CONSTRAINT deliveries_claim_token_when_claimed CHECK (((status <> ALL (ARRAY['claimed'::public.delivery_status, 'sending'::public.delivery_status])) OR (claim_token IS NOT NULL))),
    CONSTRAINT deliveries_lease_consistency CHECK ((((lease_owner IS NULL) AND (lease_until IS NULL)) OR ((lease_owner IS NOT NULL) AND (lease_until IS NOT NULL))))
);


ALTER TABLE public.deliveries OWNER TO neondb_owner;

--
-- Name: fail_permanent(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.fail_permanent(p_workspace_id uuid, p_delivery_id uuid, p_error_json jsonb) RETURNS public.deliveries
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


ALTER FUNCTION public.fail_permanent(p_workspace_id uuid, p_delivery_id uuid, p_error_json jsonb) OWNER TO neondb_owner;

--
-- Name: fail_permanent(uuid, uuid, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.fail_permanent(p_workspace_id uuid, p_delivery_id uuid, p_error_json jsonb, p_claim_token uuid) RETURNS public.deliveries
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


ALTER FUNCTION public.fail_permanent(p_workspace_id uuid, p_delivery_id uuid, p_error_json jsonb, p_claim_token uuid) OWNER TO neondb_owner;

--
-- Name: ingest_pull_chunk(uuid, text, uuid, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.ingest_pull_chunk(p_workspace_id uuid, p_source_id text, p_endpoint_id uuid, p_items_jsonb jsonb, p_now_ts timestamp with time zone DEFAULT now()) RETURNS jsonb
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
      WHERE source_ref IS NOT NULL
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


ALTER FUNCTION public.ingest_pull_chunk(p_workspace_id uuid, p_source_id text, p_endpoint_id uuid, p_items_jsonb jsonb, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

--
-- Name: mark_sent(uuid, uuid, text, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.mark_sent(p_workspace_id uuid, p_delivery_id uuid, p_provider_message_id text, p_sent_at timestamp with time zone, p_raw_meta_json jsonb) RETURNS public.deliveries
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


ALTER FUNCTION public.mark_sent(p_workspace_id uuid, p_delivery_id uuid, p_provider_message_id text, p_sent_at timestamp with time zone, p_raw_meta_json jsonb) OWNER TO neondb_owner;

--
-- Name: mark_sent(uuid, uuid, text, timestamp with time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.mark_sent(p_workspace_id uuid, p_delivery_id uuid, p_provider_message_id text, p_sent_at timestamp with time zone, p_raw_meta_json jsonb, p_claim_token uuid) RETURNS public.deliveries
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


ALTER FUNCTION public.mark_sent(p_workspace_id uuid, p_delivery_id uuid, p_provider_message_id text, p_sent_at timestamp with time zone, p_raw_meta_json jsonb, p_claim_token uuid) OWNER TO neondb_owner;

--
-- Name: recover_sending_leases(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.recover_sending_leases(p_workspace_id uuid DEFAULT NULL::uuid, p_now_ts timestamp with time zone DEFAULT now()) RETURNS integer
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


ALTER FUNCTION public.recover_sending_leases(p_workspace_id uuid, p_now_ts timestamp with time zone) OWNER TO neondb_owner;

--
-- Name: schedule_retry(uuid, uuid, timestamp with time zone, jsonb); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.schedule_retry(p_workspace_id uuid, p_delivery_id uuid, p_next_retry_at timestamp with time zone, p_error_json jsonb) RETURNS public.deliveries
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


ALTER FUNCTION public.schedule_retry(p_workspace_id uuid, p_delivery_id uuid, p_next_retry_at timestamp with time zone, p_error_json jsonb) OWNER TO neondb_owner;

--
-- Name: schedule_retry(uuid, uuid, timestamp with time zone, jsonb, uuid, integer); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.schedule_retry(p_workspace_id uuid, p_delivery_id uuid, p_next_retry_at timestamp with time zone, p_error_json jsonb, p_claim_token uuid, p_retry_after_ms integer DEFAULT NULL::integer) RETURNS public.deliveries
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


ALTER FUNCTION public.schedule_retry(p_workspace_id uuid, p_delivery_id uuid, p_next_retry_at timestamp with time zone, p_error_json jsonb, p_claim_token uuid, p_retry_after_ms integer) OWNER TO neondb_owner;

--
-- Name: tg_set_updated_at(); Type: FUNCTION; Schema: public; Owner: neondb_owner
--

CREATE FUNCTION public.tg_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at = now();
  return new;
end $$;


ALTER FUNCTION public.tg_set_updated_at() OWNER TO neondb_owner;

--
-- Name: bot_inbox; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.bot_inbox (
    workspace_id uuid NOT NULL,
    provider text NOT NULL,
    chat_id text NOT NULL,
    provider_message_id text NOT NULL,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.bot_inbox OWNER TO neondb_owner;

--
-- Name: bot_logs; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.bot_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    chat_id text NOT NULL,
    inbound_provider_message_id text,
    matched_rule_id text,
    matched_rule_version integer,
    action text NOT NULL,
    result public.event_result DEFAULT 'ok'::public.event_result NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bot_logs OWNER TO neondb_owner;

--
-- Name: bot_outbox; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.bot_outbox (
    workspace_id uuid NOT NULL,
    chat_id text NOT NULL,
    inbound_provider_message_id text NOT NULL,
    response_hash text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    provider_message_id text,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.bot_outbox OWNER TO neondb_owner;

--
-- Name: bot_rules; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.bot_rules (
    workspace_id uuid NOT NULL,
    rule_id text NOT NULL,
    version integer NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 100 NOT NULL,
    match_type text DEFAULT 'keywords'::text NOT NULL,
    pattern text,
    keywords jsonb,
    response_template text NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bot_rules OWNER TO neondb_owner;

--
-- Name: bot_state; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.bot_state (
    workspace_id uuid NOT NULL,
    chat_id text NOT NULL,
    state text DEFAULT 'default'::text NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    turns integer DEFAULT 0 NOT NULL,
    expires_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bot_state OWNER TO neondb_owner;

--
-- Name: channels; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.channels (
    workspace_id uuid NOT NULL,
    channel_id text NOT NULL,
    platform public.channel_platform NOT NULL,
    target_id text NOT NULL,
    auth_ref text NOT NULL,
    rate_group text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    title text,
    send_mode text DEFAULT 'mixed'::text NOT NULL,
    rate_rps numeric,
    max_parallel integer DEFAULT 1 NOT NULL,
    next_allowed_at timestamp with time zone,
    paused_until timestamp with time zone,
    window_mode text DEFAULT 'immediate'::text NOT NULL,
    posting_window jsonb,
    dedup_ttl_hours integer DEFAULT 168 NOT NULL,
    error_streak integer DEFAULT 0 NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    tags text[],
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    timezone text,
    route_filter jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.channels OWNER TO neondb_owner;

--
-- Name: delivery_dedup; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.delivery_dedup (
    workspace_id uuid NOT NULL,
    message_id uuid NOT NULL,
    channel_id text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


ALTER TABLE public.delivery_dedup OWNER TO neondb_owner;

--
-- Name: delivery_events; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.delivery_events (
    workspace_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    event_id bigint NOT NULL,
    delivery_id uuid NOT NULL,
    result public.event_result NOT NULL,
    stage text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL
)
PARTITION BY RANGE (created_at);


ALTER TABLE public.delivery_events OWNER TO neondb_owner;

--
-- Name: delivery_events_default; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.delivery_events_default (
    workspace_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    event_id bigint NOT NULL,
    delivery_id uuid NOT NULL,
    result public.event_result NOT NULL,
    stage text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.delivery_events_default OWNER TO neondb_owner;

--
-- Name: delivery_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: neondb_owner
--

ALTER TABLE public.delivery_events ALTER COLUMN event_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.delivery_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dispatcher_state; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.dispatcher_state (
    id integer DEFAULT 1 NOT NULL,
    last_workspace_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dispatcher_state_singleton CHECK ((id = 1))
);


ALTER TABLE public.dispatcher_state OWNER TO neondb_owner;

--
-- Name: events; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    workspace_id uuid NOT NULL,
    delivery_id uuid,
    message_id uuid,
    channel_id text,
    ts timestamp with time zone DEFAULT now() NOT NULL,
    action text NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    result public.event_result NOT NULL,
    error jsonb,
    payload_ref text,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.events OWNER TO neondb_owner;

--
-- Name: ingest_runs; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.ingest_runs (
    workspace_id uuid NOT NULL,
    run_id text NOT NULL,
    kind text NOT NULL,
    endpoint_id uuid,
    source_id text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    stats_json jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.ingest_runs OWNER TO neondb_owner;

--
-- Name: ingress_receipts; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.ingress_receipts (
    workspace_id uuid NOT NULL,
    endpoint_id uuid NOT NULL,
    endpoint_kind text NOT NULL,
    source_ref text,
    payload_hash text NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


ALTER TABLE public.ingress_receipts OWNER TO neondb_owner;

--
-- Name: media_blobs; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.media_blobs (
    workspace_id uuid NOT NULL,
    blob_ref text NOT NULL,
    provider text NOT NULL,
    file_id text,
    url text,
    expires_at timestamp with time zone,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.media_blobs OWNER TO neondb_owner;

--
-- Name: media_origin; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.media_origin (
    workspace_id uuid NOT NULL,
    blob_ref text NOT NULL,
    origin_url text NOT NULL,
    sha256 text,
    content_type text,
    size_bytes bigint,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    ref_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.media_origin OWNER TO neondb_owner;

--
-- Name: messages; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.messages (
    workspace_id uuid NOT NULL,
    message_id uuid DEFAULT gen_random_uuid() NOT NULL,
    source jsonb DEFAULT '{}'::jsonb NOT NULL,
    source_ref text,
    source_url_canonical text,
    content_hash text NOT NULL,
    text text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    hash_version integer DEFAULT 1 NOT NULL,
    normalization_version integer,
    tags text[],
    first_seen_trace_id text,
    first_ingest_run_id text,
    last_ingest_run_id text,
    seen_count bigint DEFAULT 1 NOT NULL
);


ALTER TABLE public.messages OWNER TO neondb_owner;

--
-- Name: platform_limits; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.platform_limits (
    workspace_id uuid NOT NULL,
    platform public.channel_platform NOT NULL,
    rate_group text NOT NULL,
    rate_rps numeric NOT NULL,
    burst integer DEFAULT 1 NOT NULL,
    next_allowed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.platform_limits OWNER TO neondb_owner;

--
-- Name: pull_cursors; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.pull_cursors (
    workspace_id uuid NOT NULL,
    source_id text NOT NULL,
    cursor_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pull_cursors OWNER TO neondb_owner;

--
-- Name: pull_receipts; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.pull_receipts (
    workspace_id uuid NOT NULL,
    source_id text NOT NULL,
    source_ref text,
    payload_hash text NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


ALTER TABLE public.pull_receipts OWNER TO neondb_owner;

--
-- Name: pull_sources; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.pull_sources (
    workspace_id uuid NOT NULL,
    source_id text NOT NULL,
    endpoint_id uuid,
    kind text NOT NULL,
    config_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.pull_sources OWNER TO neondb_owner;

--
-- Name: workspace_endpoints; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.workspace_endpoints (
    workspace_id uuid NOT NULL,
    endpoint_id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text NOT NULL,
    secret_hash text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    ingress_rps numeric DEFAULT 5 NOT NULL,
    max_payload_bytes integer DEFAULT 262144 NOT NULL,
    hash_drop_window_sec integer DEFAULT 10 NOT NULL,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source_id text
);


ALTER TABLE public.workspace_endpoints OWNER TO neondb_owner;

--
-- Name: workflow_locks; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.workflow_locks (
    lock_key text NOT NULL,
    locked_until timestamp with time zone NOT NULL,
    locked_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.workflow_locks OWNER TO neondb_owner;

--
-- Name: workspaces; Type: TABLE; Schema: public; Owner: neondb_owner
--

CREATE TABLE public.workspaces (
    workspace_id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    status public.workspace_status DEFAULT 'active'::public.workspace_status NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.workspaces OWNER TO neondb_owner;

--
-- Name: delivery_events_default; Type: TABLE ATTACH; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.delivery_events ATTACH PARTITION public.delivery_events_default DEFAULT;


--
-- Name: bot_inbox bot_inbox_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_inbox
    ADD CONSTRAINT bot_inbox_pkey PRIMARY KEY (workspace_id, provider, chat_id, provider_message_id);


--
-- Name: bot_logs bot_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_logs
    ADD CONSTRAINT bot_logs_pkey PRIMARY KEY (id);


--
-- Name: bot_outbox bot_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_outbox
    ADD CONSTRAINT bot_outbox_pkey PRIMARY KEY (workspace_id, chat_id, inbound_provider_message_id);


--
-- Name: bot_rules bot_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_rules
    ADD CONSTRAINT bot_rules_pkey PRIMARY KEY (workspace_id, rule_id, version);


--
-- Name: bot_state bot_state_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_state
    ADD CONSTRAINT bot_state_pkey PRIMARY KEY (workspace_id, chat_id);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (workspace_id, channel_id);


--
-- Name: channels channels_workspace_id_platform_target_id_key; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_workspace_id_platform_target_id_key UNIQUE (workspace_id, platform, target_id);


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (workspace_id, delivery_id);


--
-- Name: delivery_dedup delivery_dedup_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.delivery_dedup
    ADD CONSTRAINT delivery_dedup_pkey PRIMARY KEY (workspace_id, message_id, channel_id);


--
-- Name: delivery_events delivery_events_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.delivery_events
    ADD CONSTRAINT delivery_events_pkey PRIMARY KEY (workspace_id, created_at, event_id);


--
-- Name: delivery_events_default delivery_events_default_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.delivery_events_default
    ADD CONSTRAINT delivery_events_default_pkey PRIMARY KEY (workspace_id, created_at, event_id);


--
-- Name: dispatcher_state dispatcher_state_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.dispatcher_state
    ADD CONSTRAINT dispatcher_state_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: ingest_runs ingest_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.ingest_runs
    ADD CONSTRAINT ingest_runs_pkey PRIMARY KEY (workspace_id, run_id);


--
-- Name: ingress_receipts ingress_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.ingress_receipts
    ADD CONSTRAINT ingress_receipts_pkey PRIMARY KEY (workspace_id, endpoint_id, payload_hash, received_at);


--
-- Name: media_blobs media_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.media_blobs
    ADD CONSTRAINT media_blobs_pkey PRIMARY KEY (workspace_id, blob_ref, provider);


--
-- Name: media_origin media_origin_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.media_origin
    ADD CONSTRAINT media_origin_pkey PRIMARY KEY (workspace_id, blob_ref);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (workspace_id, message_id);


--
-- Name: messages messages_ws_hashv_contenthash_key; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_ws_hashv_contenthash_key UNIQUE (workspace_id, hash_version, content_hash);


--
-- Name: platform_limits platform_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.platform_limits
    ADD CONSTRAINT platform_limits_pkey PRIMARY KEY (workspace_id, platform, rate_group);


--
-- Name: pull_cursors pull_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_cursors
    ADD CONSTRAINT pull_cursors_pkey PRIMARY KEY (workspace_id, source_id);


--
-- Name: pull_receipts pull_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_receipts
    ADD CONSTRAINT pull_receipts_pkey PRIMARY KEY (workspace_id, source_id, payload_hash, received_at);


--
-- Name: pull_sources pull_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_sources
    ADD CONSTRAINT pull_sources_pkey PRIMARY KEY (workspace_id, source_id);


--
-- Name: workspace_endpoints workspace_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.workspace_endpoints
    ADD CONSTRAINT workspace_endpoints_pkey PRIMARY KEY (workspace_id, endpoint_id);


--
-- Name: workflow_locks workflow_locks_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.workflow_locks
    ADD CONSTRAINT workflow_locks_pkey PRIMARY KEY (lock_key);


--
-- Name: workspaces workspaces_pkey; Type: CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.workspaces
    ADD CONSTRAINT workspaces_pkey PRIMARY KEY (workspace_id);


--
-- Name: ix_events_created; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_created ON ONLY public.delivery_events USING btree (workspace_id, created_at DESC);


--
-- Name: delivery_events_default_workspace_id_created_at_idx; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX delivery_events_default_workspace_id_created_at_idx ON public.delivery_events_default USING btree (workspace_id, created_at DESC);


--
-- Name: ix_events_delivery; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_delivery ON ONLY public.delivery_events USING btree (workspace_id, delivery_id, created_at DESC);


--
-- Name: delivery_events_default_workspace_id_delivery_id_created_at_idx; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX delivery_events_default_workspace_id_delivery_id_created_at_idx ON public.delivery_events_default USING btree (workspace_id, delivery_id, created_at DESC);


--
-- Name: ix_events_stage_result; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_stage_result ON ONLY public.delivery_events USING btree (workspace_id, stage, result, created_at DESC);


--
-- Name: delivery_events_default_workspace_id_stage_result_created_a_idx; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX delivery_events_default_workspace_id_stage_result_created_a_idx ON public.delivery_events_default USING btree (workspace_id, stage, result, created_at DESC);


--
-- Name: ix_bot_logs_recent; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_bot_logs_recent ON public.bot_logs USING btree (workspace_id, created_at DESC);


--
-- Name: ix_channels_tags_gin; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_channels_tags_gin ON public.channels USING gin (tags);


--
-- Name: ix_channels_ws_enabled; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_channels_ws_enabled ON public.channels USING btree (workspace_id, enabled);


--
-- Name: ix_channels_ws_paused; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_channels_ws_paused ON public.channels USING btree (workspace_id, paused_until);


--
-- Name: ix_channels_ws_platform_rategroup; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_channels_ws_platform_rategroup ON public.channels USING btree (workspace_id, platform, rate_group);


--
-- Name: ix_deliveries_channel_status; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_channel_status ON public.deliveries USING btree (workspace_id, channel_id, status, created_at DESC);


--
-- Name: ix_deliveries_claim_token; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_claim_token ON public.deliveries USING btree (workspace_id, claim_token) WHERE (claim_token IS NOT NULL);


--
-- Name: ix_deliveries_inflight_dedup; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_inflight_dedup ON public.deliveries USING btree (workspace_id, channel_id, hash_version, content_hash, created_at) WHERE (status = ANY (ARRAY['queued'::public.delivery_status, 'claimed'::public.delivery_status, 'sending'::public.delivery_status, 'retry'::public.delivery_status]));


--
-- Name: ix_deliveries_lease; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_lease ON public.deliveries USING btree (workspace_id, lease_until);


--
-- Name: ix_deliveries_msg_channel; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_msg_channel ON public.deliveries USING btree (workspace_id, message_id, channel_id);


--
-- Name: ix_deliveries_pick; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_pick ON public.deliveries USING btree (workspace_id, status, not_before, priority, created_at);


--
-- Name: ix_deliveries_retry_at; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_retry_at ON public.deliveries USING btree (workspace_id, next_retry_at) WHERE (status = 'retry'::public.delivery_status);


--
-- Name: ix_deliveries_sending_lease; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_sending_lease ON public.deliveries USING btree (workspace_id, lease_until) WHERE (status = ANY (ARRAY['sending'::public.delivery_status, 'claimed'::public.delivery_status]));


--
-- Name: ix_deliveries_sent_dedup; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_sent_dedup ON public.deliveries USING btree (workspace_id, channel_id, hash_version, content_hash, sent_at) WHERE ((status = 'sent'::public.delivery_status) AND (sent_at IS NOT NULL));


--
-- Name: ix_deliveries_sent_or_deduped_lookup; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_sent_or_deduped_lookup ON public.deliveries USING btree (workspace_id, channel_id, hash_version, content_hash) WHERE (status = ANY (ARRAY['sent'::public.delivery_status, 'deduped'::public.delivery_status]));


--
-- Name: ix_deliveries_ws_delivery_id; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_deliveries_ws_delivery_id ON public.deliveries USING btree (workspace_id, delivery_id);


--
-- Name: ix_delivery_dedup_expires; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_delivery_dedup_expires ON public.delivery_dedup USING btree (workspace_id, expires_at);


--
-- Name: ix_delivery_dedup_expires_only; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_delivery_dedup_expires_only ON public.delivery_dedup USING btree (expires_at);


--
-- Name: ix_endpoints_kind_secret_active; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_endpoints_kind_secret_active ON public.workspace_endpoints USING btree (kind, secret_hash) WHERE (enabled = true);


--
-- Name: ix_endpoints_ws_enabled; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_endpoints_ws_enabled ON public.workspace_endpoints USING btree (workspace_id, enabled);


--
-- Name: ix_events_ws_action_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_action_ts ON public.events USING btree (workspace_id, action, ts DESC);


--
-- Name: ix_events_ws_channel_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_channel_ts ON public.events USING btree (workspace_id, channel_id, ts DESC) WHERE (channel_id IS NOT NULL);


--
-- Name: ix_events_ws_delivery_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_delivery_ts ON public.events USING btree (workspace_id, delivery_id, ts DESC) WHERE (delivery_id IS NOT NULL);


--
-- Name: ix_events_ws_message_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_message_ts ON public.events USING btree (workspace_id, message_id, ts DESC) WHERE (message_id IS NOT NULL);


--
-- Name: ix_events_ws_result_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_result_ts ON public.events USING btree (workspace_id, result, ts DESC);


--
-- Name: ix_events_ws_ts; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_events_ws_ts ON public.events USING btree (workspace_id, ts DESC);


--
-- Name: ix_ingest_runs_recent; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_ingest_runs_recent ON public.ingest_runs USING btree (workspace_id, started_at DESC);


--
-- Name: ix_ingress_receipts_expires; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_ingress_receipts_expires ON public.ingress_receipts USING btree (expires_at);


--
-- Name: ix_ingress_receipts_payload_window; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_ingress_receipts_payload_window ON public.ingress_receipts USING btree (workspace_id, endpoint_id, payload_hash, received_at DESC);


--
-- Name: ix_media_blobs_provider; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_media_blobs_provider ON public.media_blobs USING btree (workspace_id, provider, blob_ref);


--
-- Name: ix_messages_tags_gin; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_messages_tags_gin ON public.messages USING gin (tags);


--
-- Name: ix_messages_ws_created; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_messages_ws_created ON public.messages USING btree (workspace_id, created_at DESC);


--
-- Name: ix_pull_receipts_expires; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_pull_receipts_expires ON public.pull_receipts USING btree (expires_at);


--
-- Name: ix_pull_receipts_payload_window; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_pull_receipts_payload_window ON public.pull_receipts USING btree (workspace_id, source_id, payload_hash, received_at DESC);


--
-- Name: ix_pull_sources_enabled; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE INDEX ix_pull_sources_enabled ON public.pull_sources USING btree (workspace_id, enabled);


--
-- Name: ux_bot_rules_one_enabled; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_bot_rules_one_enabled ON public.bot_rules USING btree (workspace_id, rule_id) WHERE (enabled = true);


--
-- Name: ux_deliveries_enqueue_batch_guard; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_deliveries_enqueue_batch_guard ON public.deliveries USING btree (workspace_id, enqueue_batch_id, channel_id, hash_version, content_hash) WHERE (enqueue_batch_id IS NOT NULL);


--
-- Name: ux_endpoints_kind_active_secret; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_endpoints_kind_active_secret ON public.workspace_endpoints USING btree (kind, secret_hash) WHERE (enabled = true);


--
-- Name: ux_endpoints_pull_source_active; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_endpoints_pull_source_active ON public.workspace_endpoints USING btree (workspace_id, source_id) WHERE ((enabled = true) AND (kind = 'pull_source'::text));


--
-- Name: ux_endpoints_ws_active_secret; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_endpoints_ws_active_secret ON public.workspace_endpoints USING btree (workspace_id, kind, secret_hash) WHERE (enabled = true);


--
-- Name: ux_ingress_receipts_source_ref; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_ingress_receipts_source_ref ON public.ingress_receipts USING btree (workspace_id, endpoint_id, source_ref) WHERE (source_ref IS NOT NULL);


--
-- Name: ux_pull_receipts_source_ref; Type: INDEX; Schema: public; Owner: neondb_owner
--

CREATE UNIQUE INDEX ux_pull_receipts_source_ref ON public.pull_receipts USING btree (workspace_id, source_id, source_ref) WHERE (source_ref IS NOT NULL);


--
-- Name: delivery_events_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: neondb_owner
--

ALTER INDEX public.delivery_events_pkey ATTACH PARTITION public.delivery_events_default_pkey;


--
-- Name: delivery_events_default_workspace_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: neondb_owner
--

ALTER INDEX public.ix_events_created ATTACH PARTITION public.delivery_events_default_workspace_id_created_at_idx;


--
-- Name: delivery_events_default_workspace_id_delivery_id_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: neondb_owner
--

ALTER INDEX public.ix_events_delivery ATTACH PARTITION public.delivery_events_default_workspace_id_delivery_id_created_at_idx;


--
-- Name: delivery_events_default_workspace_id_stage_result_created_a_idx; Type: INDEX ATTACH; Schema: public; Owner: neondb_owner
--

ALTER INDEX public.ix_events_stage_result ATTACH PARTITION public.delivery_events_default_workspace_id_stage_result_created_a_idx;


--
-- Name: bot_rules trg_bot_rules_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_bot_rules_updated_at BEFORE UPDATE ON public.bot_rules FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: bot_state trg_bot_state_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_bot_state_updated_at BEFORE UPDATE ON public.bot_state FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: channels trg_channels_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_channels_updated_at BEFORE UPDATE ON public.channels FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: deliveries trg_deliveries_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_deliveries_updated_at BEFORE UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: media_blobs trg_media_blobs_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_media_blobs_updated_at BEFORE UPDATE ON public.media_blobs FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: messages trg_messages_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_messages_updated_at BEFORE UPDATE ON public.messages FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: platform_limits trg_platform_limits_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_platform_limits_updated_at BEFORE UPDATE ON public.platform_limits FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: pull_sources trg_pull_sources_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_pull_sources_updated_at BEFORE UPDATE ON public.pull_sources FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: workspace_endpoints trg_workspace_endpoints_updated_at; Type: TRIGGER; Schema: public; Owner: neondb_owner
--

CREATE TRIGGER trg_workspace_endpoints_updated_at BEFORE UPDATE ON public.workspace_endpoints FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();


--
-- Name: bot_inbox bot_inbox_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_inbox
    ADD CONSTRAINT bot_inbox_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: bot_logs bot_logs_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_logs
    ADD CONSTRAINT bot_logs_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: bot_outbox bot_outbox_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_outbox
    ADD CONSTRAINT bot_outbox_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: bot_rules bot_rules_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_rules
    ADD CONSTRAINT bot_rules_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: bot_state bot_state_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.bot_state
    ADD CONSTRAINT bot_state_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: channels channels_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.channels
    ADD CONSTRAINT channels_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: deliveries deliveries_workspace_id_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_workspace_id_channel_id_fkey FOREIGN KEY (workspace_id, channel_id) REFERENCES public.channels(workspace_id, channel_id) ON DELETE CASCADE;


--
-- Name: deliveries deliveries_workspace_id_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_workspace_id_message_id_fkey FOREIGN KEY (workspace_id, message_id) REFERENCES public.messages(workspace_id, message_id) ON DELETE CASCADE;


--
-- Name: events events_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: ingest_runs ingest_runs_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.ingest_runs
    ADD CONSTRAINT ingest_runs_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: ingress_receipts ingress_receipts_workspace_id_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.ingress_receipts
    ADD CONSTRAINT ingress_receipts_workspace_id_endpoint_id_fkey FOREIGN KEY (workspace_id, endpoint_id) REFERENCES public.workspace_endpoints(workspace_id, endpoint_id) ON DELETE CASCADE;


--
-- Name: media_blobs media_blobs_workspace_id_blob_ref_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.media_blobs
    ADD CONSTRAINT media_blobs_workspace_id_blob_ref_fkey FOREIGN KEY (workspace_id, blob_ref) REFERENCES public.media_origin(workspace_id, blob_ref) ON DELETE CASCADE;


--
-- Name: media_origin media_origin_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.media_origin
    ADD CONSTRAINT media_origin_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: messages messages_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: platform_limits platform_limits_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.platform_limits
    ADD CONSTRAINT platform_limits_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: pull_cursors pull_cursors_workspace_id_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_cursors
    ADD CONSTRAINT pull_cursors_workspace_id_source_id_fkey FOREIGN KEY (workspace_id, source_id) REFERENCES public.pull_sources(workspace_id, source_id) ON DELETE CASCADE;


--
-- Name: pull_receipts pull_receipts_workspace_id_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_receipts
    ADD CONSTRAINT pull_receipts_workspace_id_source_id_fkey FOREIGN KEY (workspace_id, source_id) REFERENCES public.pull_sources(workspace_id, source_id) ON DELETE CASCADE;


--
-- Name: pull_sources pull_sources_workspace_id_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_sources
    ADD CONSTRAINT pull_sources_workspace_id_endpoint_id_fkey FOREIGN KEY (workspace_id, endpoint_id) REFERENCES public.workspace_endpoints(workspace_id, endpoint_id) ON DELETE SET NULL;


--
-- Name: pull_sources pull_sources_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.pull_sources
    ADD CONSTRAINT pull_sources_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- Name: workspace_endpoints workspace_endpoints_workspace_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: neondb_owner
--

ALTER TABLE ONLY public.workspace_endpoints
    ADD CONSTRAINT workspace_endpoints_workspace_id_fkey FOREIGN KEY (workspace_id) REFERENCES public.workspaces(workspace_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict q1jF1u9SArUPe0uFWFPOr2iQDSmydGylyj6Wh5oX9NQT3mmOOhAv3iMyf8BTV3P
