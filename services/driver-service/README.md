# driver-service

Driver service (PostgreSQL + Redis, no Kafka). Internal only (via api-gateway).
Contract: /contracts/openapi/driver-service.yaml

## Environment

- PORT (default: 3011)
- DATABASE_URL (required)
- REDIS_URL (default: redis://redis:6379)
- AUTH_JWT_SECRET or AUTH_PUBLIC_KEY (JWT verification)
- LOCATION_TTL_SECONDS (default: 180)
- ONLINE_TTL_SECONDS (default: 300)
- MAX_LOCATION_RATE_PER_SEC (default: 1)
- DEFAULT_SEARCH_RADIUS_METERS (default: 3000)
- AVAILABLE_LIMIT_DEFAULT (default: 20)
- FORCE_OFFLINE_WHEN_BUSY (default: false)

## Run locally

Use `http://localhost:42100` through the API Gateway for normal driver APIs. The direct `42110` port below is only for standalone local debugging.

```bash
npm install
PORT=42110 \
DATABASE_URL=postgres://cab:cabpass@localhost:42130/driver-service_db \
REDIS_URL=redis://localhost:42131 \
AUTH_JWT_SECRET=dev-secret \
npm start
```

## Migrations

```bash
psql "$DATABASE_URL" -f services/driver-service/migrations/001_enable_extensions.sql
psql "$DATABASE_URL" -f services/driver-service/migrations/002_init_schema.sql
psql "$DATABASE_URL" -f services/driver-service/migrations/003_indexes.sql
```

## API (via api-gateway)

- Driver app:
  - GET /v1/driver/me
  - PUT /v1/driver/me
  - PUT /v1/driver/me/vehicle
  - POST /v1/driver/me/online
  - POST /v1/driver/me/offline
  - POST /v1/driver/me/location
  - POST /v1/driver/me/heartbeat
- Internal:
  - GET /v1/internal/drivers/available
  - GET /v1/internal/drivers/{driverId}
  - GET /v1/internal/drivers/{driverId}/location
  - POST /v1/internal/drivers/{driverId}/mark-busy
  - POST /v1/internal/drivers/{driverId}/mark-available
  - POST /v1/internal/drivers/bulk
- Admin:
  - POST /v1/admin/drivers
  - PATCH /v1/admin/drivers/{driverId}/approve
  - PATCH /v1/admin/drivers/{driverId}/suspend
  - GET /v1/admin/drivers

## Curl examples

### Driver online

```bash
curl -s -X POST http://localhost:42100/v1/driver/me/online \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"d1"}'
```

### Update location

```bash
curl -s -X POST http://localhost:42100/v1/driver/me/location \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"lat":10.76,"lng":106.66}'
```

### Available drivers (internal)

```bash
curl -s "http://localhost:42100/v1/internal/drivers/available?lat=10.76&lng=106.66&radiusMeters=3000&limit=10" \
  -H "Authorization: Bearer $SERVICE_TOKEN"
```

### Mark busy / available

```bash
curl -s -X POST http://localhost:42100/v1/internal/drivers/{driverId}/mark-busy \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"rideId":"ride_123"}'

curl -s -X POST http://localhost:42100/v1/internal/drivers/{driverId}/mark-available \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"rideId":"ride_123"}'
```
