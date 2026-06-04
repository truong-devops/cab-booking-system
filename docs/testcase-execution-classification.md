# Phan Loai Cach Test 100 Case

Tai lieu nay loc 100 case thanh 3 nhom:

1. **Postman hoan toan**: chi can Postman collection, request/response va test script trong Postman la du bang chung.
2. **Khong dung Postman duoc, phai dung tool khac**: Postman chi gui request don le nen khong chung minh duoc muc tieu chinh nhu load, p95, concurrency, mTLS, encryption-at-rest, autoscale, log runtime.
3. **Dung ca Postman va tool khac**: Postman dung de kich hoat flow/smoke test, nhung can them Docker/Kafka/Redis/log/DB/tool do tai de chung minh side effect hoac resilience.

## Nhom 1: Test Bang Postman Hoan Toan

Cac case nay la API functional/validation/security theo request-response. Co the import collection trong `scripts/postman`, set bien token, chay va lay response lam bang chung.

| Case | Ly do Postman du |
| --- | --- |
| 1-10 | Register, login, booking, list, driver online, ETA, pricing, notification, logout deu co the assert bang status/body/follow-up request. |
| 11-20 | Validation, expired token, payload too large, idempotency deu co the test bang status/body va bien Postman. |
| 21-24 | Booking goi ETA/Pricing/AI/payment-notification flow co response de check thanh cong. |
| 26-31 | Accept booking, notification/readback, MCP context, gateway route, pricing fallback, transaction create success deu la HTTP + readback. |
| 34 | Gui duplicate/idempotency 2 lan va so sanh booking/payment id trong Postman. |
| 41-46 | ETA, surge, fraud, recommendation, forecast, model version la API AI request-response. |
| 48-50 | Drift, fallback model, abnormal input chi can check status/body khong 5xx. |
| 51-58 | AI agent select-driver; Postman co the assert selected_driver, strategy, tool_calls, trace decision GET. |
| 60 | AI model fail nhung fallback response co `fallback_used`. |
| 81-84 | SQL injection, XSS, JWT tamper, RBAC user/admin deu assert status/body/no sensitive leak. |
| 86 | Replay payment: list before, post first, replay, list after; Postman co the so sanh id/count. |
| 89 | Driver bi cam goi admin API, admin duoc goi: status 403/200. |
| 91-93 | Missing/tampered/expired token: status 401. |
| 95-97 | RBAC user/admin, least privilege, bypass gateway deu la HTTP deny/allow checks. |

**Danh sach nhanh:** `1-24, 26-31, 34, 41-46, 48-58, 60, 81-84, 86, 89, 91-93, 95-97`.

## Nhom 2: Khong The Chung Minh Bang Postman, Phai Dung Tool Khac

Cac case nay co muc tieu chinh la do tai, song song, p95, runtime policy hoac ha tang. Postman co the gui request mau, nhung khong du lam bang chung cham diem.

| Case | Tool nen dung | Vi sao Postman khong du |
| --- | --- | --- |
| 35 | Script Node/shell, k6, autocannon | Can 2 request that su song song de bat race condition. |
| 47 | Script latency/k6/autocannon | Can nhieu samples va tinh p95 latency. |
| 59 | Script Node parallel runner | Can nhieu request parallel, trace rieng, check race/conflict. |
| 61 | Load runner trong `scripts/test-level7...`, k6/autocannon | Can ~1000 RPS booking, success rate, p95. |
| 62 | Load runner | Can ~500 RPS ETA va p95. |
| 63 | Load runner | Can pricing spike, RPS, p95, 5xx rate. |
| 65 | Load runner | Can stress DB connection pool bang concurrency/RPS cao. |
| 67 | Load runner | Can burst login de chung minh 429 rate-limit. |
| 68 | Load runner | Can p95 latency qua gateway. |
| 69 | Load runner | Can ramp-up gio cao diem va so sanh p95 theo stage. |
| 70 | Docker Swarm/Kubernetes HPA + load runner | Can bang chung scale up/down, Postman khong quan sat autoscale. |
| 77 | Node/unit-level script | Case nay doc ham `computeRetryDelayMs`, khong phai API endpoint. |
| 85 | Load/security runner | Can spam >1000 req/s va dem 429/5xx, Postman runner thuong khong du. |
| 87 | DB/storage/KMS evidence, docker/OS command | Encryption at rest la bang chung ha tang, khong phai response API. |
| 88 | openssl/curl, service mesh/PKI logs | mTLS can handshake/cert-chain/reject no-cert evidence. |
| 94 | openssl/curl, mesh/PKI/runtime evidence | Service-to-service mTLS khong the chung minh bang health request Postman. |
| 98 | Script burst runner | Can concurrency va count 429/no 5xx cho auth rate limit. |
| 99 | curl/openssl/TLS probe | Can chung minh HTTP bi reject va HTTPS/TLS hoat dong. |

**Danh sach nhanh:** `35, 47, 59, 61-63, 65, 67-70, 77, 85, 87, 88, 94, 98, 99`.

## Nhom 3: Dung Ca Postman Va Tool Khac De Chung Minh

Cac case nay Postman rat huu ich de tao request/kich hoat flow. Nhung neu muon bao cao chat, can them bang chung tu Kafka, Redis, Docker Compose, DB/log, hoac fault injection.

| Case | Postman lam gi | Tool khac chung minh gi |
| --- | --- | --- |
| 25 | Tao booking de publish event | Kafka/topic/outbox co event `ride_requested`/`ride.created`. |
| 32 | Gui request `simulate_tx_failure_after_insert` | DB/read count/log de chung minh rollback, khong co record ban. |
| 33 | Tao booking co payment failure | Payment/log/DB de chung minh compensation, no-charge/cancel. |
| 36 | Kich hoat saga success | Log/payment/notification/event de chung minh cac buoc saga hoan tat. |
| 37 | Kich hoat saga failure | Payment update/log/DB de chung minh booking CANCELLED/FAILED va compensation. |
| 38 | Tao booking co outbox signal | DB outbox/Kafka topic de chung minh event duoc ghi va publish nhat quan. |
| 39 | Tao booking khi payment timeout | Log/retry/payment state de chung minh khong ket state. |
| 40 | Gui invalid + doc lai state | Ket hop bang chung atomic/consistent/isolated/durable tu case 33/35/readback. |
| 64 | Goi `/demo/ride-created` hoac Postman producer request | Kafka offset delta va consumer lag. |
| 66 | Tao/read pricing quote | Redis stats `keyspace_hits/misses`, hit rate, p95 cached read. |
| 71 | Gui booking khi driver-service fault | Docker Compose stop service + response fallback. |
| 72 | Gui booking khi pricing timeout/down | Docker Compose fault + response fallback/default quote. |
| 73 | Gui booking khi Kafka down | Docker stop Kafka + outbox queued/pending marker. |
| 74 | Gui booking sau restart DB | Docker restart Postgres + recovery within timeout + follow-up request. |
| 75 | Goi pricing quote loi lap lai | Docker stop pricing + latency/status de chung minh circuit breaker fail-fast. |
| 76 | Gui booking khi driver + ETA down | Docker fault injection + response degrade hop le. |
| 78 | Gui booking khi pricing route bi pause | Docker pause/unpause + fallback route response. |
| 79 | Gui booking trong network partition | Docker pause/unpause + pricing recover + booking sau recovery. |
| 80 | Gui booking khi nhieu dependency down | Docker stop nhieu service + response graceful degradation. |
| 90 | Gui invalid token/payment note/unknown route | Docker logs gateway/payment de chung minh mask card/secret trong log. |
| 100 | Gui login/API voi `x-trace-id` | Docker logs api-gateway co audit event, actorId, action, timestamp, traceId. |

**Danh sach nhanh:** `25, 32, 33, 36-40, 64, 66, 71-76, 78-80, 90, 100`.

## Goi Y Cach Trinh Bay Khi Bao Cao

- **Postman hoan toan**: chup man hinh request, response body, status code, tab Tests passed.
- **Tool khac**: dinh kem output terminal cua script, vi du `scripts/test-level7-61-70cases.sh`, `docker logs`, `kafka-consumer-groups`, `redis-cli INFO stats`, `curl -vk`/`openssl s_client`.
- **Ca 2**: chup Postman de chung minh input/API flow, sau do them terminal evidence de chung minh side effect that su.

## Luu Y Quan Trong

- Cac Postman collection co bien `bookingUrl=http://localhost:3002`, nhung config hien tai booking-service trong `infra/docker-compose.dev.yml` va gateway la port `3003`. Khi test direct booking-service, nen sua `bookingUrl` thanh `http://localhost:3003`.
- Script shell strict hon Postman. Neu Postman pass nhung script fail, khi cham diem nen uu tien script vi script kiem tra them p95, rollback, Kafka lag, Redis hit rate, Docker fault injection hoac log evidence.
