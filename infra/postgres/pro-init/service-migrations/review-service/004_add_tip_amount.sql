ALTER TABLE reviews
ADD COLUMN IF NOT EXISTS tip_amount integer;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'reviews_tip_amount_check'
  ) THEN
    ALTER TABLE reviews
    ADD CONSTRAINT reviews_tip_amount_check CHECK (tip_amount IS NULL OR tip_amount >= 0);
  END IF;
END $$;
