-- migrate:up
CREATE INDEX IF NOT EXISTS payments_created_at_id_idx
  ON payments (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS payments_status_created_at_id_idx
  ON payments (status, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS payments_ride_id_created_at_id_idx
  ON payments (ride_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS payment_status_history_payment_id_occurred_at_idx
  ON payment_status_history (payment_id, occurred_at DESC);

-- migrate:down
DROP INDEX IF EXISTS payment_status_history_payment_id_occurred_at_idx;
DROP INDEX IF EXISTS payments_ride_id_created_at_id_idx;
DROP INDEX IF EXISTS payments_status_created_at_id_idx;
DROP INDEX IF EXISTS payments_created_at_id_idx;
