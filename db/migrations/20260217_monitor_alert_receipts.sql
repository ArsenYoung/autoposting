BEGIN;

CREATE TABLE public.monitor_alert_receipts (
  workspace_key text NOT NULL,
  alert_fingerprint text NOT NULL,
  first_sent_at timestamptz NOT NULL DEFAULT now(),
  last_sent_at timestamptz NOT NULL DEFAULT now(),
  sent_count integer NOT NULL DEFAULT 1,
  CONSTRAINT monitor_alert_receipts_pkey PRIMARY KEY (workspace_key, alert_fingerprint)
);

ALTER TABLE public.monitor_alert_receipts OWNER TO neondb_owner;

CREATE INDEX ix_monitor_alert_receipts_last_sent
  ON public.monitor_alert_receipts (last_sent_at DESC);

COMMIT;
