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

DO $$
DECLARE
  drivers_id_type text;
  has_kyc boolean;
BEGIN
  SELECT udt_name
  INTO drivers_id_type
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND table_name = 'drivers'
    AND column_name = 'id'
  LIMIT 1;

  has_kyc := EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = current_schema()
      AND table_name = 'driver_kyc_submissions'
  );

  IF drivers_id_type <> 'bpchar' THEN
    CREATE TEMP TABLE tmp_driver_id_map ON COMMIT DROP AS
    SELECT
      id::text AS old_id,
      CASE
        WHEN user_id::text ~ '^[0-9]{8}$' THEN user_id::text
        WHEN id::text ~ '^[0-9]{8}$' THEN id::text
        ELSE map_text_to_user8(user_id::text)::text
      END AS new_id,
      CASE
        WHEN user_id::text ~ '^[0-9]{8}$' THEN user_id::text
        ELSE map_text_to_user8(user_id::text)::text
      END AS new_user_id
    FROM drivers;

    ALTER TABLE drivers ADD COLUMN IF NOT EXISTS id_8 char(8);
    ALTER TABLE drivers ADD COLUMN IF NOT EXISTS user_id_8 char(8);
    ALTER TABLE driver_vehicles ADD COLUMN IF NOT EXISTS driver_id_8 char(8);
    ALTER TABLE driver_last_locations ADD COLUMN IF NOT EXISTS driver_id_8 char(8);
    IF has_kyc THEN
      ALTER TABLE driver_kyc_submissions ADD COLUMN IF NOT EXISTS driver_id_8 char(8);
    END IF;

    UPDATE drivers d
    SET id_8 = m.new_id::char(8),
        user_id_8 = m.new_user_id::char(8)
    FROM tmp_driver_id_map m
    WHERE d.id::text = m.old_id;

    UPDATE driver_vehicles v
    SET driver_id_8 = m.new_id::char(8)
    FROM tmp_driver_id_map m
    WHERE v.driver_id::text = m.old_id;

    UPDATE driver_last_locations l
    SET driver_id_8 = m.new_id::char(8)
    FROM tmp_driver_id_map m
    WHERE l.driver_id::text = m.old_id;

    IF has_kyc THEN
      UPDATE driver_kyc_submissions k
      SET driver_id_8 = m.new_id::char(8)
      FROM tmp_driver_id_map m
      WHERE k.driver_id::text = m.old_id;
    END IF;

    ALTER TABLE driver_vehicles DROP CONSTRAINT IF EXISTS driver_vehicles_driver_id_fkey;
    ALTER TABLE driver_last_locations DROP CONSTRAINT IF EXISTS driver_last_locations_driver_id_fkey;
    IF has_kyc THEN
      ALTER TABLE driver_kyc_submissions DROP CONSTRAINT IF EXISTS driver_kyc_submissions_driver_id_fkey;
    END IF;
    ALTER TABLE driver_last_locations DROP CONSTRAINT IF EXISTS driver_last_locations_pkey;
    ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_pkey;
    ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_user_id_key;

    ALTER TABLE drivers DROP COLUMN id;
    ALTER TABLE drivers DROP COLUMN user_id;
    ALTER TABLE drivers RENAME COLUMN id_8 TO id;
    ALTER TABLE drivers RENAME COLUMN user_id_8 TO user_id;

    ALTER TABLE driver_vehicles DROP COLUMN driver_id;
    ALTER TABLE driver_vehicles RENAME COLUMN driver_id_8 TO driver_id;

    ALTER TABLE driver_last_locations DROP COLUMN driver_id;
    ALTER TABLE driver_last_locations RENAME COLUMN driver_id_8 TO driver_id;

    IF has_kyc THEN
      ALTER TABLE driver_kyc_submissions DROP COLUMN driver_id;
      ALTER TABLE driver_kyc_submissions RENAME COLUMN driver_id_8 TO driver_id;
    END IF;
  END IF;

  ALTER TABLE drivers
    ALTER COLUMN id TYPE char(8) USING map_text_to_user8(id::text),
    ALTER COLUMN user_id TYPE char(8) USING map_text_to_user8(user_id::text);

  ALTER TABLE driver_vehicles
    ALTER COLUMN driver_id TYPE char(8) USING map_text_to_user8(driver_id::text);

  ALTER TABLE driver_last_locations
    ALTER COLUMN driver_id TYPE char(8) USING map_text_to_user8(driver_id::text);

  IF has_kyc THEN
    ALTER TABLE driver_kyc_submissions
      ALTER COLUMN driver_id TYPE char(8) USING map_text_to_user8(driver_id::text);
  END IF;

  ALTER TABLE drivers
    ALTER COLUMN id SET NOT NULL,
    ALTER COLUMN user_id SET NOT NULL;
  ALTER TABLE driver_vehicles
    ALTER COLUMN driver_id SET NOT NULL;
  ALTER TABLE driver_last_locations
    ALTER COLUMN driver_id SET NOT NULL;
  IF has_kyc THEN
    ALTER TABLE driver_kyc_submissions
      ALTER COLUMN driver_id SET NOT NULL;
  END IF;

  ALTER TABLE driver_vehicles DROP CONSTRAINT IF EXISTS driver_vehicles_driver_id_fkey;
  ALTER TABLE driver_last_locations DROP CONSTRAINT IF EXISTS driver_last_locations_driver_id_fkey;
  IF has_kyc THEN
    ALTER TABLE driver_kyc_submissions DROP CONSTRAINT IF EXISTS driver_kyc_submissions_driver_id_fkey;
  END IF;
  ALTER TABLE driver_last_locations DROP CONSTRAINT IF EXISTS driver_last_locations_pkey;
  ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_pkey;
  ALTER TABLE drivers DROP CONSTRAINT IF EXISTS drivers_user_id_key;

  ALTER TABLE drivers ADD CONSTRAINT drivers_pkey PRIMARY KEY (id);
  ALTER TABLE drivers ADD CONSTRAINT drivers_user_id_key UNIQUE (user_id);
  ALTER TABLE driver_last_locations ADD CONSTRAINT driver_last_locations_pkey PRIMARY KEY (driver_id);
  ALTER TABLE driver_vehicles
    ADD CONSTRAINT driver_vehicles_driver_id_fkey
    FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE;
  ALTER TABLE driver_last_locations
    ADD CONSTRAINT driver_last_locations_driver_id_fkey
    FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE;
  IF has_kyc THEN
    ALTER TABLE driver_kyc_submissions
      ADD CONSTRAINT driver_kyc_submissions_driver_id_fkey
      FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE CASCADE;
  END IF;
END $$;
