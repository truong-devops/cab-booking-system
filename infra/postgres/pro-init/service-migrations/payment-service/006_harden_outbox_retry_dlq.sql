-- migrate:up
ALTER TABLE outbox_events
  ADD COLUMN IF NOT EXISTS partition_key text,
  ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS max_attempts integer NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS next_retry_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS processing_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS processing_owner text,
  ADD COLUMN IF NOT EXISTS last_error_at timestamptz,
  ADD COLUMN IF NOT EXISTS dlq_topic text,
  ADD COLUMN IF NOT EXISTS dlq_payload jsonb;

UPDATE outbox_events
SET next_retry_at = COALESCE(next_retry_at, now())
WHERE next_retry_at IS NULL;

CREATE INDEX IF NOT EXISTS outbox_events_claim_idx
  ON outbox_events (status, next_retry_at, created_at);

CREATE INDEX IF NOT EXISTS outbox_events_processing_idx
  ON outbox_events (status, processing_started_at);

-- migrate:down
DROP INDEX IF EXISTS outbox_events_processing_idx;
DROP INDEX IF EXISTS outbox_events_claim_idx;

ALTER TABLE outbox_events
  DROP COLUMN IF EXISTS dlq_payload,
  DROP COLUMN IF EXISTS dlq_topic,
  DROP COLUMN IF EXISTS last_error_at,
  DROP COLUMN IF EXISTS processing_owner,
  DROP COLUMN IF EXISTS processing_started_at,
  DROP COLUMN IF EXISTS next_retry_at,
  DROP COLUMN IF EXISTS max_attempts,
  DROP COLUMN IF EXISTS attempt_count,
  DROP COLUMN IF EXISTS partition_key;
