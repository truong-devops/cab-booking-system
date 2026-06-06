## Kafka E2E Observability Runbook

### 1) Mục tiêu giám sát

Các metric bắt buộc đã được publish:

- `cab_kafka_consumer_lag`: lag theo `service_name`, `consumer_group`, `topic`, `partition`.
- `cab_outbox_backlog`: backlog outbox theo `service_name`, `queue_name`.
- `cab_kafka_publish_total`: success/error rate publish theo `topic`, `operation`.
- `cab_kafka_dlq_total`: DLQ rate theo `source_topic`, `dlq_topic`, `error_type`.
- `cab_kafka_retry_total`: retry rate theo `scope` (outbox/inbox), `topic`, `status`.
- `cab_kafka_processing_latency_ms`: latency pipeline (`publish_event`, `outbox_publish`, `consume_event`, `inbox_process`, `publish_dlq`).

Dashboard: `Cab Booking - Kafka End-to-End`.

### 2) Trace correlation HTTP -> Kafka -> Consumer

Trace path chuẩn:

1. HTTP request vào service có middleware trace (`x-trace-id`).
2. Envelope event chứa `traceId`.
3. Producer set Kafka header `x-trace-id` và `x-event-id`.
4. Consumer đọc `traceId` từ envelope, fallback từ header `x-trace-id`, log ra `traceId`.

Cách kiểm tra nhanh:

```bash
# Lấy traceId từ response header của request tạo booking
curl -i -X POST http://localhost:42104/api/v1/bookings \
  -H 'content-type: application/json' \
  -d '{"pickup":{"lat":10.77,"lng":106.69},"dropoff":{"lat":10.78,"lng":106.70},"vehicleType":"STANDARD"}'

# Xem message Kafka có header trace hay không
COMPOSE="docker compose --env-file .env -f infra/docker-compose.dev.yml"
$COMPOSE exec -T kafka kafka-console-consumer \
  --bootstrap-server kafka:9092 \
  --topic ride.created \
  --from-beginning \
  --max-messages 1 \
  --property print.headers=true

# Search log theo traceId
docker compose --env-file .env -f infra/docker-compose.dev.yml logs booking-service ride-service payment-service | rg '<trace-id>'
```

### 3) Alert quan trọng và ảnh hưởng vận hành

- `KafkaConsumerLagHighWarning`, `KafkaConsumerLagHighCritical`
  - Ảnh hưởng: sự kiện xử lý chậm, trễ trạng thái booking/ride/payment, SLA realtime giảm.
- `KafkaOutboxBacklogHighWarning`, `KafkaOutboxBacklogHighCritical`
  - Ảnh hưởng: dữ liệu DB đã commit nhưng event chưa phát, hệ thống downstream lệch trạng thái.
- `KafkaPublishErrorRateHigh`
  - Ảnh hưởng: event thất thoát tạm thời (được retry), tăng load outbox và tăng độ trễ.
- `KafkaDlqRateHigh`
  - Ảnh hưởng: lỗi contract/schema hoặc poison message tăng, cần can thiệp thủ công.
- `KafkaRetryRateHigh`
  - Ảnh hưởng: hệ thống đang degraded, có thể dẫn tới DLQ spike nếu kéo dài.
- `KafkaProcessingLatencyP95High`
  - Ảnh hưởng: end-to-end event time tăng, nguy cơ dồn lag/backlog.

### 4) Playbook xử lý sự cố

#### 4.1 Lag tăng (`KafkaConsumerLagHigh*`)

1. Xác nhận phạm vi:

```bash
curl -sG http://localhost:42191/api/v1/query \
  --data-urlencode 'query=max by (service_name,consumer_group,topic) (cab_kafka_consumer_lag)'
```

2. Kiểm tra service consumer tương ứng còn sống và không crash loop.
3. Kiểm tra broker health, rebalance, network timeout, DB downstream.
4. Giảm lag ngắn hạn:

- tăng `KAFKA_CONSUMER_PARTITIONS_CONCURRENCY`
- tăng số replica consumer group
- giảm xử lý nặng trong path synchronous của consumer

5. Sau ổn định: theo dõi `lag`, `retry`, `dlq` thêm 30 phút.

#### 4.2 DLQ tăng (`KafkaDlqRateHigh`)

1. Xác định `source_topic`, `error_type` cao nhất.
2. Lấy mẫu message từ topic DLQ để phân loại:

- lỗi contract/schema
- lỗi business logic
- poison message dữ liệu xấu

3. Nếu lỗi schema mới: rollback producer hoặc release consumer tương thích.
4. Nếu poison message: chặn nguồn phát + chuẩn bị re-drive có lọc.

#### 4.3 Poison message

1. Freeze re-drive tự động cho topic lỗi.
2. Dump mẫu message DLQ, xác định pattern gây lỗi.
3. Thêm guard validation tại consumer/outbox.
4. Re-drive từng batch nhỏ và theo dõi `KafkaDlqRateHigh` + `KafkaRetryRateHigh`.

#### 4.4 Broker down / publish timeout

1. Xác nhận broker/container health và network.
2. Kiểm tra đồng thời:

- `KafkaPublishErrorRateHigh`
- `KafkaOutboxBacklogHigh*`
- `KafkaProcessingLatencyP95High`

3. Khôi phục broker trước, sau đó theo dõi outbox drain rate.
4. Chỉ scale worker sau khi broker ổn định để tránh retry storm.

### 5) Cách test từng alert (local)

Dùng stack:

```bash
COMPOSE="docker compose --env-file .env -f infra/docker-compose.dev.yml -f infra/observability/docker-compose.observability.yml"
$COMPOSE up -d
```

Kiểm tra rule đã load:

```bash
curl -s http://localhost:42191/api/v1/rules | rg 'KafkaConsumerLagHigh|KafkaOutboxBacklogHigh|KafkaPublishErrorRateHigh|KafkaDlqRateHigh|KafkaRetryRateHigh|KafkaProcessingLatencyP95High'
```

1. `KafkaOutboxBacklogHigh*` + `KafkaPublishErrorRateHigh` + `KafkaRetryRateHigh` + `KafkaProcessingLatencyP95High`

- Test:
  1. Stop broker: `$COMPOSE stop kafka`
  2. Gọi API tạo booking liên tục (để outbox tăng).
  3. Đợi 10-15 phút theo `for` của alert.
- Kỳ vọng: backlog tăng, publish error/retry tăng, latency outbox_publish tăng.

2. `KafkaDlqRateHigh`

- Test:
  1. Start lại broker: `$COMPOSE start kafka`
  2. Bơm 25 message JSON sai vào `ride.created`:

```bash
seq 1 25 | sed 's/.*/not-a-json-event/' | \
  $COMPOSE exec -T kafka kafka-console-producer --broker-list kafka:9092 --topic ride.created
```

- Kỳ vọng: consumer route sang `ride.created.dlq`, alert DLQ fire.

3. `KafkaConsumerLagHigh*`

- Test:
  1. Bơm burst lớn vào topic tiêu thụ:

```bash
seq 1 6000 | sed 's/.*/{"eventId":"evt-&","traceId":"t-&","occurredAt":"2026-01-01T00:00:00.000Z","type":"RideCreated","version":1,"payload":{"rideId":"ride-&","bookingId":"bk-&","pickup":{"lat":10.77,"lng":106.69},"dropoff":{"lat":10.78,"lng":106.70},"vehicleType":"STANDARD","timestamp":"2026-01-01T00:00:00.000Z"}}/' | \
  $COMPOSE exec -T kafka kafka-console-producer --broker-list kafka:9092 --topic ride.created
```

2. Theo dõi lag query theo group/topic.

- Kỳ vọng: lag tăng rõ rệt trước khi consumer bắt kịp.

### 6) Hậu kiểm sau sự cố

- Xác nhận lag về baseline.
- Outbox backlog về gần 0.
- DLQ/retry rate giảm về baseline.
- Ghi lại root cause + hành động phòng ngừa (schema guard, timeout, capacity, retry tuning).
