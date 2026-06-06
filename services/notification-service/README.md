# notification-service

ExpressJS microservice for notifications (REST + MongoDB).
Contract: /contracts/openapi/notification-service.yaml

## Features

- REST API for other services to send notifications
- MongoDB persistence with idempotency (dedupeKey)
- Async dispatch + retry (no Kafka)
- JWT verify + RBAC (service/admin/user)
- User lookup via user-service (internal API key)
- Trace/request/correlation id propagation

## Environment

- `PORT` (default: 3010)
- `SERVICE_NAME` (default: notification-service)

### Auth

- `AUTH_JWT_SECRET` (HS256) or `AUTH_PUBLIC_KEY` (RS256)
  - Fallback: `JWT_SECRET`

### MongoDB

- `MONGODB_URI` (default: mongodb://mongo:27017/notification_service)
- `MONGODB_DB` (optional override)

### User-service integration

- `USER_SERVICE_BASE_URL` (default: http://user-service:4004)
- `INTERNAL_API_KEY` (required to call /internal/users/:id)
- `USER_SERVICE_TIMEOUT_MS` (default: 2000)
- `USER_SERVICE_RETRY` (default: 1)
- `USER_CACHE_TTL_MS` (default: 300000)

### Dispatcher

- `NOTIFICATION_DISPATCH_INTERVAL_MS` (default: 1000)
- `NOTIFICATION_DISPATCH_BATCH_SIZE` (default: 10)
- `NOTIFICATION_MAX_ATTEMPTS` (default: 5)
- `NOTIFICATION_RETRY_BASE_MS` (default: 1000)
- `NOTIFICATION_RESPECT_PREFERENCES` (default: true)

## Run locally

Use `http://localhost:42100` through the API Gateway for normal notification APIs. The direct `42109` port below is only for standalone local debugging.

```bash
npm install
PORT=42109 \
MONGODB_URI=mongodb://localhost:42132/notification_service \
AUTH_JWT_SECRET=dev-secret \
USER_SERVICE_BASE_URL=http://localhost:42103 \
INTERNAL_API_KEY=dev-internal-key \
npm start
```

## API

### Health

- `GET /healthz`
- `GET /readyz`

### Service-to-service (role: service/admin)

- `POST /v1/notifications`
- `POST /v1/notifications/batch`
- `POST /v1/notifications/:id/retry`
- `PATCH /v1/notifications/:id/cancel`
- `GET /v1/notifications/:id` (service/admin or owner)

### User APIs

- `GET /v1/users/:userId/notifications`
- `GET /v1/users/:userId/preferences`
- `PUT /v1/users/:userId/preferences`

## Payload rules

- **Template mode**: `templateKey` + `data`
- **Raw mode**: `title`/`body` + `data`
- If `recipient` missing, service will call user-service to resolve contacts.
- If user.status != ACTIVE: EMAIL/SMS/PUSH are blocked, IN_APP still created.
- Idempotency:
  - If `dedupeKey` provided -> unique by dedupeKey
  - Else auto-generate from sourceService/action/user/channels/template or title/body

## Example requests

### Ride-service: RIDE_ASSIGNED (PUSH + IN_APP)

```bash
curl -X POST http://localhost:42109/v1/notifications \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{
    "sourceService":"ride-service",
    "sourceAction":"RIDE_ASSIGNED",
    "sourceRef":{"rideId":"r123","driverId":"d9"},
    "userId":"u_customer_1",
    "channels":["PUSH","IN_APP"],
    "templateKey":"RIDE_ASSIGNED",
    "data":{"rideId":"r123","driverName":"An","etaSec":240},
    "dedupeKey":"ride-assigned:r123:u_customer_1"
  }'
```

### Payment-service: PAYMENT_FAILED (SMS + IN_APP)

```bash
curl -X POST http://localhost:42109/v1/notifications \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{
    "sourceService":"payment-service",
    "sourceAction":"PAYMENT_FAILED",
    "sourceRef":{"paymentId":"p777","rideId":"r123"},
    "userId":"u_customer_1",
    "channels":["SMS","IN_APP"],
    "title":"Thanh toán thất bại",
    "body":"Thanh toán cho chuyến r123 thất bại. Vui lòng thử lại.",
    "data":{"paymentId":"p777","reason":"INSUFFICIENT_FUNDS"},
    "dedupeKey":"payment-failed:p777:u_customer_1"
  }'
```

### Batch send

```bash
curl -X POST http://localhost:42109/v1/notifications/batch \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{
    "items": [
      {
        "sourceService":"booking-service",
        "sourceAction":"BOOKING_CREATED",
        "sourceRef":{"bookingId":"b1"},
        "userId":"u_customer_1",
        "channels":["IN_APP"],
        "title":"Đặt xe thành công",
        "body":"Bạn đã đặt xe b1"
      },
      {
        "sourceService":"driver-service",
        "sourceAction":"DRIVER_APPROVED",
        "sourceRef":{"driverId":"d9"},
        "userId":"u_driver_9",
        "channels":["EMAIL"],
        "title":"Tài khoản tài xế đã được duyệt"
      }
    ]
  }'
```

### User notifications

```bash
curl -X GET "http://localhost:42109/v1/users/u_customer_1/notifications?status=PENDING&limit=20" \
  -H "Authorization: Bearer <JWT>"
```

### Preferences

```bash
curl -X PUT http://localhost:42109/v1/users/u_customer_1/preferences \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{"channels":{"EMAIL":false,"SMS":false,"PUSH":true,"IN_APP":true}}'
```
