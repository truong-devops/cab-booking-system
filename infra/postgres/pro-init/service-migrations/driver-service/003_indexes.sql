CREATE INDEX IF NOT EXISTS idx_drivers_status ON drivers(status);
CREATE INDEX IF NOT EXISTS idx_drivers_online_status ON drivers(online_status);
CREATE INDEX IF NOT EXISTS idx_driver_vehicles_driver_id ON driver_vehicles(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_vehicles_plate_number ON driver_vehicles(plate_number);
CREATE INDEX IF NOT EXISTS idx_driver_last_locations_recorded_at ON driver_last_locations(recorded_at);
