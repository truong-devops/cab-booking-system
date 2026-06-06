# Observability Audit — cab-booking-system

Date: 2026-02-11  
Scope: repo static audit (code + config). No runtime checks executed.

> Historical note: this report predates the ELK logging migration on 2026-04-02.
> See `docs/observability/ELK_MIGRATION_NOTES.md` for current logging architecture.

## Executive Summary

**Verdict: FAIL (observability by design)**  
Reason: basic health endpoints and partial structured logging exist, but there is **no metrics stack, no distributed tracing instrumentation, no centralized logging config, and no dashboards/runbooks**. Correlation IDs exist but are not consistently generated/propagated across all services.

## What was checked (from code/config)

- Services under `services/*`
- Infra/config under `infra/`
- Docs under `docs/`

## Evidence (selected, code-based)

| Component                        | Evidence (file path)                                                                                                                                                                                                                   | Notes                                                              |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Trace/request IDs at gateway     | `services/api-gateway/src/middleware/trace.js`                                                                                                                                                                                         | Generates `x-trace-id` + `x-request-id` and attaches to response   |
| JSON request logs at gateway     | `services/api-gateway/src/middleware/requestLogger.js`                                                                                                                                                                                 | Logs JSON (method/path/status/latency/traceId/requestId)           |
| Pino structured logging          | `services/ride-service/src/utils/logger.js`, `services/driver-service/src/utils/logger.js`, `services/payment-service/src/utils/logger.js`, `services/user-service/src/utils/logger.js`, `services/review-service/src/utils/logger.js` | Structured logging present in some services                        |
| Non-structured logging           | `services/booking-service/src/app.js`, `services/notification-service/src/app.js`                                                                                                                                                      | `morgan("dev")` -> text logs (not structured)                      |
| Trace propagation in HTTP client | `libs/http/client.js`, `libs/http/httpClient.js`                                                                                                                                                                                       | Copies `x-trace-id` and `x-request-id` into downstream requests    |
| Event envelope includes traceId  | `services/booking-service/src/routes/bookings.js`                                                                                                                                                                                      | Event envelope includes `traceId` (if incoming header provided)    |
| Health endpoints                 | e.g. `services/ride-service/src/app.js`, `services/driver-service/src/app.js`, `services/auth-service/src/app.js`                                                                                                                      | `/health`, `/healthz`, `/readyz` exist on most services            |
| Infra composition                | `infra/docker-compose.dev.yml`                                                                                                                                                                                                         | No logging/metrics/tracing stack (Loki/ELK/Prometheus/OTel/Jaeger) |
| Runbooks                         | `docs/runbooks/README.md`                                                                                                                                                                                                              | Placeholder only, no actual runbook content                        |

## Pillar-by-pillar assessment

### A) Logging standardization

- **Structured logging:** PARTIAL  
  Some services use Pino JSON logs (ride/driver/payment/user/review). Others use plain Morgan (`booking`, `notification`) without structure.
- **Log level + sampling:** PARTIAL  
  Pino supports levels; `LOG_LEVEL` is used in `user-service`/`payment-service`. No sampling found.
- **Correlation/Request IDs:** PARTIAL  
  Gateway creates `x-trace-id` / `x-request-id`; ride/driver/user/payment use trace middleware. Auth/booking do not create IDs.
- **Centralized logging:** FAIL  
  No ELK/Loki/Cloud logging config in repo/compose.

### B) Metrics

- **Metrics endpoint (/metrics):** FAIL  
  No `prom-client`/`/metrics` found.
- **RED metrics (Rate/Errors/Duration):** FAIL  
  No metrics instrumentation.
- **Business metrics:** FAIL  
  No counters like `bookings_created_total`.
- **Alert rules/SLOs:** FAIL  
  No alertmanager/grafana rules or SLO docs.

### C) Distributed Tracing

- **Instrumentation (OpenTelemetry/Jaeger/Zipkin):** FAIL  
  No OTel SDKs or exporters found.
- **Context propagation:** PARTIAL  
  Custom `x-trace-id` propagation exists in gateway + HTTP client.
- **Collector/exporter config:** FAIL  
  None present.
- **Trace-log linkage:** PARTIAL  
  Some logs include `traceId`, but not standardized across all services.

### D) Health/Runtime signals

- **Readiness/Liveness:** PARTIAL  
  Many services expose `/healthz` and `/readyz`. No k8s probes or deployment configs.
- **Circuit breaker/retry w/ metrics/tracing:** FAIL  
  Circuit breaker exists in `libs/http/client.js`, but **no metrics/tracing**.
- **DLQ/Retry visibility:** FAIL  
  Kafka is used, but no lag/consumer metrics or DLQ visibility.

### E) Dashboards/Runbooks

- **Dashboards:** FAIL  
  No Grafana dashboards in repo.
- **Runbooks:** FAIL  
  `docs/runbooks` is empty.

## Gaps & Risks

1. **No metrics or dashboards** → cannot detect error rates/latency regressions early.
2. **No distributed tracing** → hard to debug cross-service issues.
3. **Inconsistent logging format** → log aggregation/search will be unreliable.
4. **No centralized logging** → no single source of truth for incidents.
5. **No operational runbooks** → oncall response will be slow or inconsistent.

## Recommendations (prioritized)

**P0 (S/M)**

- Add Prometheus metrics (e.g., `prom-client`) for HTTP RED + key business counters.
- Standardize structured JSON logs across all services (replace `morgan("dev")` with JSON logger).

**P1 (M/L)**

- Add OpenTelemetry tracing (HTTP + Kafka) and export to OTLP/Jaeger/Tempo.
- Add centralized logging stack (Loki/ELK) in `infra/docker-compose*.yml`.

**P2 (M)**

- Create dashboards (Grafana JSON) and runbooks for top incidents.
- Add alert rules for 5xx rate, latency, Kafka consumer lag.

## Runtime checks (not executed)

No runtime checks were executed to avoid altering the environment. If desired, run:

- `curl http://localhost:42100/healthz`
- `curl http://localhost:42105/healthz`
  and capture outputs in this report.
