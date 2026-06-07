# auth-service

Auth microservice using Express + PostgreSQL.

## Features

- Register / Login / Refresh / Logout
- JWT access token + refresh token
- Bcrypt password hashing
- Basic role support (user/admin/ops/driver)
- Token verification endpoint for API Gateway

## Environment

- `PORT` (default: 4001)
- `DATABASE_URL` (required)
- `JWT_SECRET` (required)
- `JWT_EXPIRES_IN` (default: `15m`)
- `REFRESH_TOKEN_TTL_DAYS` (default: `7`)
- `BCRYPT_ROUNDS` (default: `10`)
- `AUTH_ROLES` (default: `user,admin,ops,driver`)
- `AUTH_PUBLIC_REGISTER_ROLES` (default: `user,driver`; do not include `admin` or `ops` in shared environments)
- `DEV_MAGIC_PASSWORD` (optional local-only login bypass; disabled in `NODE_ENV=production` and disabled by default)

## Database

Run schema:

```bash
psql "$DATABASE_URL" -f ./migrations/001_init.sql
```

## Run locally

Use the API Gateway at `http://localhost:42100` for normal app/API flows. The command below runs auth-service directly for standalone debugging.

```bash
npm install
DATABASE_URL=postgres://cab:cabpass@localhost:42130/auth-service_db \
JWT_SECRET=dev-secret \
npm start
```

## Docker

This direct host port is for local debugging only; deployment should keep auth-service internal on port `4001`.

```bash
docker build -t auth-service .
docker run -p 42102:4001 \
  -e PORT=4001 \
  -e DATABASE_URL=postgres://cab:cabpass@host.docker.internal:42130/auth-service_db \
  -e JWT_SECRET=dev-secret \
  auth-service
```

## API

- POST `/auth/register`
- POST `/auth/login`
- POST `/auth/refresh`
- POST `/auth/logout`
- GET `/auth/verify`

Example payloads:

```json
// register
{ "email": "user@example.com", "password": "secret123", "role": "user" }
```

```json
// login
{ "identifier": "user@example.com", "password": "secret123" }
```

```json
// refresh
{ "refreshToken": "<token>" }
```
