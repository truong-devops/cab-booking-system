# API Inventory

This inventory is derived from code in the repository (routes/controllers/middleware) and the generated OpenAPI specs in `docs/openapi/*.openapi.yaml`. No endpoints were inferred from external docs.

## Services Discovered

| Service              | Location                        | Framework | Base Paths                                       |
| -------------------- | ------------------------------- | --------- | ------------------------------------------------ |
| api-gateway          | `services/api-gateway`          | Express   | `/health`, `/healthz`, `/readyz`, `/v1/{domain}` |
| auth-service         | `services/auth-service`         | Express   | `/auth/*`                                        |
| booking-service      | `services/booking-service`      | Express   | `/v1/bookings/*`, `/demo/ride-created`           |
| driver-service       | `services/driver-service`       | Express   | `/v1/driver/*`, `/v1/admin/*`, `/v1/internal/*`  |
| eta-service          | `services/eta-service`          | Express   | `/v1/eta/*`                                      |
| places-service       | `services/places-service`       | Express   | `/v1/places/*`                                   |
| notification-service | `services/notification-service` | Express   | `/v1/notifications/*`, `/v1/users/*`             |
| payment-service      | `services/payment-service`      | Express   | `/v1/payments/*`                                 |
| pricing-service      | `services/pricing-service`      | Express   | `/v1/pricing/*`                                  |
| review-service       | `services/review-service`       | Express   | `/v1/reviews/*`                                  |
| ride-service         | `services/ride-service`         | Express   | `/v1/rides/*`                                    |
| user-service         | `services/user-service`         | Express   | `/v1/users/*`, `/internal/users/*`               |

## Gateway Domain Mapping

The gateway calls upstream services through internal service DNS and internal ports. For normal local access from your machine, call the gateway at `http://localhost:42100`; direct `421xx` service ports are debug-only shortcuts from `infra/docker-compose.dev.yml`.

| Gateway Domain                      | Upstream Service     | Upstream Base                | Notes                                                       |
| ----------------------------------- | -------------------- | ---------------------------- | ----------------------------------------------------------- |
| auth                                | auth-service         | `http://auth-service:4001`   | `/v1/auth/*` rewrites to `/auth/*`                          |
| bookings                            | booking-service      | `http://booking-service:3003` | Pass-through                                                |
| driver / drivers / admin / internal | driver-service       | `http://driver-service:3011` | Pass-through                                                |
| eta                                 | eta-service          | `http://eta-service:3012`    | Pass-through                                                |
| places                              | places-service       | `http://places-service:3014` | Pass-through                                                |
| notifications                       | notification-service | `http://notification-service:3010` | `/v1/notifications/users/*` rewrites to `/v1/users/*` |
| payments                            | payment-service      | `http://payment-service:3007` | Pass-through                                                |
| pricing                             | pricing-service      | `http://pricing-service:3006` | Pass-through                                                |
| reviews                             | review-service       | `http://review-service:3009` | Pass-through                                                |
| rides                               | ride-service         | `http://ride-service:3005`   | Pass-through                                                |
| users                               | user-service         | `http://user-service:4004`   | Pass-through (internal endpoints not reachable via gateway) |

## Endpoint Inventory (Service → Endpoint → Auth → Models)

### api-gateway

| Method                    | Path                  | Auth                               | Request Model | Response Model          |
| ------------------------- | --------------------- | ---------------------------------- | ------------- | ----------------------- |
| GET                       | `/health`             | Public                             | —             | `{ ok: boolean }`       |
| GET                       | `/healthz`            | Public                             | —             | `{ ok: boolean }`       |
| GET                       | `/readyz`             | Public                             | —             | `{ ok: boolean }`       |
| GET/POST/PUT/PATCH/DELETE | `/v1/{domain}`        | Bearer JWT (except public domains) | Pass-through  | Pass-through (upstream) |
| GET/POST/PUT/PATCH/DELETE | `/v1/{domain}/{path}` | Bearer JWT (except public domains) | Pass-through  | Pass-through (upstream) |

### auth-service

| Method | Path             | Auth                    | Request Model                | Response Model                           |
| ------ | ---------------- | ----------------------- | ---------------------------- | ---------------------------------------- |
| POST   | `/auth/register` | Public                  | inline (email/password/role) | `{ data: AuthUser, tokens: AuthTokens }` |
| POST   | `/auth/login`    | Public                  | inline (identifier/password) | `{ data: AuthUser, tokens: AuthTokens }` |
| POST   | `/auth/refresh`  | Bearer or refresh token | inline (refreshToken)        | `{ tokens: AuthTokens }`                 |
| POST   | `/auth/logout`   | Bearer                  | inline (refreshToken)        | `{ ok: true }`                           |
| POST   | `/auth/verify`   | Bearer                  | —                            | `{ data: AuthUser }`                     |

### booking-service

| Method | Path                       | Auth          | Request Model                                                                                           | Response Model                                             |
| ------ | -------------------------- | ------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| GET    | `/v1/bookings`             | Bearer        | query `user_id` (optional)                                                                              | `{ data: Booking[] }`                                      |
| POST   | `/v1/bookings`             | Bearer        | inline `{ pickup, drop/dropoff, distance_km, traffic_level, vehicleType }` + optional `Idempotency-Key` | `{ booking: Booking, publishedEvent, additionalEvents[] }` |
| GET    | `/v1/bookings/{id}`        | Bearer        | —                                                                                                       | `{ data: Booking }`                                        |
| POST   | `/v1/bookings/{id}/cancel` | Bearer        | —                                                                                                       | `{ booking: Booking, publishedEvent: PublishedEvent }`     |
| POST   | `/demo/ride-created`       | Internal demo | —                                                                                                       | `{ ok: true }`                                             |

### eta-service

| Method | Path               | Auth                                   | Request Model                          | Response Model                                          |
| ------ | ------------------ | -------------------------------------- | -------------------------------------- | ------------------------------------------------------- |
| POST   | `/v1/eta/estimate` | Bearer (via gateway) / direct internal | `{ pickup/drop }` or `{ distance_km }` | `{ data: { distance_km, traffic_level, eta_minutes } }` |

### driver-service

| Method | Path                                             | Auth           | Request Model                    | Response Model                     |
| ------ | ------------------------------------------------ | -------------- | -------------------------------- | ---------------------------------- |
| GET    | `/v1/driver/me`                                  | Bearer         | —                                | `{ data: DriverProfile }`          |
| PUT    | `/v1/driver/me`                                  | Bearer         | DriverUpdateRequest              | `{ data: DriverProfile }`          |
| PUT    | `/v1/driver/me/vehicle`                          | Bearer         | VehicleUpdateRequest             | `{ data: VehicleResponse }`        |
| POST   | `/v1/driver/me/online`                           | Bearer         | —                                | `{ data: DriverProfile }`          |
| POST   | `/v1/driver/me/offline`                          | Bearer         | —                                | `{ data: DriverProfile }`          |
| POST   | `/v1/driver/me/location`                         | Bearer         | LocationUpdateRequest            | `{ ok: true }`                     |
| POST   | `/v1/driver/me/heartbeat`                        | Bearer         | —                                | `{ ok: true }`                     |
| POST   | `/v1/admin/drivers`                              | Bearer (admin) | AdminCreateDriverRequest         | `{ data: { driver, created } }`    |
| GET    | `/v1/admin/drivers`                              | Bearer (admin) | —                                | `{ data: { items, page, limit } }` |
| PATCH  | `/v1/admin/drivers/{driverId}/approve`           | Bearer (admin) | —                                | `{ data: { driver } }`             |
| PATCH  | `/v1/admin/drivers/{driverId}/suspend`           | Bearer (admin) | —                                | `{ data: { driver } }`             |
| GET    | `/v1/internal/drivers/available`                 | Internal       | query: pickupLat/pickupLng/limit | `{ data: AvailableDriver[] }`      |
| GET    | `/v1/internal/drivers/{driverId}`                | Internal       | —                                | `{ data: { driver, vehicle } }`    |
| GET    | `/v1/internal/drivers/{driverId}/location`       | Internal       | —                                | `{ data: { location } }`           |
| POST   | `/v1/internal/drivers/{driverId}/mark-busy`      | Internal       | `{ rideId }`                     | `{ data: { driver, rideId } }`     |
| POST   | `/v1/internal/drivers/{driverId}/mark-available` | Internal       | —                                | `{ data: { driver } }`             |
| POST   | `/v1/internal/drivers/bulk`                      | Internal       | `{ ids }`                        | `{ data: items[] }`                |

### places-service

| Method | Path                      | Auth   | Request Model                                               | Response Model               |
| ------ | ------------------------- | ------ | ----------------------------------------------------------- | ---------------------------- |
| GET    | `/v1/places/autocomplete` | Bearer | query `q`, `limit`, optional `lat`, `lng`                  | `{ data: { items[] } }`      |
| GET    | `/v1/places/recent`       | Bearer | query `limit`; user resolved from `x-user-id`              | `{ data: { items[] } }`      |
| POST   | `/v1/places/recent`       | Bearer | `{ label }` or `{ place: { label, address, location } }`   | `{ ok: true, data: items[] }` |

### notification-service

| Method | Path                               | Auth   | Request Model             | Response Model             |
| ------ | ---------------------------------- | ------ | ------------------------- | -------------------------- |
| POST   | `/v1/notifications`                | Bearer | NotificationCreateRequest | NotificationCreateResponse |
| POST   | `/v1/notifications/batch`          | Bearer | NotificationBatchRequest  | `{ results[] }`            |
| GET    | `/v1/notifications/{id}`           | Bearer | —                         | NotificationResponse       |
| POST   | `/v1/notifications/{id}/retry`     | Bearer | —                         | NotificationResponse       |
| PATCH  | `/v1/notifications/{id}/cancel`    | Bearer | —                         | NotificationResponse       |
| GET    | `/v1/users/{userId}/notifications` | Bearer | query filters             | NotificationListResponse   |
| GET    | `/v1/users/{userId}/preferences`   | Bearer | —                         | PreferencesResponse        |
| PUT    | `/v1/users/{userId}/preferences`   | Bearer | `{ channels }`            | PreferencesResponse        |

### payment-service

| Method | Path                             | Auth   | Request Model        | Response Model           |
| ------ | -------------------------------- | ------ | -------------------- | ------------------------ |
| GET    | `/v1/payments`                   | Bearer | query filters        | `{ data[], nextCursor }` |
| POST   | `/v1/payments`                   | Bearer | PaymentCreateRequest | `{ data: Payment }`      |
| GET    | `/v1/payments/{id}`              | Bearer | —                    | `{ data: Payment }`      |
| PATCH  | `/v1/payments/{id}`              | Bearer | PaymentUpdateRequest | `{ data: Payment }`      |
| GET    | `/v1/payments/{id}/vietqr-codes` | Bearer | —                    | VietQRResponse           |

### pricing-service

| Method | Path                           | Auth   | Request Model        | Response Model        |
| ------ | ------------------------------ | ------ | -------------------- | --------------------- |
| POST   | `/v1/pricing/quotes`           | Bearer | QuoteRequest         | QuoteResponse         |
| GET    | `/v1/pricing/quotes/{quoteId}` | Bearer | —                    | QuoteResponse         |
| POST   | `/v1/pricing/finalize`         | Bearer | QuoteFinalizeRequest | QuoteFinalizeResponse |

### review-service

| Method | Path               | Auth   | Request Model       | Response Model           |
| ------ | ------------------ | ------ | ------------------- | ------------------------ |
| GET    | `/v1/reviews`      | Bearer | query filters       | `{ data[], nextCursor }` |
| POST   | `/v1/reviews`      | Bearer | ReviewCreateRequest | `{ data: Review }`       |
| GET    | `/v1/reviews/{id}` | Bearer | —                   | `{ data: Review }`       |
| PATCH  | `/v1/reviews/{id}` | Bearer | ReviewUpdateRequest | `{ data: Review }`       |
| DELETE | `/v1/reviews/{id}` | Bearer | —                   | `{ data: Review }`       |

### ride-service

| Method | Path                    | Auth   | Request Model           | Response Model           |
| ------ | ----------------------- | ------ | ----------------------- | ------------------------ |
| GET    | `/v1/rides`             | Bearer | query filters           | `{ data[], nextCursor }` |
| POST   | `/v1/rides`             | Bearer | RideCreateRequest       | `{ data: Ride }`         |
| GET    | `/v1/rides/assignments` | Bearer | —                       | `{ data: Ride[] }`       |
| GET    | `/v1/rides/{id}`        | Bearer | —                       | `{ data: Ride }`         |
| PATCH  | `/v1/rides/{id}`        | Bearer | RideStatusUpdateRequest | `{ data: Ride }`         |

### user-service

| Method | Path                               | Auth                                 | Request Model     | Response Model   |
| ------ | ---------------------------------- | ------------------------------------ | ----------------- | ---------------- |
| POST   | `/v1/users`                        | Bearer (gateway) or headers (direct) | UserCreateRequest | UserResponse     |
| GET    | `/v1/users`                        | Bearer (gateway) or headers (direct) | query filters     | UserListResponse |
| GET    | `/v1/users/{id}`                   | Bearer (gateway) or headers (direct) | —                 | UserResponse     |
| PATCH  | `/v1/users/{id}`                   | Bearer (gateway) or headers (direct) | UserUpdateRequest | UserResponse     |
| DELETE | `/v1/users/{id}`                   | Bearer (gateway) or headers (direct) | —                 | UserResponse     |
| GET    | `/internal/users/{id}`             | x-internal-key                       | —                 | UserResponse     |
| GET    | `/internal/users/by-email/{email}` | x-internal-key                       | —                 | UserResponse     |

## Assumptions / Notes

- `CAB-BOOKING-SYSTEM.docx` does not contain parseable endpoint definitions; all endpoints above are from code.
- Gateway authentication uses JWT; user-service direct endpoints use `x-user-id`/`x-user-role` headers.
- Internal endpoints are intended for service-to-service usage and not exposed through the gateway unless explicitly proxied.
