CREATE UNIQUE INDEX IF NOT EXISTS users_phone_uq
  ON users (phone)
  WHERE phone IS NOT NULL;

CREATE INDEX IF NOT EXISTS users_email_idx
  ON users (email);

CREATE INDEX IF NOT EXISTS users_role_idx
  ON users (role);

CREATE INDEX IF NOT EXISTS users_status_idx
  ON users (status);

CREATE UNIQUE INDEX IF NOT EXISTS outbox_events_event_id_uq
  ON outbox_events (event_id);

CREATE INDEX IF NOT EXISTS outbox_events_status_occurred_at_idx
  ON outbox_events (status, occurred_at DESC);
