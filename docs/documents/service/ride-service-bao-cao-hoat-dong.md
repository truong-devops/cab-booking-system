# Báo cáo phân tích `ride-service`

Ngày lập: 14/04/2026  
Phạm vi đọc mã: `services/ride-service/src/*`, `services/ride-service/.env`, `contracts/openapi/ride-service.yaml`, `contracts/events/*`.

## 1) Tổng quan service đang hoạt động như thế nào

| Thành phần | Vai trò | File chính |
|---|---|---|
| HTTP API (Express) | Nhận request tạo/chỉnh sửa/lấy chuyến đi | `src/app.js`, `src/routes/rides.js` |
| Auth + Trace + Validation | Bắt buộc JWT, gắn `x-trace-id`/`x-request-id`, validate request | `src/middleware/auth.js`, `src/middleware/trace.js`, `src/middleware/validateRequest.js` |
| MongoDB Repository | Lưu ride, lịch sử trạng thái, inbox/outbox, idempotency | `src/db/mongo.js`, `src/repository/*.js` |
| Redis | Cache response idempotency, lock idempotency, cache chống trùng event Kafka | `src/cache/redis.js`, `src/idempotency/store.js`, `src/messaging/consumer.js` |
| Kafka Consumer + Inbox Processor | Nhận sự kiện từ topic, validate schema, ghi inbox, xử lý nghiệp vụ bất đồng bộ | `src/messaging/consumer.js`, `src/messaging/inboxProcessor.js` |
| Kafka Outbox Poller + Producer | Lấy event outbox chưa publish, phát ra Kafka, retry + DLQ | `src/messaging/outboxPoller.js`, `src/messaging/producer.js` |

Luồng khởi động khi chạy service:
1. Nạp env + observability.
2. Start Kafka consumer.
3. Start `inboxProcessor` (poll định kỳ).
4. Start `outboxPoller` (poll định kỳ).
5. Mở HTTP server (mặc định cổng `3005`).

## 2) Dữ liệu nhận/truyền qua HTTP API

Tất cả endpoint dưới `/v1/rides` đều yêu cầu JWT Bearer.

| API | Nhận dữ liệu gì | Truyền dữ liệu gì | Tác động dữ liệu |
|---|---|---|---|
| `POST /v1/rides` | Header: `Authorization`, `Idempotency-Key`; Body: `pickupLat`, `pickupLng`, `dropoffLat`, `dropoffLng`, `bookingId`, `driverId`, `status`, `externalRideId` | JSON `data` ride vừa tạo (hoặc replay idempotent) | Ghi `rides`, `ride_status_history`, `idempotency_keys`; có thể ghi `outbox_events` (`RideCreated`) |
| `GET /v1/rides` | Query: `status`, `riderId`, `driverId`, `limit`, `cursor`, `sort` | JSON danh sách ride + `nextCursor` | Đọc `rides` |
| `GET /v1/rides/assignments` | Header auth (driver id trong JWT) | JSON mảng assignment cho tài xế | Đọc `rides` |
| `GET /v1/rides/external/:externalRideId` | Path `externalRideId` | JSON 1 ride | Đọc `rides` |
| `GET /v1/rides/:id` | Path `id` | JSON 1 ride | Đọc `rides` |
| `PATCH /v1/rides/:id` | Path `id`; Body: `driverId`, điểm đón/trả, `status`, `statusReason` | JSON ride sau cập nhật | Update `rides`; nếu đổi trạng thái thì ghi thêm `ride_status_history`; nếu sang `assigned` thì ghi `outbox_events` (`RideAssigned`) |
| `DELETE /v1/rides/:id` | Path `id`; body có thể có `reason` | JSON ride sau khi đổi `cancelled` | Update `rides` + ghi `ride_status_history` (+ có thể outbox tùy trạng thái) |
| `GET /v1/rides/:id/summary` | Path `id` | JSON tổng kết chuyến: quãng đường, thời lượng, fare, breakdown | Đọc `rides`, `ride_status_history`; gọi sang `payment-service` để lấy payment liên quan |

Health endpoints:
- `GET /health`
- `GET /healthz`
- `GET /readyz`

## 3) Phần Kafka (nêu rõ)

### 3.1 Chuẩn envelope sự kiện

`ride-service` dùng contract registry để validate envelope theo topic. Envelope chung bắt buộc:
- `eventId`
- `type`
- `version`
- `occurredAt`
- `payload`
- `traceId` (optional)

Nếu JSON/envelope sai chuẩn: đẩy vào `<topic>.dlq`.

### 3.2 Topic Kafka mà `ride-service` tham gia

| Topic | `ride-service` là gì | Dữ liệu nhận/truyền chính | Xử lý trong code |
|---|---|---|---|
| `ride.created` | Consumer + Producer | Payload chính: `rideId`, `bookingId`, `riderId`, `pickup`, `dropoff`, `pricing`, `timestamp` | Consumer: ghi `inbox_events`, processor tạo ride mới hoặc backfill ride đã có. Producer: phát từ outbox khi tạo ride nội bộ |
| `ride.assigned` | Consumer (subscribe) + Producer | Payload: `rideId`, `driverId`, `assignedAt` | Producer: phát khi ride chuyển sang `assigned`; Consumer hiện subscribe nhưng processor không có nhánh nghiệp vụ riêng (mặc định skipped) |
| `ride.cancelled` | Consumer | Payload: `rideId`, `reason`, `timestamp` | Processor tìm ride và chuyển trạng thái `cancelled` nếu transition hợp lệ |
| `payment.completed` | Consumer | Payload: `paymentId`, `rideId`, `amount`, `currency`, `status=PAID`, `statusUpdatedAt` | Processor cập nhật trạng thái ride sang `completed` nếu hợp lệ |
| `payment.failed` | Consumer | Payload: `paymentId`, `rideId`, `amount`, `currency`, `status=FAILED`, `failureReason` | Processor cập nhật trạng thái ride sang `cancelled` nếu hợp lệ |
| `driver.location.updated` | Consumer (subscribe) | Payload: `driverId`, `rideId`, `lat`, `lng`, `heading`, `speedKph`, `timestamp` | Đang subscribe để guard contract; chưa có xử lý nghiệp vụ cụ thể trong processor |

### 3.3 Cơ chế Consume (Kafka -> Inbox)

1. Consumer subscribe toàn bộ topic trong `src/messaging/topics.js`.
2. Mỗi message:
   - Parse JSON.
   - Validate envelope theo topic.
   - Chống trùng bằng Redis key `inbox:ride-service:<eventId>`.
   - Ghi `inbox_events` (unique `event_id + consumer`) để chống trùng ở DB.
3. Message hợp lệ sẽ được commit offset; lỗi nặng trước commit sẽ không commit (để retry theo Kafka).

### 3.4 Cơ chế Inbox Processor (Inbox -> Business)

1. Poll `inbox_events` state `pending/retry` (hoặc `processing` timeout).
2. Claim event sang `processing`.
3. Chạy xử lý theo topic:
   - `ride.created`
   - `ride.cancelled`
   - `payment.completed`
   - `payment.failed`
4. Thành công: mark `processed`.
5. Thất bại: tăng `attempt_count`, tính backoff mũ, chuyển `retry`; quá `max_attempts` -> `dead` và publish DLQ.

### 3.5 Cơ chế Outbox Publisher (Outbox -> Kafka)

1. Poll `outbox_events` trạng thái `pending/retry/failed`.
2. Claim sang `processing`.
3. Resolve topic theo `event_type`:
   - `RideCreated` -> `ride.created`
   - `RideAssigned` -> `ride.assigned`
4. Publish Kafka với key ưu tiên `rideId`/`bookingId`.
5. Thành công: mark `published`.
6. Lỗi: mark retry/backoff; quá ngưỡng -> mark `dead` + đẩy DLQ.

### 3.6 Cấu hình Kafka quan trọng

| Biến môi trường | Mặc định | Ý nghĩa |
|---|---|---|
| `KAFKA_BROKERS` | `localhost:29092` | Danh sách broker |
| `KAFKA_CONSUMER_GROUP_ID` | `ride-service-group` | Consumer group |
| `KAFKA_CONSUMER_PARTITIONS_CONCURRENCY` | `1` | Số partition xử lý đồng thời |
| `KAFKA_CONSUMER_MAX_MESSAGES_PER_BATCH` | `100` | Số message tối đa mỗi batch |
| `OUTBOX_PUBLISH_INTERVAL_MS` | `5000` | Chu kỳ poll outbox |
| `OUTBOX_PUBLISH_BATCH_SIZE` | `50` | Kích thước lô publish outbox |
| `INBOX_MAX_ATTEMPTS` / `OUTBOX_MAX_ATTEMPTS` | `10` | Số lần retry tối đa trước khi dead |

## 4) Service đang giao tiếp với service nào qua API nào

### 4.1 Giao tiếp đồng bộ (HTTP)

| Từ | Đến | API gọi | Mục đích | Dữ liệu gửi |
|---|---|---|---|---|
| `ride-service` | `payment-service` | `GET /v1/payments?rideId=<id>&limit=20&sort=-createdAt` | Lấy payment khi gọi `GET /v1/rides/:id/summary` | Header `Authorization`, `x-trace-id`, `x-request-id`; query `rideId` |

### 4.2 Giao tiếp bất đồng bộ (Kafka)

| Service liên quan | Topic liên quan đến ride-service | Ride-service nhận/gửi |
|---|---|---|
| `booking-service` | `ride.created`, `ride.cancelled` | Nhận |
| `payment-service` | `payment.completed`, `payment.failed`, `ride.created`, `ride.assigned` | Nhận `payment.*`; gửi `ride.created`/`ride.assigned` để payment-service dùng |
| `ride-service` (nội bộ) | `ride.created`, `ride.assigned`, `driver.location.updated` | Vừa subscribe vừa/hoặc publish tùy topic |

## 5) DB đang sử dụng gì? Collection như thế nào?

## 5.1 DB chính

- DB chính đang dùng trong runtime: **MongoDB** (`mongodb` Node driver), không phải PostgreSQL.
- URI mặc định trong Docker network: `mongodb://mongo:27017/ride_service`; khi truy cập từ máy host dùng port local `mongodb://localhost:42132/ride_service`.
- Tên DB resolve theo thứ tự:
  1. `MONGODB_DB`/`MONGO_DB`
  2. Tên DB trong URI
  3. fallback `ride_service`
- Hỗ trợ transaction Mongo có điều kiện; nếu môi trường không hỗ trợ transaction (không replica set), code fallback chạy không transaction.

Lưu ý: thư mục `services/ride-service/migrations/*.sql` còn tồn tại dạng SQL lịch sử, nhưng lớp repository runtime hiện tại truy cập MongoDB collections.

## 5.2 Collection chi tiết (MongoDB)

| Collection | Mục đích | Trường chính (kiểu dữ liệu) | Index/Unique |
|---|---|---|---|
| `rides` | Bản ghi chuyến đi chính | `_id:string(UUID)`, `external_ride_id:string`, `booking_id:string?`, `rider_id:string(8 số)?`, `driver_id:string(8 số)?`, `pickup_lat:number`, `pickup_lng:number`, `pickup_label:string?`, `dropoff_lat:number?`, `dropoff_lng:number?`, `dropoff_label:string?`, `quote_fare_amount:number?`, `quote_currency:string?`, `status:string`, `status_updated_at:Date`, `created_at:Date`, `updated_at:Date` | Unique `external_ride_id`; index `(rider_id, created_at desc)`; index `(status, created_at desc)` |
| `ride_status_history` | Lịch sử chuyển trạng thái | `_id:string(UUID)`, `ride_id:string`, `from_status:string?`, `to_status:string`, `reason:string?`, `actor_id:string?`, `trace_id:string?`, `occurred_at:Date`, `created_at:Date`, `updated_at:Date` | index `(ride_id, occurred_at desc)` |
| `idempotency_keys` | Lưu idempotency durable cho API POST create ride | `_id:string(UUID)`, `idempotency_key:string`, `route_key:string`, `user_id:string`, `idem_key:string`, `request_hash:string`, `response_status:number?`, `response_headers:object?`, `response_body:object?`, `locked_at:Date?`, `created_at:Date`, `updated_at:Date`, `expires_at:Date?` | Unique `(route_key, user_id, idem_key)` |
| `inbox_events` | Hàng đợi inbox để xử lý event consume | `_id:string(UUID)`, `event_id:string`, `consumer:string`, `topic:string`, `event_type:string`, `trace_id:string?`, `payload:object`, `state:string(pending/retry/processing/processed/dead)`, `attempt_count:number`, `max_attempts:number`, `next_retry_at:Date`, `processing_started_at:Date?`, `processing_owner:string?`, `received_at:Date`, `processed_at:Date?`, `error_message:string?`, `created_at:Date`, `updated_at:Date` | Unique `(event_id, consumer)`; index `(topic, received_at desc)`; index `(state, next_retry_at, received_at)` |
| `outbox_events` | Hàng đợi outbox để publish Kafka | `_id:string(UUID)`, `event_id:string`, `aggregate_type:string`, `aggregate_id:string`, `event_type:string`, `topic:string?`, `payload:object`, `status:string(pending/retry/processing/published/dead)`, `attempt_count:number`, `max_attempts:number`, `next_retry_at:Date`, `processing_started_at:Date?`, `processing_owner:string?`, `last_error:string?`, `last_error_at:Date?`, `dlq_topic:string?`, `dlq_payload:object?`, `occurred_at:Date`, `published_at:Date?`, `created_at:Date`, `updated_at:Date` | Unique `event_id`; index `(status, next_retry_at, occurred_at)` |

## 5.3 Redis dùng cho gì?

| Key pattern | Mục đích | TTL |
|---|---|---|
| `idempo:<routeKey>:<userId>:<idempotencyKey>` | Cache response idempotency cho HTTP create ride | 24 giờ |
| `idempo:lock:<routeKey>:<userId>:<idempotencyKey>` | Lock chống xử lý đồng thời cùng idempotency key | 10 giây |
| `inbox:ride-service:<eventId>` | Cache chống consume trùng event Kafka | 24 giờ (mặc định) |

## 6) Ma trận “nhận gì - truyền gì” (tổng hợp)

| Kênh | Nhận vào | Xử lý | Truyền ra |
|---|---|---|---|
| HTTP `POST /v1/rides` | Dữ liệu tạo ride từ client/app | Validate + idempotency + ghi DB + ghi outbox | Response ride; sau đó outbox có thể phát Kafka `ride.created` |
| Kafka `ride.created` | Dữ liệu tạo ride từ booking-service | Ghi inbox, processor tạo/backfill ride | Cập nhật DB ride nội bộ |
| Kafka `payment.completed` | Kết quả thanh toán thành công | Ghi inbox, processor cập nhật trạng thái ride -> completed | Cập nhật DB + status history |
| Kafka `payment.failed` | Kết quả thanh toán thất bại | Ghi inbox, processor cập nhật trạng thái ride -> cancelled | Cập nhật DB + status history |
| HTTP `GET /v1/rides/:id/summary` | Yêu cầu xem tổng kết chuyến | Đọc ride + status history + gọi payment-service | Response summary gồm fare/breakdown |
| Outbox poller | Event nội bộ chờ phát | Validate contract + publish Kafka | Sự kiện `ride.created` / `ride.assigned` hoặc DLQ |

## 7) Đề xuất cải tiến (nếu có)

| Mục cải tiến | Hiện trạng | Đề xuất |
|---|---|---|
| Đồng bộ tài liệu API | `contracts/openapi/ride-service.yaml` chưa phản ánh đủ route runtime như `/v1/rides/assignments`, `/v1/rides/external/:externalRideId` | Cập nhật OpenAPI contract để tránh lệch client/server |
| Tối ưu subscribe Kafka | Service đang subscribe `ride.assigned` và `driver.location.updated` nhưng processor chưa xử lý nghiệp vụ tương ứng | Nếu chưa dùng thì bỏ subscribe; hoặc bổ sung handler rõ ràng + retention strategy |
| Quản trị tăng trưởng dữ liệu | `inbox_events`, `outbox_events`, `idempotency_keys` tăng dần theo thời gian | Thêm TTL cleanup job/archive policy định kỳ |
| Tối ưu index theo truy vấn tài xế | Truy vấn active assignment dùng `driver_id + status + status_updated_at` | Cân nhắc thêm index phù hợp cho luồng driver assignment |
| Đồng bộ kiến trúc DB | Repo runtime là MongoDB nhưng vẫn còn migration SQL lịch sử | Tách rõ thư mục legacy hoặc ghi chú chính thức để tránh hiểu nhầm DB engine |

---

Nếu cần, có thể tách tiếp thành 2 tài liệu riêng:
1. “Sơ đồ luồng nghiệp vụ ride-service” (sequence theo từng use case).  
2. “Data contract chi tiết theo từng topic Kafka” (kèm ví dụ JSON đầy đủ).
