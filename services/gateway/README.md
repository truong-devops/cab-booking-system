# Go Gateway (Parallel with api-gateway)

This service is a Go implementation of the API gateway for high-load tests.

## Run with docker compose

```bash
docker compose -f infra/docker-compose.dev.yml up -d gateway
```

- Existing Node gateway: `http://localhost:3000`
- New Go gateway: `http://localhost:3008`

## Use with case63 (k6)

```bash
BASE_URL=http://localhost:3008 \
K6_BASE_URL=http://host.docker.internal:3008 \
scripts/postman-truong/testcase-truong-hop-2/case63.sh
```

## Compatibility implemented

- Health routes: `/health`, `/healthz`, `/readyz`
- Public webhook route: `/webhooks/payos`
- Domain proxy routes: `/v1/:domain` and `/v1/:domain/*`
- Local route: `POST /v1/fraud/check`
- JWT auth (local verify), optional auth-service verify cache
- Route mapping parity:
  - `/v1/auth/*` -> auth service `/auth/*`
  - `/v1/auth/health|healthz|readyz` -> auth service root health routes
  - `/v1/notifications/users/*` -> notification service `/v1/users/*`

