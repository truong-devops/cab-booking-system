# pricing-service

Internal pricing service for fare quotes.
Contract: /contracts/openapi/pricing-service.yaml

## Routes (via API Gateway)

- POST /v1/pricing/quotes
- GET /v1/pricing/quotes/{quoteId}
- POST /v1/pricing/finalize

Note: This service is internal. Do not expose a public port. Route traffic through api-gateway.

## Environment

- PORT (default: 3006)
- REDIS_URL (default: redis://redis:6379)
- JWT_SECRET (required if validating bearer tokens)
- INTERNAL_API_KEY (optional, for service-to-service calls via x-internal-key)
- QUOTE_TTL_SEC (default: 300)
- AVERAGE_SPEED_KMH (default: 25)
- RATES_JSON (optional rate overrides)
- RATE_CACHE_TTL_SEC (default: 900)
- COUPON_DISCOUNTS_JSON (optional coupon map)

Example overrides:

- RATES_JSON='{"STANDARD":{"currency":"VND","baseFare":12000,"perKmRate":5000,"perMinRate":500,"surgeMultiplier":1.0,"averageSpeedKmh":25}}'
- COUPON_DISCOUNTS_JSON='{"WELCOME10":10000}'

## Local run

Use `http://localhost:42100` through the API Gateway for normal pricing APIs. Direct service execution is only for local debugging.

```bash
cd services/pricing-service
npm install
JWT_SECRET=dev-secret REDIS_URL=redis://localhost:42131 node src/server.js
```

Health endpoints:

- GET /health
- GET /ready (checks Redis)
