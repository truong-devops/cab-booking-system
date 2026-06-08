-- migrate:up
CREATE TABLE IF NOT EXISTS idempotency_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_key text NOT NULL,
  user_id char(8) NOT NULL,
  idem_key text NOT NULL,
  request_hash text NOT NULL,
  response_code integer NOT NULL,
  response_headers jsonb,
  response_body jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (route_key, user_id, idem_key)
);

CREATE TABLE IF NOT EXISTS inbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL UNIQUE,
  trace_id text,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

CREATE TABLE IF NOT EXISTS outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL UNIQUE,
  trace_id text,
  request_id text,
  event_type text NOT NULL,
  topic text NOT NULL,
  payload jsonb NOT NULL,
  occurred_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz
);

CREATE INDEX IF NOT EXISTS outbox_events_status_created_at_idx
  ON outbox_events (status, created_at DESC);

CREATE INDEX IF NOT EXISTS inbox_events_event_id_idx
  ON inbox_events (event_id);

-- migrate:down
DROP INDEX IF EXISTS inbox_events_event_id_idx;
DROP INDEX IF EXISTS outbox_events_status_created_at_idx;
DROP TABLE IF EXISTS outbox_events;
DROP TABLE IF EXISTS inbox_events;
DROP TABLE IF EXISTS idempotency_keys;
