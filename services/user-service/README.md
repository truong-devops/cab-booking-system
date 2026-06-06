# user-service

User management microservice for cab-booking-system.

## Features

- RESTful endpoints for user CRUD
- Role-based access (admin/customer/driver) via gateway headers
- PostgreSQL storage + outbox_events for publish-later
- Internal lookup endpoints protected by `x-internal-key`
- Structured logging + trace id

## Environment

- `PORT` (default: 4004)
- `DATABASE_URL` (required)
- `INTERNAL_API_KEY` (required for internal endpoints)
- `LOG_LEVEL` (default: info)

## Migrations

Run in order:

```
psql "$DATABASE_URL" -f migrations/001_enable_extensions.sql
psql "$DATABASE_URL" -f migrations/002_init_schema.sql
psql "$DATABASE_URL" -f migrations/003_indexes.sql
```

## Run (local)

```
npm install
DATABASE_URL=postgres://user:pass@localhost:42130/user_service_db \
INTERNAL_API_KEY=dev-internal-key \
npm start
```

## Endpoints

Auth headers (from API Gateway):

- `x-user-id`
- `x-user-role` (admin/customer/driver)

### Public

- `GET /healthz`

### Users (requires auth)

- `POST /v1/users` (admin only)
- `GET /v1/users/:id` (admin or self)
- `GET /v1/users?email=&role=&status=&limit=&cursor=` (admin only)
- `PATCH /v1/users/:id` (admin or self; only admin can change role/status)
- `DELETE /v1/users/:id` (admin only, soft delete)

### Internal (requires `x-internal-key`)

- `GET /internal/users/:id`
- `GET /internal/users/by-email/:email`

## Event Outbox

User events are recorded in `outbox_events` with types:

- `user.created`
- `user.updated`

This can be published later by a Kafka/RabbitMQ worker.
