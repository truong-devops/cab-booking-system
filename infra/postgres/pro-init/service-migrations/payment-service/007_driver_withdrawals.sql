-- migrate:up
CREATE TABLE IF NOT EXISTS driver_withdrawals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_user_id char(8) NOT NULL,
  amount numeric(12, 2) NOT NULL,
  currency char(3) NOT NULL DEFAULT 'VND',
  status text NOT NULL DEFAULT 'REQUESTED',
  note text,
  rejection_reason text,
  requested_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  processed_by char(8),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT driver_withdrawals_amount_positive CHECK (amount > 0),
  CONSTRAINT driver_withdrawals_currency_length CHECK (char_length(currency) = 3),
  CONSTRAINT driver_withdrawals_status_check CHECK (status IN ('REQUESTED', 'APPROVED', 'REJECTED', 'PAID', 'FAILED', 'CANCELED'))
);

CREATE INDEX IF NOT EXISTS driver_withdrawals_driver_requested_idx
  ON driver_withdrawals (driver_user_id, requested_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS driver_withdrawals_status_requested_idx
  ON driver_withdrawals (status, requested_at DESC, id DESC);

-- migrate:down
DROP INDEX IF EXISTS driver_withdrawals_status_requested_idx;
DROP INDEX IF EXISTS driver_withdrawals_driver_requested_idx;
DROP TABLE IF EXISTS driver_withdrawals;
