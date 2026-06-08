-- migrate:up
CREATE TABLE IF NOT EXISTS payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id text NOT NULL,
  user_id char(8),
  amount numeric(12, 2) NOT NULL,
  currency char(3) NOT NULL,
  method text,
  status text NOT NULL,
  status_updated_at timestamptz NOT NULL DEFAULT now(),
  failure_reason text,
  vietqr_payload text,
  vietqr_reference text,
  vietqr_expires_at timestamptz,
  vietqr_qr_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_amount_positive CHECK (amount > 0),
  CONSTRAINT payments_currency_length CHECK (char_length(currency) = 3),
  CONSTRAINT payments_status_check CHECK (
    status IN ('INITIATED', 'PROCESSING', 'PAID', 'FAILED', 'REFUNDED')
  )
);

CREATE TABLE IF NOT EXISTS payment_status_history (
  id bigserial PRIMARY KEY,
  payment_id uuid NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
  from_status text,
  to_status text NOT NULL,
  reason text,
  actor_id char(8),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  trace_id text,
  CONSTRAINT payment_status_history_from_check CHECK (
    from_status IS NULL OR from_status IN ('INITIATED', 'PROCESSING', 'PAID', 'FAILED', 'REFUNDED')
  ),
  CONSTRAINT payment_status_history_to_check CHECK (
    to_status IN ('INITIATED', 'PROCESSING', 'PAID', 'FAILED', 'REFUNDED')
  )
);

-- migrate:down
DROP TABLE IF EXISTS payment_status_history;
DROP TABLE IF EXISTS payments;
