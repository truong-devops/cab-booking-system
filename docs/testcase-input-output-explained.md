# Giai Thich Input / Output Test Case Postman

Tai lieu nay tom tat bo test trong `scripts/postman/*.postman_collection.json` va doi chieu voi `scripts/test-level*-cases.sh`.

## Cach Doc Chung

- `baseUrl`: API Gateway, mac dinh `http://localhost:3000`.
- `aiUrl`, `etaUrl`, `pricingUrl`, `bookingUrl`: goi truc tiep service khi test hieu nang/noi bo. Luu y trong Postman `bookingUrl` dang de `http://localhost:3002`, trong docker-compose va gateway hien tai booking-service la `3003`.
- Cac bien `{{userToken}}`, `{{adminToken}}`, `{{driverToken}}` duoc lay sau request login.
- Output trong bang la output ky vong cua test: status HTTP, field quan trong, hoac tinh chat can dam bao.

## API Output Chuan Hay Gap

| Nhom API | Input chinh | Output chinh |
| --- | --- | --- |
| Auth register/login | email/identifier, password, role | `data` user va `tokens.accessToken`/refresh token |
| Booking | pickup, drop/dropoff, vehicleType, payment_method, idempotency key | `booking`/`data` co `booking_id`, `status`, gia/ETA/event neu thanh cong |
| Driver | driver profile, vehicle, online status, location | `data.driver`, trang thai APPROVED/ONLINE, danh sach driver kha dung |
| ETA | `distance_km` hoac pickup/drop, `traffic_level` | `data.distance_km`, `data.traffic_level`, `data.eta_minutes` |
| Pricing | `distance_km`, demand/supply hoac quote pickup/dropoff | quote/fare/surge/price snapshot |
| Notification | `user_id`, message/items | notification id, status, channel status |
| Payment | rideId, amount, currency, userId | payment id, status; idempotent replay khong tao duplicate |
| AI | feature/candidates/context | recommendation/score/forecast/selected_driver, trace/log/fallback metadata |

## Level 1: Happy Path Co Ban

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 1 | `POST /v1/auth/register` voi email, username, password, name | 201/200; neu user da co thi 409 | Tao user moi |
| 2 | `POST /v1/auth/login` voi identifier + password | 200, tra token va userId | Dang nhap de lay JWT |
| 3 | `POST /v1/bookings` pickup/drop/distance | 200/201, co bookingId/status | Tao booking hop le |
| 4 | `GET /v1/bookings?user_id={{userId}}` | 200, danh sach booking | Xem lich su booking cua user |
| 5 | Tao driver, approve, dang ky xe, set ONLINE, check availability | 200/201/409 tuy buoc; availability 200 | Chuan bi driver san sang nhan chuyen |
| 6 | `GET /v1/bookings/{{bookingId}}` | 200, booking vua tao | Doc lai booking va trang thai |
| 7 | `POST /v1/eta/estimate` distance=5, traffic=0.5 | 200, ETA hop le | Kiem tra tinh ETA |
| 8 | `POST /v1/pricing/estimate` distance=5, demand=1 | 200, gia/surge hop le | Kiem tra tinh gia |
| 9 | `POST /v1/notifications` user_id + message | 200/201, tao notification | Gui thong bao |
| 10 | `POST /v1/auth/logout`, sau do goi API bang token cu | logout 200, token cu 401/403 | Logout phai vo hieu hoa token |

## Level 2: Validation, Edge Case, Idempotency

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 11 | Booking thieu `pickup` | 400/422 | Validate field bat buoc |
| 12 | `pickup.lat` la chuoi `"abc"` | 400/422 | Validate kieu du lieu toa do |
| 13 | Booking tai khu vuc khong co driver online | 200/201 hoac 404/409 | He thong xu ly no-driver area |
| 14 | `payment_method="invalid_card"` | 400/422 | Tu choi payment method sai |
| 15 | ETA `distance_km=0` | 200 | Pickup=drop van khong crash |
| 16 | Pricing demand=0, supply=1 | 200 | Gia luc off-peak |
| 17 | Fraud check chi co `user_id` | 400/422 | Thieu feature fraud |
| 18 | Booking bang expired token | 401 | Bao ve endpoint bang JWT |
| 19 | Gui cung booking payload/idempotency 2 lan | 200/201 ca hai, khong tao duplicate logic | Idempotency |
| 20 | Payload JSON > 1MB | 400/413/422 | Gioi han kich thuoc request |

## Level 3: Tich Hop Service

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 21 | Tao booking binh thuong | 200/201 | Booking goi ETA trong flow |
| 22 | Tao booking voi toa do khac | 200/201 | Booking goi Pricing trong flow |
| 23 | `POST /v1/bookings/ai/select-driver` pickup + vehicleType | 200, co driver duoc chon | AI/matching chon driver |
| 24 | Booking + `payment_method=CASH` | 200/201 | Flow booking-payment-notification |
| 25 | Tao booking moi | 200/201, co event | Publish event ride/requested/created |
| 26 | `PATCH /v1/bookings/{id}/status` sang ACCEPTED | 200/2xx | Driver accept booking |
| 27 | Lay notification va booking status | 200/2xx | Notification va status duoc persist |
| 28 | `GET /v1/bookings/{id}/mcp-context` | 200 hoac 404 | Lay context cho AI/MCP |
| 29 | Tao booking qua gateway | 200/201 | Gateway route dung booking-service |
| 30 | Booking `simulate_pricing_timeout=true` | 200/201 hoac 504 | Retry/fallback khi pricing cham |

## Level 4: Transaction, Saga, Consistency

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 31 | Booking hop le | 200/201 | Transaction tao booking thanh cong |
| 32 | Booking `simulate_tx_failure_after_insert=true` | 400/500 va rollback | Loi sau insert khong de du lieu ban |
| 33 | Booking card + `simulate_payment_failure=true` | 200/201/402/500 tuy flow | Payment fail can cancel/compensate |
| 34 | Booking CASH gui lai cung idempotency | 200/201, cung ket qua logic | Retry khong tao booking trung |
| 35 | Hai booking song song | 200/201/409 | Xu ly race condition |
| 36 | Booking CASH full flow | 200/201 | Saga thanh cong |
| 37 | Booking VIETQR + payment timeout/fail | 200/201 va compensation | Saga fail phai bu tru |
| 38 | Tao booking | 200/201, co outbox/event signal | DB update va publish event nhat quan |
| 39 | Booking + payment timeout | 200/201/504 | Partial failure co retry/fallback |
| 40 | Booking `distance_km=-1` | 400/422 | Du lieu sai bi reject de giu consistency |

## Level 5: AI Model APIs

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 41 | ETA distance=5, traffic=0.5 | 200, ETA trong range hop ly | AI/ETA prediction binh thuong |
| 42 | Pricing demand_index=2 | 200, surge cao hon baseline | Surge pricing khi nhu cau cao |
| 43 | Fraud features amount/route_risk cao | 200, co fraud score/risk | Cham diem gian lan |
| 44 | Driver candidates | 200, top 3 recommendation | Goi y tai xe |
| 45 | Forecast zone/horizon/timestamp | 200, demand forecast | Du bao nhu cau |
| 46 | Forecast model_version v1 va v2 | 200 ca hai | Versioning model |
| 47 | Nhieu request forecast | Khong 5xx, latency dat nguong script | AI latency under load |
| 48 | Drift check features la/khac distribution | 200, drift result | Phat hien drift |
| 49 | Recommend drivers + `simulate_model_error=true` | 200, fallback | Model loi van co ket qua |
| 50 | ETA/Pricing distance=1000 | Khong 5xx | Outlier input khong lam sap service |

## Level 6: AI Agent Select Driver

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 51 | Candidates D1 5km, D2 2km, D3 3km; objective nearest | 200, chon D2 | Chon tai xe gan nhat dang online |
| 52 | Candidates co rating khac nhau; objective highest_rating | 200, chon driver rating cao | Strategy theo rating |
| 53 | Candidate A nhanh hon, B re hon; objective balanced_eta_price | 200, co score va chon A/B hop ly | Can bang ETA va gia |
| 54 | Hai probe: ETA-focused va Pricing-focused | 200, tool_calls dung muc tieu | Agent goi dung tool can thiet |
| 55 | Candidate thieu context/features | 200, khong crash, co fallback/enrich | Chiu duoc du lieu thieu |
| 56 | `simulate_tool_error=true` | 200, retry_count/tool attempts > 1 | Retry khi tool loi |
| 57 | Danh sach co driver offline gan nhat | 200, khong chon offline | Rang buoc hard constraint |
| 58 | POST select-driver co `x-trace-id`, sau do GET decision | 200/200, log co trace/objective/reason/scores | Audit decision |
| 59 | Nhieu request agent song song | Tat ca 200, trace rieng, strategy on dinh | Concurrency cua agent |
| 60 | `simulate_model_error=true` | 200, `fallback_used=true` | Rule-based fallback khi model fail |

## Level 7: Load, Cache, Performance

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 61 | Load POST booking, muc tieu script ~1000 RPS | success_rate/p95/RPS dat nguong, khong 5xx | Booking throughput |
| 62 | Load ETA ~500 RPS | p95 va success_rate dat nguong | ETA performance |
| 63 | Pricing spike ~800 RPS | p95/success_rate/5xx dat nguong | Pricing chiu spike |
| 64 | Produce nhieu event ride.created | topic delta/lag dat nguong | Kafka throughput |
| 65 | GET bookings concurrency cao | 5xx rate thap | DB pool stability |
| 66 | Tao quote roi doc quote lap lai | quote 200/201, cache hit/gain dat nguong | Cache pricing quote |
| 67 | Burst login sai password | Co 429 theo nguong, khong 5xx | Gateway rate limit |
| 68 | ETA qua gateway duoi load | p95 <= nguong | Latency qua gateway |
| 69 | Peak booking ramp-up | p95 khong degrade qua nguong | Tai gio cao diem |
| 70 | POST vao autoscale target | Khong 5xx; script co local-dev exemption | Autoscaling target |

## Level 8: Failure & Resilience

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 71 | Booking khi driver service fault/down | Khong 5xx | Fallback khi driver dependency loi |
| 72 | Booking khi pricing timeout | Khong 5xx | Retry/fallback pricing |
| 73 | Booking khi Kafka down | Khong 5xx, outbox/buffer | Event khong lam sap request |
| 74 | Booking sau DB recovery/failover | Recovery trong timeout, request sau consistent | Phuc hoi DB |
| 75 | GET pricing quote loi lap lai | Fail fast trong nguong, khong 5xx collapse | Circuit breaker |
| 76 | Booking trong partial outage | Khong 5xx | He thong van degrade duoc |
| 77 | Backoff attempts 1s,2s,4s... | Health 200 va policy dung | Exponential backoff |
| 78 | Booking khi mesh route fault | Khong 5xx | Fallback route |
| 79 | Pricing sau network partition | Khong 5xx va recover | Partition recovery |
| 80 | Booking khi overload/failure | Khong 5xx | Graceful degradation |

## Level 9: Security 81-90

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 81 | SQL injection vao login/query/path | Login 400/401; query/path khong success 200/201; khong leak loi DB | Chong SQL injection |
| 82 | XSS payload trong `vehicle_type` | 200/201/400/422 nhung response khong reflect script | Chong XSS/reflection |
| 83 | JWT sai signature/role tamper/malformed | 401 | Chong tamper JWT |
| 84 | USER goi `/v1/admin/drivers`; admin baseline | User 403, admin 200 | RBAC admin |
| 85 | Spam POST booking | 200/201/400/422/429, khong 5xx | Rate-limit/anti-abuse |
| 86 | Payment replay cung rideId/amount/userId | Replay tra cung payment id hoac count tang toi da 1 | Chong replay/duplicate charge |
| 87 | Evidence encryption-at-rest | Can file evidence/script xac nhan | Du lieu nhay cam ma hoa khi luu |
| 88 | Evidence mTLS service-to-service | Can evidence reject request khong cert | Giao tiep noi bo can mTLS |
| 89 | DRIVER goi admin API; admin baseline | Driver 403, admin 200 va data array | RBAC voi driver |
| 90 | Invalid token, payment note co card, unknown route | 401/403/404; khong leak secret/card full | Mask sensitive data |

## Level 10: Zero Trust 91-100

| Case | Input | Output/Ky vong | Y nghia |
| --- | --- | --- | --- |
| 91 | GET bookings khong Authorization | 401/403 | Bat buoc co token |
| 92 | JWT bi tamper | 401 | Verify chu ky token |
| 93 | JWT expired | 401 | Check `exp` |
| 94 | mTLS evidence note/health | Health 200 + evidence file trong script | Service-to-service cert policy |
| 95 | USER goi admin API, admin baseline | User 403, admin 200 | RBAC user/admin |
| 96 | DRIVER doc user khac | 401/403/404 | Least privilege |
| 97 | Goi truc tiep booking-service, khong qua gateway | 401/403/404 ke ca co user token | Chan bypass gateway/internal auth |
| 98 | Burst login sai password | Co 429 theo script, khong 5xx/timeout flood | Rate limit auth |
| 99 | Probe HTTPS `/health` | HTTPS 200; script so sanh HTTP/HTTPS | Encryption in transit |
| 100 | Login va API co trace/audit | 200/204, log/audit trace duoc ghi | Audit logging |

## Luu Y Khi Chay Postman

1. Chay setup register/login dau collection de Postman tu set token.
2. Neu test direct service fail do port, doi `bookingUrl` tu `3002` sang `3003` theo `infra/docker-compose.dev.yml`.
3. Cac case 87, 88, 94, 99 phu thuoc evidence/TLS/mTLS, khong chi la request JSON binh thuong.
4. Postman thuong check status rong hon script shell; script `scripts/test-level*-cases.sh` la ban strict hon de cham diem.
