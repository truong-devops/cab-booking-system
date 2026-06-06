## Observability Alerting Runbook (Prometheus + Alertmanager)

Kafka E2E runbook: `docs/runbooks/kafka-observability.md`

### 1) Start stack

```bash
docker compose --env-file .env -f infra/docker-compose.dev.yml -f infra/observability/docker-compose.observability.yml up -d
```

### 2) Verify wiring

```bash
curl -s http://localhost:42191/api/v1/status/config | rg -n "alertmanagers|alertmanager:9093"
curl -s http://localhost:9093/-/healthy
curl -s http://localhost:42191/api/v1/rules | rg -n "ServiceDown|HighHttpErrorRate|PaymentFailureSpike|QueueBacklogHigh"
```

### 3) Force a test alert (without waiting metric conditions)

```bash
curl -X POST http://localhost:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "ManualAlertTest",
      "severity": "warning",
      "service_name": "manual-test"
    },
    "annotations": {
      "summary": "Manual alert test",
      "description": "Alertmanager route/receiver smoke test"
    }
  }]'
```

Check alert:

```bash
curl -s http://localhost:9093/api/v2/alerts | rg -n "ManualAlertTest|severity|service_name"
```

### 4) Force Prometheus rule alert quickly

Stop OTel collector for ~2 minutes:

```bash
docker compose --env-file .env -f infra/docker-compose.dev.yml -f infra/observability/docker-compose.observability.yml stop otel-collector
```

Then check:

```bash
curl -s http://localhost:42191/api/v1/alerts | rg -n "OTelCollectorScrapeMissing|firing"
```

Bring it back:

```bash
docker compose --env-file .env -f infra/docker-compose.dev.yml -f infra/observability/docker-compose.observability.yml start otel-collector
```

### 5) Optional channels via env

- Generic webhook (default): `ALERT_WEBHOOK_URL`
- Slack receiver: set `ALERT_DEFAULT_RECEIVER=slack-notifications` (or `ALERT_WARNING_RECEIVER` / `ALERT_CRITICAL_RECEIVER`) + `SLACK_WEBHOOK_URL`, `SLACK_CHANNEL`
- Telegram receiver: set `ALERT_DEFAULT_RECEIVER=telegram-notifications` + `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`

Restart alertmanager after env change:

```bash
docker compose --env-file .env -f infra/docker-compose.dev.yml -f infra/observability/docker-compose.observability.yml up -d alertmanager
```
