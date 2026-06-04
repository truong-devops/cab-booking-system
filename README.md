<div align="center">

# Cab Booking System

**A microservices-based ride-hailing platform with event-driven workflows, polyglot persistence, and end-to-end observability.**

[![Node.js](https://img.shields.io/badge/Node.js-20%2B-339933?logo=nodedotjs)](https://nodejs.org/)
[![Go](https://img.shields.io/badge/Go-Gateway-00ADD8?logo=go)](https://go.dev/)
[![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)](https://docs.docker.com/compose/)
[![Apache Kafka](https://img.shields.io/badge/Apache_Kafka-7.6-231F20?logo=apachekafka)](https://kafka.apache.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql)](https://www.postgresql.org/)
[![MongoDB](https://img.shields.io/badge/MongoDB-7-47A248?logo=mongodb)](https://www.mongodb.com/)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D?logo=redis)](https://redis.io/)

</div>

## Overview

Cab Booking System is a reference implementation of a ride-hailing platform organized as an npm-workspaces monorepo. It contains customer, driver, and operations applications; domain-oriented backend services; REST and event contracts; Docker Compose infrastructure; and a complete local observability stack.

The system demonstrates:

- Ride booking, driver management, ride lifecycle, pricing, payment, notification, and review domains.
- Synchronous service communication over HTTP through an API Gateway.
- Asynchronous business workflows over Apache Kafka.
- Database-per-service ownership using PostgreSQL, MongoDB, and Redis.
- Transactional outbox, inbox deduplication, idempotency, retries, compensation, and dead-letter topics.
- OpenAPI and JSON Schema contracts as shared integration boundaries.
- Centralized logs, metrics, traces, dashboards, and alerts.

> **Project status:** this repository is suitable for local development, architecture demonstrations, automated testing, and production-like experiments. The supplied Compose files are single-host deployments and require the hardening steps described in [Production Deployment](#production-deployment) before being used in a real production environment.

## Architecture

![Cab Booking System architecture][system-architecture-diagram]

### Architectural Principles

| Principle                  | Implementation                                                                                                              |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Single entry point         | Clients call the API Gateway, which validates authentication, applies rate limits, and proxies requests to domain services. |
| Domain ownership           | Each service owns its business logic and data. Services do not share application tables.                                    |
| Hybrid communication       | HTTP is used for request-response operations; Kafka is used for distributed state propagation and compensation workflows.   |
| Contract-first integration | REST contracts live in `contracts/openapi`; event envelopes and payload schemas live in `contracts/events`.                 |
| Reliable event processing  | Booking, ride, and payment workflows use outbox/inbox patterns, idempotency, retry policies, and DLQ routing.               |
| Observable by default      | Services expose structured logs and telemetry that can be collected by ELK, OpenTelemetry, Prometheus, Tempo, and Grafana.  |

### Gateway Implementations

The repository contains two gateway implementations:

- `services/gateway`: Go gateway used by `infra/docker-compose.dev.yml` for local and load-test workloads.
- `services/api-gateway`: Node.js/Express gateway used by `infra/docker-compose.pro.yml` and available for feature-parity development.

Both expose the gateway on HTTP port `3000` and development HTTPS port `3443`.

## Components

### Backend Services

The **Host access** column reflects the default local stack in `infra/docker-compose.dev.yml`. Services without a published host port remain reachable inside the Docker `backend` network through the API Gateway.

| Service                |  Internal port | Host access    | Data store               | Responsibility                                                                                                  |
| ---------------------- | -------------: | -------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `api-gateway`          | `3000`, `3443` | `3000`, `3443` | None                     | Authentication enforcement, routing, rate limiting, retry, and circuit breaking.                                |
| `auth-service`         |         `4001` | Gateway only   | PostgreSQL               | Registration, login, access tokens, refresh tokens, logout, and token verification.                             |
| `user-service`         |         `4004` | Gateway only   | PostgreSQL               | User profiles, roles, statuses, and internal user lookup.                                                       |
| `driver-service`       |         `3011` | `3011`         | PostgreSQL, Redis        | Driver profiles, vehicles, availability, heartbeat, and location/geo state.                                     |
| `booking-service`      |         `3003` | `3003`         | PostgreSQL, Kafka        | Booking lifecycle, price snapshot, driver-selection workflow, payment initialization, and booking outbox/inbox. |
| `ride-service`         |         `3005` | Gateway only   | MongoDB, Redis, Kafka    | Ride state machine, assignment, ride event processing, and ride outbox/inbox.                                   |
| `pricing-service`      |         `3006` | `3006`         | Redis                    | Fare quotes, rate rules, surge configuration, coupons, and quote finalization.                                  |
| `payment-service`      |         `3007` | `3007`         | PostgreSQL, Redis, Kafka | Payment lifecycle, VietQR/PayOS integration, wallet/withdrawals, and payment events.                            |
| `notification-service` |         `3010` | Gateway only   | MongoDB                  | Notification persistence, preferences, dispatch, deduplication, and retry.                                      |
| `review-service`       |         `3009` | Gateway only   | PostgreSQL, Redis        | Ratings, comments, tips, moderation states, and idempotency.                                                    |
| `eta-service`          |         `3012` | `3012`         | None                     | ETA estimation.                                                                                                 |
| `places-service`       |         `3014` | `3014`         | PostgreSQL               | Place search, recent places, and optional Nominatim integration.                                                |
| `ai-service`           |         `3013` | `3013`         | In-memory/config         | Driver recommendation, fraud scoring, demand forecasting, drift checks, and agent decisions.                    |

### Client Applications

| Application            | Technology                | Purpose                                                                                          |
| ---------------------- | ------------------------- | ------------------------------------------------------------------------------------------------ |
| `apps/customer-app`    | React Native, Expo        | Search, quote, booking, ride tracking, payment, history, profile, and reviews.                   |
| `apps/driver-app`      | React Native, Expo Router | Driver availability, incoming requests, ride execution, location updates, earnings, and profile. |
| `apps/admin-dashboard` | React, Vite               | Operations dashboards, user/driver/ride/payment management, pricing tools, logs, and monitoring. |

### Data Ownership

| Store      | Owning domains                                       | Primary use                                                                 |
| ---------- | ---------------------------------------------------- | --------------------------------------------------------------------------- |
| PostgreSQL | Auth, user, driver, booking, payment, review, places | Transactional relational data and service-owned outbox/inbox tables.        |
| MongoDB    | Ride, notification                                   | Ride documents, state history, event processing records, and notifications. |
| Redis      | Driver, ride, pricing, payment, review               | Driver geo/presence, caching, quote storage, locks, and idempotency.        |
| Kafka      | Booking, ride, payment                               | Distributed workflow events, retry topics, and dead-letter topics.          |

## Core Workflows

### Booking and Ride Creation

![Booking and ride creation workflow][booking-workflow-diagram]

The booking service owns the booking record and immutable price snapshot. The ride service owns the ride state machine:

```text
REQUESTED -> ASSIGNED -> ARRIVING -> IN_PROGRESS -> COMPLETED
                   \                         \
                    +--------> CANCELLED <----+
```

### Payment Completion and Compensation

![Payment completion and compensation workflow][payment-workflow-diagram]

Payment state follows:

```text
INITIATED -> PROCESSING -> PAID -> REFUNDED
     \             \
      +----------> FAILED -> REFUNDED
```

### Driver Availability and Location

Driver availability and GPS updates currently use authenticated REST endpoints through the gateway:

1. The driver app sets the driver online or offline.
2. Location updates are handled by `driver-service`.
3. PostgreSQL stores the durable last location.
4. Redis stores short-lived presence, location, and geo indexes for nearby-driver queries.
5. Booking and AI workflows use driver availability data when selecting a driver.

The frontend applications contain optional WebSocket clients and polling fallbacks, but the default Docker Compose stack does **not** deploy a production realtime WebSocket gateway. The admin dashboard includes a mock realtime server for UI demonstrations.

## Event-Driven Design

All governed events use a common envelope:

```text
eventId, type, version, traceId, occurredAt, payload
```

Important runtime topics include:

| Topic                     | Producer                             | Consumers                     | Purpose                                                 |
| ------------------------- | ------------------------------------ | ----------------------------- | ------------------------------------------------------- |
| `ride.created`            | Booking service                      | Ride service, payment service | Starts downstream ride/payment processing.              |
| `ride_events`             | Booking service                      | None                          | Compatibility event for ride-request workflows.         |
| `ride_accepted`           | Booking service                      | None                          | Compatibility event emitted when a booking is accepted. |
| `ride.assigned`           | Ride service                         | Ride service, payment service | Propagates assignment state.                            |
| `ride.cancelled`          | Booking service                      | Ride service, payment service | Propagates user cancellation or payment compensation.   |
| `payment.completed`       | Payment service                      | Ride service, booking service | Synchronizes successful payment state.                  |
| `payment.failed`          | Payment service                      | Ride service, booking service | Triggers failure handling and booking compensation.     |
| `driver.location.updated` | Contract-only in the current runtime | Ride service contract guard   | Reserved for event-driven location propagation.         |
| `review.created`          | Contract-only in the current runtime | None                          | Reserved for review integrations.                       |

Topic policy is defined in `infra/kafka/topic-policy.json`. The bootstrap script provisions:

- Main topics.
- Retry tiers: `<topic>.retry.30s`, `<topic>.retry.5m`, and `<topic>.retry.30m`.
- Dead-letter topics: `<topic>.dlq`.

Event contracts and compatibility checks are maintained in:

- `contracts/events/catalog.json`
- `contracts/events/schema-registry/`
- `contracts/events/topics.md`

## Reliability and Security

### Reliability Patterns

| Pattern                 | Current implementation                                                                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Transactional outbox    | Booking and payment persist domain changes and pending events in the same PostgreSQL transaction; ride persists outbox records in MongoDB.           |
| Inbox and deduplication | Kafka consumers record event IDs before processing to prevent duplicate side effects.                                                                |
| Idempotency             | Mutation endpoints use idempotency keys and Redis/database-backed response or lock storage where applicable.                                         |
| Retry and backoff       | HTTP clients, dependency startup, Kafka producers/consumers, outbox pollers, and notification dispatchers use bounded or exponential retry policies. |
| Dead-letter handling    | Invalid or exhausted events are routed to `<source-topic>.dlq`.                                                                                      |
| Compensation            | Payment failure can cancel the booking and publish `ride.cancelled` without distributed two-phase commit.                                            |
| Circuit breaking        | Gateway and booking-to-pricing calls include configurable circuit-breaker behavior.                                                                  |

### Security Boundaries

- JWT access tokens protect user-facing APIs.
- Gateway and service middleware enforce role- and ownership-based authorization.
- Internal endpoints use an `x-internal-key` boundary where configured.
- Helmet, CORS, payload limits, schema validation, and rate limiting protect HTTP entry points.
- The gateway can serve HTTPS with development certificates.

The local stack intentionally uses development defaults such as `dev-secret`, `dev-internal-key`, Kafka PLAINTEXT, and unauthenticated Redis/MongoDB. Replace these controls before any shared or production deployment.

## Repository Structure

```text
.
├── apps/                       # Customer, driver, and admin applications
├── services/                   # Gateway and domain microservices
├── libs/                       # Shared HTTP, validation, resilience, security, and telemetry libraries
├── contracts/
│   ├── openapi/                # REST API contracts
│   ├── events/                 # Event catalog and JSON schemas
│   └── state-machines/         # Ride, payment, and review state machines
├── infra/
│   ├── docker-compose.dev.yml  # Local backend stack and development tools
│   ├── docker-compose.pro.yml  # Production-shaped single-host stack
│   ├── docker-compose.kafka.prodlike.yml
│   ├── postgres/               # Database creation and local seed scripts
│   ├── mongo/                  # MongoDB local seed scripts
│   ├── kafka/                  # Kafka topic policy and deployment notes
│   └── observability/          # ELK, OTel, Prometheus, Tempo, Grafana, and Alertmanager
├── scripts/                    # Health, seed, contract, Postman, k6, and test automation
├── docs/                       # Architecture, runbooks, reports, and sequence diagrams
├── package.json                # npm workspaces and root automation
└── README.md
```

## Production Deployment

Before deploying to a shared staging or production environment:

1. Build immutable service images in CI and publish them to a private registry. Do not build application images on production hosts.
2. Move secrets to a secret manager. Rotate `JWT_SECRET`, `INTERNAL_API_KEY`, database credentials, provider credentials, and webhook secrets.
3. Expose only a load balancer or ingress in front of the API Gateway. Remove direct public service ports and development UIs.
4. Terminate trusted TLS certificates at the ingress or gateway. Encrypt and authenticate service-to-service, Kafka, database, and cache traffic.
5. Replace local PostgreSQL, MongoDB, Redis, and Kafka containers with highly available managed or clustered deployments with backups and recovery procedures.
6. Run service migrations as an explicit deployment job before starting new application versions. Do not rely on local seed scripts.
7. Deploy multiple stateless service replicas, configure readiness/liveness probes, and set resource requests, limits, autoscaling, and disruption policies.
8. Deploy `places-service` separately if place search is required, because it is not present in `infra/docker-compose.pro.yml`.
9. Configure external payment providers, verified PayOS webhooks, alert receivers, retention policies, dashboards, and incident runbooks.
10. Keep demo credentials, seed data, self-signed certificates, mock realtime servers, and tracked local `.env` values out of production.

For Kubernetes or another orchestrator, use the service boundaries and environment variables in the Compose files as the deployment mapping, then add managed secrets, service discovery, autoscaling, health probes, and network policies.

## Configuration

The repository includes local `.env` files for development. Review them before starting the stack and never store real production credentials in the repository.

Important configuration groups:

| Group             | Examples                                                                                      |
| ----------------- | --------------------------------------------------------------------------------------------- |
| Authentication    | `JWT_SECRET`, `JWT_ACCESS_SECRET`, `AUTH_JWT_SECRET`, `JWT_ALGORITHMS`                        |
| Internal trust    | `INTERNAL_API_KEY`                                                                            |
| Gateway           | `RATE_LIMIT_MAX`, `PROXY_TIMEOUT_MS`, `GATEWAY_HTTPS_ENABLED`, `HTTPS_PORT`                   |
| Databases         | `DATABASE_URL`, `MONGODB_URI`, `REDIS_URL`                                                    |
| Kafka             | `KAFKA_BROKERS`, consumer group/retry settings, producer acknowledgement settings             |
| Event reliability | `OUTBOX_*`, `INBOX_*`, Kafka retry and DLQ topic settings                                     |
| Payments          | `VIETQR_*`, `PAYOS_*`, compensation and auto-sync settings                                    |
| Places            | `PLACES_PROVIDER_*`                                                                           |
| Observability     | `OTEL_EXPORTER_OTLP_ENDPOINT`, `DEPLOY_ENV`, `LOGSTASH_SYSLOG_HOST`, alert receiver variables |

Compose provides insecure local defaults for several values. Override them through the environment or a deployment-specific env file.

## Observability

```text
Application logs -> Logstash -> Elasticsearch -> Kibana
OTel metrics      -> OTel Collector -> Prometheus -> Grafana
OTel traces       -> OTel Collector -> Tempo -> Grafana
Prometheus rules  -> Alertmanager -> Webhook/Slack/Telegram
```

| Component     | URL                     | Purpose                                                               |
| ------------- | ----------------------- | --------------------------------------------------------------------- |
| Grafana       | `http://localhost:3001` | Provisioned service, dependency, business-flow, and Kafka dashboards. |
| Prometheus    | `http://localhost:9090` | Metrics, scrape targets, and alert rules.                             |
| Alertmanager  | `http://localhost:9093` | Alert routing and receiver status.                                    |
| Tempo         | `http://localhost:3200` | Distributed trace storage.                                            |
| Kibana        | `http://localhost:5601` | Log search and dashboards.                                            |
| Elasticsearch | `http://localhost:9200` | Central log storage.                                                  |

Docker Desktop can route container logs to Logstash through `host.docker.internal`. On Linux, set `LOGSTASH_SYSLOG_HOST` to an address reachable from Docker containers.

See `docs/runbooks/README.md` and `docs/runbooks/kafka-observability.md` for alert and Kafka operations.

## Current Limitations

- The default stack does not include a production realtime WebSocket gateway. Frontends use optional WebSocket URLs, mocks, or polling fallbacks.
- Notification delivery is REST- and dispatcher-based; it is not currently a Kafka consumer.
- The AI service is a heuristic/rule-based MVP intended for architecture and test scenarios.
- Retry topics are provisioned by policy, while individual services implement their own retry and DLQ behavior.
- The production-shaped Compose file is not a complete production platform and currently omits `places-service`.
- Local environment files and development defaults are intentionally convenient and must not be reused for production secrets.

## Documentation

- `docs/README.md`: detailed repository and service reference.
- `docs/sequence-diagrams/main-event-flows.md`: event-driven sequence diagrams.
- `contracts/openapi/`: REST API contracts.
- `contracts/events/`: event catalog, schemas, and runtime topic documentation.
- `contracts/state-machines/`: ride, payment, and review state machines.
- `infra/kafka/README.md`: Kafka profiles and topic governance.
- `docs/runbooks/`: operational and incident-response runbooks.

[system-architecture-diagram]: https://kroki.io/mermaid/png/eNp1VE1vgzAMvfMrcuwO_QfTJNpOE1q3di07RT1k4EJUICgJrfrvl88S2HIgNu-92E5sODfsVtSES5SvEoTE8FNx0tdo3VDopFAQQutBSNYCx95Bad-fDLXh9KoIa0Y4LVvaYbOiDRH1DyO81BR0ZZKMEdFy-YLeiIQbuSc-2gy0UUJMgc7F6T7z_slo0kHWWC_oCPxKCziNaiP4FqpevcQEtghH-pNFtCvGLrSrsLMx2YGWgPUSE-w5LXQcZ6Mycm9VV7CzMdknk_RMCyIp63D4Eq0PrhRu2Jpo8oYUILA1MdFrnmL1xOg0w2k2kor1NxfcwgxV4WZIms032vtQ6OS0vt1hnmcNvpPzheCFMU-6RtObkVKIv-IA1LOoB8tkZEJWXF3HwnnHr62JZCYrVDzG2p16Tk7OMcI-_wx2LZqLbU8m6L95D1BSVbMx48EfjA7lJnCCBbVYLNz5wbqK4YUxm5WJ-qcLhtS7XDECZ52QfNBhoXyg9hPe5dDgXQ-dstCC5He0Zk0DhWRcR9e8mxf1D5E1DCJEc2h7FqQy4JZVQqofkcK9a4erIULSQgDhRZ38Aoz8nHU
[booking-workflow-diagram]: https://kroki.io/mermaid/png/eNp1kUFvgzAMhe_7FT5umjq0K4dKpUho2qSxtlLPIaQQFRLqJGz993MgbBRtp5j4e-H52YiLE4qLVLIKWXsHwJzVyrWFQP_BrUbYOmN1O1x0DK3ksmPKQnYEZmCTv0DGrPhk10U_0fosVeWhqdwL7CUXCzBHqkZwKv8G02T-WK6NrVDsP94W2Cs7ndnibidL4cXD-Y8Ndm0Fnd5GKCeQyCmE1XqdHWPI3_cHiPrnqBjdGEKyIzWDuxg2ztb0huQUTgnogzaWqAAQGoaNYTc24eK0FUCJ96yRJemgG5EbWZrEcECmDG1HahVDsACPoJ0t9Nc90pBPHIX_8wNp02Q1d7bVbSvnVsJMPwvjXHQkHUei5jT7n8ivsSF3isYVjTQ1zF3ACXUb7JFmIP3Lfh1kaICigvHzSTbNoARbo3ZVDVItNGE5PjausYw61FwYM6pE7_d2q_0GIJr-aQ
[payment-workflow-diagram]: https://kroki.io/mermaid/png/eNptkU1SwzAMhfc9hfZMeoAsOkPpDhal4QKKoyaeOrbxT4dwemQThzZ05b_3pO_Jnj4jaUEHib3DcQOAMRgdx5YcHyy6IIW0qAMccRqJV_TLtiF3lYIeCw_7W-nR-NA7at7fVupXPF9wdXeSHSVzXh832RtzkbpPqrItQlbOXavdboGp4cOh9iiCNLqGaDsMxCV_8Z7AxNCaL6ArH-8qZMC6KLfCjFZRoA6MWy7PKBV1bMviil0JvYZna9UELsUIqbtMzSEMzsR-AKm5461pTlJDM2nBIi2_Cdo5XkH1gcFTSFThPwCUcfyRH2OrpB8yxlYg_7ZiLaQgxANJSNm4Yn_Jyuy6f55HU9LNCJVPKVdFSXebHzAW1FM
