# ride-service

ExpressJS microservice scaffold.
Contract: /contracts/openapi/ride-service.yaml

## Environment

- `MONGODB_URI` (default: `mongodb://mongo:27017/ride_service`)
- `MONGODB_DB` (optional database name override)
- `MONGODB_TRANSACTIONS` (set to `false` to disable transactions on standalone MongoDB)
- `REDIS_URL` (default: `redis://redis:6379`)

## Tests

All tests use mocks for DB/Redis and run locally with Node.

Run all tests:

```bash
npm test
```

Run unit tests:

```bash
npx jest test/rideStateMachine.test.js
npx jest test/auth.middleware.test.js
```

Run integration route tests (supertest + mocked repositories):

```bash
npx jest test/routes.integration.test.js
npx jest test/rides.idempotency.test.js
npx jest test/rides.transitions.test.js
```

Run contract tests against OpenAPI:

```bash
npx jest test/contract.test.js
```
