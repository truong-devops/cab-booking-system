# api-gateway

ExpressJS microservice scaffold.
Contract: /contracts/openapi/api-gateway.yaml

## Environment

- `PORT` (default: 3000)
- `JWT_SECRET` (required for protected routes)
- `JWT_ALGORITHMS` (default: `HS256`)
- `AUTH_PUBLIC_DOMAINS` (default: `auth`)
- `AUTH_PUBLIC_PATHS` (default: `/health,/healthz,/readyz`)
- `RATE_LIMIT_WINDOW_MS` (default: 60000)
- `RATE_LIMIT_MAX` (default: 100)
- `PROXY_TIMEOUT_MS` (default: 3000)
- `PROXY_RETRY_BACKOFF_MS` (default: 100)
- `RIDE_SERVICE_URL`, `USER_SERVICE_URL`, `DRIVER_SERVICE_URL`,
  `BOOKING_SERVICE_URL`, `PRICING_SERVICE_URL`, `PAYMENT_SERVICE_URL`,
  `REVIEW_SERVICE_URL`, `AUTH_SERVICE_URL`, `NOTIFICATION_SERVICE_URL`

## Docker

Build + run:

The host mapping below publishes the gateway itself. Downstream service URLs should point to internal service DNS in compose/deploy, or to direct `421xx` debug ports only when running gateway standalone from the host.

```bash
docker build -t api-gateway .
docker run -p 42100:3000 \
  -e PORT=3000 \
  -e JWT_SECRET=your-secret \
  -e RIDE_SERVICE_URL=http://host.docker.internal:42105 \
  api-gateway
```
