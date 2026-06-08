#!/bin/sh
set -eu

bootstrap_server="${KAFKA_BOOTSTRAP_SERVER:-kafka:9092}"
wait_attempts="${KAFKA_BOOTSTRAP_WAIT_ATTEMPTS:-30}"
wait_ms="${KAFKA_BOOTSTRAP_WAIT_MS:-2000}"
replication_factor="${KAFKA_TOPIC_RF:-1}"
min_isr="${KAFKA_TOPIC_MIN_ISR:-1}"
retention_ms="${KAFKA_TOPIC_RETENTION_MS:-604800000}"
segment_ms="${KAFKA_TOPIC_SEGMENT_MS:-3600000}"
dlq_retention_ms="${KAFKA_DLQ_TOPIC_RETENTION_MS:-1209600000}"
topic_specs="${KAFKA_TOPIC_SPECS:-ride.created:6 ride.assigned:6 ride.cancelled:6 payment.completed:6 payment.failed:6 review.created:3 driver.location.updated:12}"
retry_tiers="${KAFKA_RETRY_TIERS:-retry.30s:1800000 retry.5m:21600000 retry.30m:259200000}"

sleep_ms() {
  seconds="$((($1 + 999) / 1000))"
  sleep "$seconds"
}

wait_for_broker() {
  attempt=1
  while [ "$attempt" -le "$wait_attempts" ]; do
    if kafka-broker-api-versions --bootstrap-server "$bootstrap_server" >/dev/null 2>&1; then
      return 0
    fi
    echo "[kafka-bootstrap] broker not ready, attempt ${attempt}/${wait_attempts}"
    sleep_ms "$wait_ms"
    attempt="$((attempt + 1))"
  done
  echo "[kafka-bootstrap] broker ${bootstrap_server} was not ready" >&2
  return 1
}

apply_topic() {
  topic="$1"
  partitions="$2"
  topic_retention_ms="$3"

  kafka-topics \
    --bootstrap-server "$bootstrap_server" \
    --create \
    --if-not-exists \
    --topic "$topic" \
    --partitions "$partitions" \
    --replication-factor "$replication_factor"

  kafka-topics \
    --bootstrap-server "$bootstrap_server" \
    --alter \
    --if-exists \
    --topic "$topic" \
    --partitions "$partitions" >/dev/null 2>&1 || true

  kafka-configs \
    --bootstrap-server "$bootstrap_server" \
    --alter \
    --entity-type topics \
    --entity-name "$topic" \
    --add-config "cleanup.policy=delete,retention.ms=${topic_retention_ms},segment.ms=${segment_ms},min.insync.replicas=${min_isr}"
}

wait_for_broker

for spec in $topic_specs; do
  topic="${spec%%:*}"
  partitions="${spec#*:}"
  echo "[kafka-bootstrap] apply ${topic}"
  apply_topic "$topic" "$partitions" "$retention_ms"

  for retry_spec in $retry_tiers; do
    retry_suffix="${retry_spec%%:*}"
    retry_retention_ms="${retry_spec#*:}"
    apply_topic "${topic}.${retry_suffix}" "$partitions" "$retry_retention_ms"
  done

  apply_topic "${topic}.dlq" "$partitions" "$dlq_retention_ms"
done

echo "[kafka-bootstrap] done"
