# Postman + k6 Test Plan (Truong)

## 1) Files đã tạo

Trong thư mục `scripts/postman-truong`:

- `truong-direct.postman_collection.json`
- `truong-partial.postman_collection.json`
- `truong-non-postman.postman_collection.json`
- `truong-local.postman_environment.json`
- `k6/case61-63-load.js`
- `k6/case35-47-59-concurrency-latency.js`
- `k6/case64-66-kafka-db-cache.js`
- `k6/case67-85-98-rate-limit.js`
- `k6/case68-70-latency-ramp.js`
- `k6/docker-compose.k6.yml`

## 2) Import vào Postman

1. Import `truong-local.postman_environment.json`.
2. Import 3 collection JSON.
3. Chọn environment `CAB System - Truong - Local`.
4. Chạy folder `00 Setup` trước trong collection `direct` hoặc `partial` để lấy token/biến động.
5. Với case dùng `{{expiredToken}}`, tự điền token hết hạn vào biến này.

## 3) Mapping đã áp dụng

- `direct`: `1-24, 29, 41-46, 50, 81-86, 91-93, 95-96, 98, 102`
- `partial`: `25-28, 30-40, 47-49, 51-60, 67, 71-80, 87-90, 94, 97, 99-100, 103-105, 111-120`
- `non-postman`: `0, 61-66, 68-70, 101, 106-110` (để trống request theo yêu cầu)

## 4) Cách check dữ liệu cho nhóm `partial`

Postman chỉ dùng để kích hoạt API. Kết quả pass/fail cuối cùng cần thêm bằng chứng ngoài Postman.

### 4.1 Nhóm Kafka/Event/Outbox

Áp dụng chính: `25-28, 38, 73, 105, 119`

- Chạy request trong Postman để phát sinh event.
- Check lag/offset/topic bằng Kafka UI hoặc CLI.
- Gợi ý nhanh (container kafka trong compose dev):

```bash
docker ps --format '{{.Names}}' | grep -E 'kafka' 
```

```bash
docker exec -it <kafka-container> kafka-topics --bootstrap-server localhost:9092 --list
```

```bash
docker exec -it <kafka-container> kafka-consumer-groups --bootstrap-server localhost:9092 --all-groups --describe
```

### 4.2 Nhóm Transaction/Compensation/Consistency

Áp dụng chính: `30-40, 74, 79`

- Chạy request Postman theo đúng thứ tự trong từng case folder.
- Đối chiếu DB state (booking/payment/outbox) để xác nhận rollback/compensation.
- Gợi ý SQL check nhanh (Postgres container):

```bash
docker ps --format '{{.Names}}' | grep -E 'postgres'
```

```bash
docker exec -it <postgres-container> psql -U cab -d booking-service_db -c "select booking_id,status,created_at,canceled_at from bookings order by created_at desc limit 20;"
```

### 4.3 Nhóm AI/Agent/Model

Áp dụng chính: `47-49, 51-60, 118`

- Postman xác minh response schema/cơ bản.
- Đối chiếu thêm log quyết định và model_version/latency.
- Endpoint hỗ trợ trong repo:
  - `POST /v1/ai/agent/select-driver`
  - `POST /v1/ai/forecast-demand`
  - `GET /v1/ai/agent/decisions/:trace_id`
  - `GET /metrics` (AI service)

### 4.4 Nhóm Security/Zero-Trust một phần

Áp dụng chính: `87-90, 94, 97, 99-100, 103-105`

- `87`: Postman chỉ thấy payload trả về; mã hóa at-rest phải check DB/KMS.
- `88`, `94`, `99`: Postman chỉ probe HTTPS/mTLS; xác minh mTLS thật ở mesh/ingress/cert logs.
- `97`: request direct service trong Postman để chứng minh bị chặn/bypass, nhưng cần thêm network policy evidence.
- `100`: dùng `x-trace-id` rồi đối chiếu audit log backend.

### 4.5 Nhóm Observability

Áp dụng chính: `111-120`

- Postman dùng để tạo traffic/trace seed.
- Xác minh cuối cùng ở stack observability:
  - Logs: ELK/Loki
  - Metrics: Prometheus/Grafana
  - Tracing: Jaeger/Tempo
  - Alerts: Alertmanager

## 5) Nhóm `non-postman`: test bằng k6 trên Docker

Áp dụng: `0, 61-66, 68-70, 101, 106-110`

## 5.1 Chuẩn bị

- Stack API chạy ở local (gateway `:3000`).
- Có JWT user token (dán vào env `USER_TOKEN`).

## 5.2 Chạy k6 bằng Docker Compose

Từ root repo:

```bash
BASE_URL=http://host.docker.internal:3000 \
BOOKING_URL=http://host.docker.internal:3003 \
PRICING_URL=http://host.docker.internal:3006 \
USER_TOKEN='<your_user_jwt>' \
docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 run /work/case61-63-load.js
```

```bash
BASE_URL=http://host.docker.internal:3000 \
AI_URL=http://host.docker.internal:3013 \
USER_TOKEN='<your_user_jwt>' \
docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 run /work/case35-47-59-concurrency-latency.js
```

```bash
BASE_URL=http://host.docker.internal:3000 \
USER_TOKEN='<your_user_jwt>' \
docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 run /work/case64-66-kafka-db-cache.js
```

```bash
BASE_URL=http://host.docker.internal:3000 \
USER_TOKEN='<your_user_jwt>' \
docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 run /work/case68-70-latency-ramp.js
```

```bash
BASE_URL=http://host.docker.internal:3000 \
USER_EMAIL='rate-limit-user@test.com' \
USER_PASS='123456' \
USER_TOKEN='<your_user_jwt>' \
docker compose -f scripts/postman-truong/k6/docker-compose.k6.yml run --rm k6 run /work/case67-85-98-rate-limit.js
```

## 5.3 Cách đối chiếu theo case non-postman

- `61-63`: lấy k6 report (`http_req_failed`, `p95`, throughput).
- `35,59`: chạy script concurrency để tạo request song song (race/conflict evidence).
- `47`: lấy nhiều latency samples, chốt theo p95.
- `64`: sau k6 phải check Kafka lag/offset.
- `65`: sau k6 phải check DB connection/pool logs.
- `66`: sau k6 check hit ratio cache (Redis + app metrics).
- `67,85,98`: dùng k6 burst, thống kê tỷ lệ `429` và `5xx`.
- `68-70`: dùng k6 làm tải + check Grafana/K8s HPA để kết luận.
- `101,106-110`: đây là deploy/rollout/rollback/config; không dùng Postman, k6 chỉ làm smoke/load sau deploy.

## 6) Lưu ý vận hành

- Một số case trong collection `partial` được ghi rõ là `Manual Evidence`.
- Với `https://localhost:3443`, nếu cert self-signed thì tắt SSL verification trong Postman hoặc import cert dev.
- Nếu chạy theo docker compose dev của repo, port mặc định phù hợp với environment đã tạo.
