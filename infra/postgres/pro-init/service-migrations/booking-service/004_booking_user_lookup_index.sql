-- migrate:up
CREATE INDEX IF NOT EXISTS bookings_user_created_at_idx
  ON bookings (user_id, created_at DESC);

-- migrate:down
DROP INDEX IF EXISTS bookings_user_created_at_idx;
