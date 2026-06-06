# Observability Architecture (ELK logging + OTel metrics/tracing)

Last updated: 2026-04-02

## Architecture overview

```
Application containers
  -> stdout/stderr logs
  -> Docker syslog logging driver (overlay compose)
  -> Logstash (parse/transform)
  -> Elasticsearch (index + search)
  -> Kibana (log exploration)

Application OpenTelemetry SDK
  -> OTEL Collector (OTLP 4317/4318)
     -> Tempo (traces)
     -> Prometheus exporter (metrics)
  -> Grafana (Prometheus + Tempo)
```

## What changed (old vs new)

Old logging path:

- OTEL Collector logs pipeline -> Loki
- Grafana used Loki datasource for logs

New logging path:

- Docker stdout/stderr -> Logstash -> Elasticsearch -> Kibana
- Loki removed from active compose pipeline
- Grafana kept for metrics/traces only (Prometheus + Tempo)

## Why this migration is low-risk

- No business logic changes required for route handling/domain flows.
- Existing OTel traces/metrics path is preserved.
- Logging routing is applied via compose overlay (`infra/observability/docker-compose.observability.yml`), so base dev compose remains usable.

## Infra files

Core stack:

- `infra/observability/docker-compose.observability.yml`
- `infra/observability/elasticsearch/elasticsearch.yml`
- `infra/observability/logstash/logstash.yml`
- `infra/observability/logstash/pipeline/logstash.conf`
- `infra/observability/kibana/kibana.yml`

Metrics/tracing (kept):

- `infra/observability/otel-collector.yml`
- `infra/observability/prometheus.yml`
- `infra/observability/tempo.yml`
- `infra/observability/grafana/provisioning/datasources/datasources.yml`

Deprecated:

- `infra/observability/loki.yml` (kept for rollback reference only)

## Local run

```bash
npm run dev:observability
```

This starts base services + observability overlay.

Environment knobs for syslog routing:

- `LOGSTASH_SYSLOG_HOST` (default: `host.docker.internal`)
- `LOGSTASH_SYSLOG_PORT` (default: `5514`)

For Linux Docker Engine, set `LOGSTASH_SYSLOG_HOST` to a host/IP reachable from Docker daemon.

Main endpoints:

- Kibana: http://localhost:42193
- Elasticsearch: http://localhost:9200
- Logstash monitoring API: http://localhost:9600
- Grafana: http://localhost:42190
- Prometheus: http://localhost:42191
- Tempo: http://localhost:3200

## Log normalization

Logstash normalizes these fields when available:

- `@timestamp`
- `level`
- `service.name`
- `trace_id`
- `span_id`
- `message`
- `environment`

For Pino JSON logs:

- Maps `serviceName` -> `service.name`
- Maps `traceId` / `otelTraceId` -> `trace_id`
- Maps numeric Pino level to text level (`info`, `warn`, `error`, ...)

For non-JSON logs:

- Keeps original `message`
- Fallback `service` inferred from container program/tag
- Fallback `level` from syslog severity, default `info`

## Verification (manual)

1. Generate traffic/logs (any service request).
2. Check Elasticsearch indices:

```bash
curl -s http://localhost:9200/_cat/indices/cab-logs-*?v
```

3. Check a few documents:

```bash
curl -s "http://localhost:9200/cab-logs-*/_search?size=5&sort=@timestamp:desc" | jq '.hits.hits[]._source'
```

4. Open Kibana and create a data view for `cab-logs-*`.

## Notes

- OTEL Collector logs pipeline is intentionally not active for ELK yet; primary logging path is Docker -> Logstash.
- TODO: if services later emit OTLP logs, add a dedicated OTLP logs -> ELK exporter path.
