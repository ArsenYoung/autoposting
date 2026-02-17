BEGIN;

CREATE OR REPLACE FUNCTION public.dispatcher_tick(
  p_forced_workspace_id uuid DEFAULT NULL::uuid,
  p_run_id text DEFAULT NULL::text,
  p_limit integer DEFAULT 20,
  p_lease_seconds integer DEFAULT 300,
  p_now_ts timestamp with time zone DEFAULT now()
) RETURNS TABLE(
  workspace_id uuid,
  delivery_id uuid,
  message_id uuid,
  channel_id text,
  platform text,
  attempt integer,
  claim_token uuid,
  rendered_text text,
  target_id text,
  auth_ref text,
  channel_settings jsonb,
  render_meta jsonb,
  payload jsonb,
  content_hash text,
  source_ref text,
  claim_has_item boolean,
  lock_acquired boolean,
  lock_skipped boolean,
  is_forced boolean,
  is_empty boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_lock_key bigint := hashtext('autoposting_dispatcher_lock')::bigint;
  v_lock_acquired boolean := false;
  v_workspace_id uuid := NULL;
  v_is_forced boolean := false;
  v_now timestamptz := COALESCE(p_now_ts, now());
BEGIN
  v_lock_acquired := pg_try_advisory_lock(v_lock_key);

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
    PERFORM pg_advisory_unlock(v_lock_key);

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

  PERFORM pg_advisory_unlock(v_lock_key);
  RETURN;
EXCEPTION
  WHEN OTHERS THEN
    IF v_lock_acquired THEN
      BEGIN
        PERFORM pg_advisory_unlock(v_lock_key);
      EXCEPTION
        WHEN OTHERS THEN
          NULL;
      END;
    END IF;
    RAISE;
END;
$$;

ALTER FUNCTION public.dispatcher_tick(
  p_forced_workspace_id uuid,
  p_run_id text,
  p_limit integer,
  p_lease_seconds integer,
  p_now_ts timestamp with time zone
) OWNER TO neondb_owner;

COMMIT;
