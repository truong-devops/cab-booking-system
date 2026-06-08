CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE SEQUENCE IF NOT EXISTS driver8_seq START 10000050;

CREATE TABLE IF NOT EXISTS drivers (
  id char(8) PRIMARY KEY DEFAULT LPAD(nextval('driver8_seq')::text,8,'0'),
  user_id char(8) NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'PENDING',
  online_status text NOT NULL DEFAULT 'OFFLINE',
  full_name text,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT drivers_status_check CHECK (status IN ('PENDING','APPROVED','SUSPENDED','DELETED')),
  CONSTRAINT drivers_online_status_check CHECK (online_status IN ('OFFLINE','ONLINE','BUSY'))
);

CREATE TABLE IF NOT EXISTS driver_vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id char(8) NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
  vehicle_type text NOT NULL,
  plate_number text NOT NULL,
  brand text,
  model text,
  color text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS driver_last_locations (
  driver_id char(8) PRIMARY KEY REFERENCES drivers(id) ON DELETE CASCADE,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  heading double precision,
  speed double precision,
  accuracy_m double precision,
  recorded_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_updated_at_drivers ON drivers;
CREATE TRIGGER set_updated_at_drivers
BEFORE UPDATE ON drivers
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_driver_vehicles ON driver_vehicles;
CREATE TRIGGER set_updated_at_driver_vehicles
BEFORE UPDATE ON driver_vehicles
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS set_updated_at_driver_last_locations ON driver_last_locations;
CREATE TRIGGER set_updated_at_driver_last_locations
BEFORE UPDATE ON driver_last_locations
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
