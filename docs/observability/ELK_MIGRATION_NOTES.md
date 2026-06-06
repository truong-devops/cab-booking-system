# ELK Migration Notes

Date: 2026-04-02

## Scope

This migration switches the primary logging backend from Loki to ELK while keeping existing OpenTelemetry traces/metrics flow.

## Old vs New

Old logging path:

- OTEL Collector logs -> Loki -> Grafana (logs view)

New logging path:

- Container stdout/stderr -> Docker syslog driver -> Logstash -> Elasticsearch -> Kibana

Unchanged paths:

- Traces: OTel -> Tempo -> Grafana
- Metrics: OTel -> Prometheus -> Grafana

## Breaking changes

1. Loki is no longer part of active observability compose stack.
2. Grafana no longer has Loki datasource in provisioning.
3. Log exploration moves to Kibana (`http://localhost:42193`).

## Backward compatibility

- `infra/observability/loki.yml` is kept as deprecated rollback reference.
- Base app compose (`infra/docker-compose.dev.yml`) is unchanged; log rerouting only happens when observability overlay is enabled.

## New components

- Elasticsearch (`docker.elastic.co/elasticsearch/elasticsearch:8.13.4`)
- Logstash (`docker.elastic.co/logstash/logstash:8.13.4`)
- Kibana (`docker.elastic.co/kibana/kibana:8.13.4`)

## New configs

- `infra/observability/elasticsearch/elasticsearch.yml`
- `infra/observability/logstash/logstash.yml`
- `infra/observability/logstash/pipeline/logstash.conf`
- `infra/observability/kibana/kibana.yml`

## Validation checklist

- Start stack:

```bash
npm run dev:observability
```

If Docker daemon cannot reach Logstash via localhost, set:

- `LOGSTASH_SYSLOG_HOST=host.docker.internal` (Docker Desktop default)
- `LOGSTASH_SYSLOG_PORT=5514`

- Check Elasticsearch health:

```bash
curl -s http://localhost:9200/_cluster/health?pretty
```

- Check indices created:

```bash
curl -s http://localhost:9200/_cat/indices/cab-logs-*?v
```

- Check logs received by service:

```bash
curl -s "http://localhost:9200/cab-logs-*/_search?size=20&q=service.name:api-gateway&sort=@timestamp:desc"
```

- Open Kibana and create data view `cab-logs-*`.

## Follow-up TODOs

- Standardize remaining non-JSON service logs (`booking-service`, `notification-service`) to structured JSON for richer filtering.
- If OTLP logs are enabled in service code later, wire an explicit OTLP logs -> ELK pipeline in OTel collector.
