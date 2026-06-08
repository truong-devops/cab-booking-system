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

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'driver_kyc_submissions'
      AND column_name = 'reviewed_by'
  ) THEN
    ALTER TABLE driver_kyc_submissions
      ALTER COLUMN reviewed_by TYPE char(8)
      USING map_text_to_user8(reviewed_by::text);
  END IF;
END $$;

DROP FUNCTION IF EXISTS map_text_to_user8(text);

-- migrate:down
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'driver_kyc_submissions'
      AND column_name = 'reviewed_by'
  ) THEN
    ALTER TABLE driver_kyc_submissions
      ALTER COLUMN reviewed_by TYPE text
      USING reviewed_by::text;
  END IF;
END $$;
