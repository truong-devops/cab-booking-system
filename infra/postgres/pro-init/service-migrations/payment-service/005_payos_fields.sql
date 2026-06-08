-- migrate:up
ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS payos_order_code bigint,
  ADD COLUMN IF NOT EXISTS payos_payment_link_id text,
  ADD COLUMN IF NOT EXISTS payos_checkout_url text,
  ADD COLUMN IF NOT EXISTS payos_qr_code text;

CREATE UNIQUE INDEX IF NOT EXISTS payments_payos_order_code_uidx
  ON payments (payos_order_code)
  WHERE payos_order_code IS NOT NULL;

-- migrate:down
DROP INDEX IF EXISTS payments_payos_order_code_uidx;

ALTER TABLE payments
  DROP COLUMN IF EXISTS payos_qr_code,
  DROP COLUMN IF EXISTS payos_checkout_url,
  DROP COLUMN IF EXISTS payos_payment_link_id,
  DROP COLUMN IF EXISTS payos_order_code;
