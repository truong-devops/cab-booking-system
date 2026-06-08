CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id text NOT NULL,
  rider_id char(8) NOT NULL,
  driver_id char(8) NOT NULL,
  rating integer NOT NULL,
  comment text,
  status text NOT NULL,
  status_updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reviews_rating_check CHECK (rating >= 1 AND rating <= 5)
);

CREATE TABLE IF NOT EXISTS reviews_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reviews_id uuid NOT NULL,
  from_status text,
  to_status text NOT NULL,
  reason text,
  actor_id char(8),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  trace_id text
);

CREATE TABLE IF NOT EXISTS review_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL,
  status text NOT NULL,
  reason text,
  status_updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_key text NOT NULL,
  user_id char(8) NOT NULL,
  idem_key text NOT NULL,
  request_hash text NOT NULL,
  response_status integer,
  response_headers jsonb,
  response_body jsonb,
  locked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz
);

CREATE TABLE IF NOT EXISTS inbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL,
  consumer text NOT NULL,
  topic text NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL,
  aggregate_type text NOT NULL,
  aggregate_id uuid NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  occurred_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_updated_at_reviews ON reviews;
CREATE TRIGGER set_updated_at_reviews
BEFORE UPDATE ON reviews
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_review_status_history ON review_status_history;
CREATE TRIGGER set_updated_at_review_status_history
BEFORE UPDATE ON review_status_history
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_idempotency_keys ON idempotency_keys;
CREATE TRIGGER set_updated_at_idempotency_keys
BEFORE UPDATE ON idempotency_keys
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_inbox_events ON inbox_events;
CREATE TRIGGER set_updated_at_inbox_events
BEFORE UPDATE ON inbox_events
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_outbox_events ON outbox_events;
CREATE TRIGGER set_updated_at_outbox_events
BEFORE UPDATE ON outbox_events
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
