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

ALTER TABLE bookings
  ALTER COLUMN user_id TYPE char(8)
  USING map_text_to_user8(user_id::text);

DELETE FROM idempotency_keys
WHERE map_text_to_user8(user_id::text) IS NULL;

ALTER TABLE idempotency_keys
  ALTER COLUMN user_id TYPE char(8)
  USING map_text_to_user8(user_id::text),
  ALTER COLUMN user_id SET NOT NULL;

DROP INDEX IF EXISTS bookings_one_active_per_user_idx;
CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_per_user_idx
  ON bookings (user_id)
  WHERE user_id IS NOT NULL
    AND status IN ('PENDING', 'REQUESTED', 'ACCEPTED', 'CONFIRMED');

DROP FUNCTION IF EXISTS map_text_to_user8(text);

-- migrate:down
ALTER TABLE idempotency_keys
  ALTER COLUMN user_id TYPE text
  USING user_id::text;

ALTER TABLE bookings
  ALTER COLUMN user_id TYPE text
  USING user_id::text;

DROP INDEX IF EXISTS bookings_one_active_per_user_idx;
CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_per_user_idx
  ON bookings (user_id)
  WHERE user_id IS NOT NULL
    AND status IN ('PENDING', 'REQUESTED', 'ACCEPTED', 'CONFIRMED');
