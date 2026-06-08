-- migrate:up
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id text NOT NULL UNIQUE,
  ride_id text NOT NULL,
  pickup jsonb NOT NULL,
  dropoff jsonb NOT NULL,
  vehicle_type text NOT NULL,
  price_snapshot jsonb NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL UNIQUE,
  aggregate_type text NOT NULL,
  aggregate_id text NOT NULL,
  event_type text NOT NULL,
  topic text NOT NULL,
  partition_key text,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 10,
  next_retry_at timestamptz NOT NULL DEFAULT now(),
  processing_started_at timestamptz,
  processing_owner text,
  last_error text,
  last_error_at timestamptz,
  dlq_topic text,
  dlq_payload jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bookings_created_at_idx
  ON bookings (created_at DESC);

CREATE INDEX IF NOT EXISTS outbox_events_claim_idx
  ON outbox_events (status, next_retry_at, occurred_at);

CREATE INDEX IF NOT EXISTS outbox_events_processing_idx
  ON outbox_events (status, processing_started_at);

DROP TRIGGER IF EXISTS set_bookings_updated_at ON bookings;
CREATE TRIGGER set_bookings_updated_at
BEFORE UPDATE ON bookings
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_outbox_updated_at ON outbox_events;
CREATE TRIGGER set_outbox_updated_at
BEFORE UPDATE ON outbox_events
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- migrate:down
DROP TRIGGER IF EXISTS set_outbox_updated_at ON outbox_events;
DROP TRIGGER IF EXISTS set_bookings_updated_at ON bookings;
DROP TABLE IF EXISTS outbox_events;
DROP TABLE IF EXISTS bookings;
