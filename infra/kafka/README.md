# Kafka Infra Profiles And Topic Governance

## 1. Deployment modes

### Local (backward-compatible)

- Single broker (`kafka` in `infra/docker-compose.dev.yml`).
- Existing flow still works without extra flags.

Run:

```bash
docker compose --env-file .env --env-file infra/env/kafka.local.env \
  -f infra/docker-compose.dev.yml up -d
```

### Prod-like (multi-broker profile)

- Adds `kafka-1`, `kafka-2`, `kafka-3` via profile `kafka-prodlike`.
- Keep base compose for all services, add overlay for Kafka cluster.

Run:

```bash
docker compose --env-file .env --env-file infra/env/kafka.staging.env \
  -f infra/docker-compose.dev.yml -f infra/docker-compose.kafka.prodlike.yml \
  --profile kafka-prodlike up -d
```

## 2. Topic architecture

Topic classes:

- Main topic: `<topic>`
- Retry topics: `<topic>.retry.30s`, `<topic>.retry.5m`, `<topic>.retry.30m`
- Dead letter topic: `<topic>.dlq`

Main topics are taken from `contracts/events/catalog.json` and policy in `infra/kafka/topic-policy.json`.

## 3. Topic bootstrap command

Production Compose:

- `infra/docker-compose.pro.yml` runs `kafka-topics-bootstrap` as a one-shot job.
- `booking-service`, `ride-service`, and `payment-service` wait for that job before starting.
- `KAFKA_AUTO_CREATE_TOPICS_ENABLE` defaults to `false` in production compose.

Local/single broker:

```bash
node scripts/kafka/bootstrap-topics.js
```

Prod-like/multi broker:

```bash
KAFKA_COMPOSE_FILES=infra/docker-compose.dev.yml,infra/docker-compose.kafka.prodlike.yml \
KAFKA_COMPOSE_PROFILES=kafka-prodlike \
KAFKA_BOOTSTRAP_SERVICE=kafka-1 \
KAFKA_BOOTSTRAP_SERVER=kafka-1:9092 \
node scripts/kafka/bootstrap-topics.js
```

## 4. Environment separation

- `infra/env/kafka.local.env`: local default settings (RF=1).
- `infra/env/kafka.dev.env`: shared dev-like tuning.
- `infra/env/kafka.staging.env`: staging/prod-like tuning (RF=3, min ISR=2).

## 5. Migration guide

1. Start from local mode and keep `KAFKA_BROKERS=kafka:9092`.
2. Apply topic bootstrap once in local mode.
3. Switch to prod-like profile with `infra/env/kafka.staging.env`.
4. Update services to `KAFKA_BROKERS=kafka-1:9092,kafka-2:9092,kafka-3:9092` (already env-driven in compose).
5. Re-run topic bootstrap in prod-like mode to create/align partitions/RF/config.
6. Verify topic configs:

```bash
docker compose -f infra/docker-compose.dev.yml -f infra/docker-compose.kafka.prodlike.yml \
  --profile kafka-prodlike exec -T kafka-1 kafka-topics --bootstrap-server kafka-1:9092 --describe
```

For managed Kafka, set `KAFKA_BROKERS`, `KAFKA_SSL`, and `KAFKA_SASL_*` in the service environment. The Node services that use Kafka support KafkaJS SSL/SASL configuration from those variables.
