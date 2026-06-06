function toPositiveInt(raw, fallback) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return Math.floor(value);
}

const config = {
  port: toPositiveInt(process.env.PORT, 3014),
  databaseUrl: process.env.DATABASE_URL || 'postgres://cab:cabpass@postgres:5432/places-service_db',
  placesProviderEnabled: String(process.env.PLACES_PROVIDER_ENABLED || 'true').toLowerCase() !== 'false',
  placesProviderBaseUrl: process.env.PLACES_PROVIDER_BASE_URL || 'https://nominatim.openstreetmap.org',
  placesProviderTimeoutMs: toPositiveInt(process.env.PLACES_PROVIDER_TIMEOUT_MS, 1800),
  placesProviderCountryCodes: process.env.PLACES_PROVIDER_COUNTRY_CODES || 'vn',
  placesProviderUserAgent: process.env.PLACES_PROVIDER_USER_AGENT || 'cab-booking-system/places-service',
  defaultResultLimit: toPositiveInt(process.env.PLACES_DEFAULT_LIMIT, 8),
  maxResultLimit: toPositiveInt(process.env.PLACES_MAX_LIMIT, 20),
  maxRecentPerUser: toPositiveInt(process.env.PLACES_RECENT_MAX_PER_USER, 20)
};

module.exports = { config, toPositiveInt };
