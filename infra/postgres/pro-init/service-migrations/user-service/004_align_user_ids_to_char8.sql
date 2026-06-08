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

  hash_seed := (('x' || substr(md5(normalized), 1, 8))::bit(32)::bigint % 90000000) + 10000000;
  RETURN lpad(hash_seed::text, 8, '0')::char(8);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

DO $$
DECLARE
  users_id_type text;
BEGIN
  SELECT udt_name
  INTO users_id_type
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND table_name = 'users'
    AND column_name = 'id'
  LIMIT 1;

  IF users_id_type <> 'bpchar' THEN
    CREATE TEMP TABLE tmp_user_id_map ON COMMIT DROP AS
    SELECT id::text AS old_id, map_text_to_user8(id::text)::text AS new_id
    FROM users;

    ALTER TABLE users ADD COLUMN IF NOT EXISTS id_8 char(8);
    ALTER TABLE outbox_events ADD COLUMN IF NOT EXISTS aggregate_id_8 char(8);

    UPDATE users u
    SET id_8 = m.new_id::char(8)
    FROM tmp_user_id_map m
    WHERE u.id::text = m.old_id;

    UPDATE outbox_events o
    SET aggregate_id_8 = m.new_id::char(8)
    FROM tmp_user_id_map m
    WHERE o.aggregate_type = 'user'
      AND o.aggregate_id::text = m.old_id;

    ALTER TABLE users DROP CONSTRAINT IF EXISTS users_pkey;
    ALTER TABLE users DROP COLUMN id;
    ALTER TABLE users RENAME COLUMN id_8 TO id;

    ALTER TABLE outbox_events DROP COLUMN aggregate_id;
    ALTER TABLE outbox_events RENAME COLUMN aggregate_id_8 TO aggregate_id;
  END IF;

  ALTER TABLE users
    ALTER COLUMN id TYPE char(8) USING map_text_to_user8(id::text),
    ALTER COLUMN id SET NOT NULL;

  ALTER TABLE outbox_events
    ALTER COLUMN aggregate_id TYPE char(8) USING map_text_to_user8(aggregate_id::text);

  ALTER TABLE users DROP CONSTRAINT IF EXISTS users_pkey;
  ALTER TABLE users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
END $$;
