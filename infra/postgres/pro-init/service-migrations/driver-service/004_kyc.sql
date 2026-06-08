CREATE TABLE IF NOT EXISTS driver_kyc_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id char(8) NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'PENDING',
  full_name text,
  phone text,
  id_number text,
  license_number text,
  vehicle_registration_number text,
  id_front_url text,
  id_back_url text,
  license_front_url text,
  selfie_url text,
  rejection_reason text,
  reviewed_by char(8),
  reviewed_at timestamptz,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT driver_kyc_status_check CHECK (status IN ('NOT_SUBMITTED', 'PENDING', 'APPROVED', 'REJECTED'))
);

CREATE INDEX IF NOT EXISTS idx_driver_kyc_submissions_driver_id_submitted_at
  ON driver_kyc_submissions (driver_id, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_driver_kyc_submissions_status_submitted_at
  ON driver_kyc_submissions (status, submitted_at DESC);

DROP TRIGGER IF EXISTS set_updated_at_driver_kyc_submissions ON driver_kyc_submissions;
DROP TRIGGER IF EXISTS set_updated_at_driver_kyc_submissions ON driver_kyc_submissions;
CREATE TRIGGER set_updated_at_driver_kyc_submissions
BEFORE UPDATE ON driver_kyc_submissions
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
