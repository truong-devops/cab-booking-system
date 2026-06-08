CREATE OR REPLACE FUNCTION map_text_to_user8(input_value text)
RETURNS char(8) AS $$
DECLARE
  normalized text;
  hash_seed bigint;
BEGIN
  IF input_value IS NULL THEN
    RETURN NULL;
  END IF;

  normalized := btrim(input_value);
  IF normalized = '' THEN
    RETURN NULL;
  END IF;

  IF normalized ~ '^[0-9]{8}$' THEN
    RETURN normalized::char(8);
  END IF;

  IF normalized ~ '^00000000-0000-0000-0000-0*[0-9]{8}$' THEN
    RETURN substring(normalized FROM '([0-9]{8})$')::char(8);
  END IF;

  hash_seed := (('x' || substr(md5(normalized), 1, 8))::bit(32)::bigint % 90000000) + 10000000;
  RETURN lpad(hash_seed::text, 8, '0')::char(8);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

ALTER TABLE reviews
  ALTER COLUMN ride_id TYPE text
  USING ride_id::text;

ALTER TABLE reviews
  ALTER COLUMN rider_id TYPE char(8)
  USING map_text_to_user8(rider_id::text);

ALTER TABLE reviews
  ALTER COLUMN driver_id TYPE char(8)
  USING map_text_to_user8(driver_id::text);

ALTER TABLE reviews_status_history
  ALTER COLUMN actor_id TYPE char(8)
  USING map_text_to_user8(actor_id::text);

ALTER TABLE idempotency_keys
  ALTER COLUMN user_id TYPE char(8)
  USING map_text_to_user8(user_id::text);
