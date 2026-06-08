-- migrate:up
CREATE TABLE IF NOT EXISTS inbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL UNIQUE,
  trace_id text,
  topic text NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS inbox_events_received_at_idx
  ON inbox_events (received_at DESC);

CREATE INDEX IF NOT EXISTS bookings_user_status_created_idx
  ON bookings (user_id, status, created_at DESC);

-- Keep only one active booking per user before enforcing uniqueness.
WITH ranked_active AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY created_at DESC, updated_at DESC, id DESC
    ) AS rn
  FROM bookings
  WHERE user_id IS NOT NULL
    AND status IN ('PENDING', 'REQUESTED', 'ACCEPTED', 'CONFIRMED')
)
UPDATE bookings AS b
SET status = 'CANCELLED',
    cancelled_at = COALESCE(b.cancelled_at, now()),
    updated_at = now()
FROM ranked_active AS ra
WHERE b.id = ra.id
  AND ra.rn > 1;

-- Ensure ride_id can be made unique on existing legacy data.
WITH ranked_ride AS (
  SELECT
    id,
    ride_id,
    ROW_NUMBER() OVER (
      PARTITION BY ride_id
      ORDER BY created_at DESC, updated_at DESC, id DESC
    ) AS rn
  FROM bookings
  WHERE ride_id IS NOT NULL
)
UPDATE bookings AS b
SET ride_id = CONCAT(
      b.ride_id,
      '_legacy_',
      SUBSTRING(REPLACE(b.id::text, '-', '') FROM 1 FOR 8)
    ),
    updated_at = now()
FROM ranked_ride AS rr
WHERE b.id = rr.id
  AND rr.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS bookings_ride_id_uq
  ON bookings (ride_id);

CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_per_user_idx
  ON bookings (user_id)
  WHERE user_id IS NOT NULL
    AND status IN ('PENDING', 'REQUESTED', 'ACCEPTED', 'CONFIRMED');

DROP TRIGGER IF EXISTS set_inbox_updated_at ON inbox_events;
CREATE TRIGGER set_inbox_updated_at
BEFORE UPDATE ON inbox_events
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- migrate:down
DROP TRIGGER IF EXISTS set_inbox_updated_at ON inbox_events;
DROP INDEX IF EXISTS bookings_one_active_per_user_idx;
DROP INDEX IF EXISTS bookings_ride_id_uq;
DROP INDEX IF EXISTS bookings_user_status_created_idx;
DROP INDEX IF EXISTS inbox_events_received_at_idx;
DROP TABLE IF EXISTS inbox_events;
