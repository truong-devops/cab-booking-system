# CAB Booking Customer App – Mock & Flow Quickstart

## Journey to preserve

Splash → Login/OTP → Home (map) → Destination → RideOptions → Searching → Tracking → Payment → Rating  
Plus: Ride History, Profile & Wallet (tab bar).

## Mock toggles

- `EXPO_PUBLIC_USE_MOCK_API` (default `true`)
- `MOCK_SCENARIO`: `happy | no_driver | surge | pricing_down | payment_fail | payment_timeout | overload`
- `MOCK_LATENCY`: `fast | normal | slow`

## Where mocks live

- `src/mocks/config.ts` (env toggles)
- `src/mocks/handlers` (auth, pricing, ride, payment)
- `src/mocks/socket` (nearby_drivers, match_status, driver_location every 2–5s, auto reconnect)
- `src/mocks/state/db.ts` (in-memory data)
- `src/mocks/factories` (quotes)
- `src/constants/states.ts` (Ride/Payment enums)

## Services & mapping

- Auth → `services/authApi.ts` (switches to mock when toggle on)
- Booking/Ride → `services/rideApi.ts`
- Pricing/Surge/ETA → `services/pricingApi.ts`
- Payment → `services/paymentApi.ts`

## Failure scenarios covered (via scenario or mock socket)

- No driver found (`no_driver`)
- Surge spike (`surge`)
- Pricing down (`pricing_down`)
- Payment fail/timeout (`payment_fail`, `payment_timeout`)
- Realtime reconnect fallback (socket auto reconnect)

## How to run (mock on)

```
cd apps/customer-app
npx expo start --port 42181 --clear
```

Scan `exp://<LAN-IP>:42181` in Expo Go.

## Notes

- Mock data uses địa điểm/driver VN thật tế (HCM).
- Price snapshot kept via quoteId from Pricing mock.
- Idempotency keys kept for ride/payment even in mock.
