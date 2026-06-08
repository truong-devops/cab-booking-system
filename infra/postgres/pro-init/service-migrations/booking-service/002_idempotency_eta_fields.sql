-- migrate:up
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS user_id char(8),
  ADD COLUMN IF NOT EXISTS distance_km numeric(10, 3),
  ADD COLUMN IF NOT EXISTS eta_minutes integer;

CREATE TABLE IF NOT EXISTS idempotency_keys (
  route_key text NOT NULL,
  user_id char(8) NOT NULL,
  idem_key text NOT NULL,
  request_hash text NOT NULL,
  response_code integer,
  response_body jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_key, user_id, idem_key)
);

DROP TRIGGER IF EXISTS set_idempotency_updated_at ON idempotency_keys;
CREATE TRIGGER set_idempotency_updated_at
BEFORE UPDATE ON idempotency_keys
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- migrate:down
DROP TRIGGER IF EXISTS set_idempotency_updated_at ON idempotency_keys;
DROP TABLE IF EXISTS idempotency_keys;
ALTER TABLE bookings
  DROP COLUMN IF EXISTS eta_minutes,
  DROP COLUMN IF EXISTS distance_km,
  DROP COLUMN IF EXISTS user_id;
