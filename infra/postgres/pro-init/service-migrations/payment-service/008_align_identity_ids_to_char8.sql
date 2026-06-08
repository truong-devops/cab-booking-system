-- migrate:up
CREATE OR REPLACE FUNCTION map_text_to_user8(value text)
RETURNS char(8)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN value IS NULL THEN NULL::char(8)
      WHEN btrim(value) ~ '^[0-9]{8}$' THEN btrim(value)::char(8)
      WHEN btrim(value) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN right(regexp_replace(lower(btrim(value)), '[^0-9]', '', 'g'), 8)::char(8)
      ELSE NULL::char(8)
    END
$$;

ALTER TABLE payments
  ALTER COLUMN user_id TYPE char(8)
  USING map_text_to_user8(user_id::text);

ALTER TABLE payment_status_history
  ALTER COLUMN actor_id TYPE char(8)
  USING map_text_to_user8(actor_id::text);

DELETE FROM idempotency_keys
WHERE map_text_to_user8(user_id::text) IS NULL;

ALTER TABLE idempotency_keys
  ALTER COLUMN user_id TYPE char(8)
  USING map_text_to_user8(user_id::text),
  ALTER COLUMN user_id SET NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'driver_withdrawals'
  ) THEN
    DELETE FROM driver_withdrawals
    WHERE map_text_to_user8(driver_user_id::text) IS NULL;

    ALTER TABLE driver_withdrawals
      ALTER COLUMN driver_user_id TYPE char(8)
      USING map_text_to_user8(driver_user_id::text),
      ALTER COLUMN driver_user_id SET NOT NULL,
      ALTER COLUMN processed_by TYPE char(8)
      USING map_text_to_user8(processed_by::text);
  END IF;
END $$;

DROP FUNCTION IF EXISTS map_text_to_user8(text);

-- migrate:down
ALTER TABLE idempotency_keys
  ALTER COLUMN user_id TYPE text
  USING user_id::text;

ALTER TABLE payment_status_history
  ALTER COLUMN actor_id TYPE text
  USING actor_id::text;

ALTER TABLE payments
  ALTER COLUMN user_id TYPE text
  USING user_id::text;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'driver_withdrawals'
  ) THEN
    ALTER TABLE driver_withdrawals
      ALTER COLUMN driver_user_id TYPE text
      USING driver_user_id::text,
      ALTER COLUMN processed_by TYPE text
      USING processed_by::text;
  END IF;
END $$;
