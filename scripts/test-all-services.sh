#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:42100}"
USER_EMAIL="${USER_EMAIL:-user1@test.com}"
USER_PASSWORD="${USER_PASSWORD:-secret123}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@test.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret123}"
NOW_TS="$(date +%s)"

json_get() {
  local path="$1"
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);let v=j;for (const k of '$path'.split('.')) { if (!k) continue; v = v?.[k]; } console.log(v||'');}catch(e){console.log('');}})"
}

echo "== Test all services =="

echo "-- Auth: register user/admin (ignore if exists)"
curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASSWORD\",\"role\":\"user\"}" >/dev/null || true
curl -s -X POST "$BASE_URL/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\",\"role\":\"admin\"}" >/dev/null || true

echo "-- Auth: login user/admin"
USER_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"$USER_EMAIL\",\"password\":\"$USER_PASSWORD\"}")
USER_TOKEN=$(echo "$USER_LOGIN" | json_get "tokens.accessToken")
USER_REFRESH=$(echo "$USER_LOGIN" | json_get "tokens.refreshToken")
USER_ID=$(echo "$USER_LOGIN" | json_get "data.id")

ADMIN_LOGIN=$(curl -s -X POST "$BASE_URL/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | json_get "tokens.accessToken")
ADMIN_REFRESH=$(echo "$ADMIN_LOGIN" | json_get "tokens.refreshToken")

if [[ -z "$USER_TOKEN" || -z "$ADMIN_TOKEN" ]]; then
  echo "Login failed"
  exit 1
fi

curl -s "$BASE_URL/v1/auth/verify" -H "Authorization: Bearer $ADMIN_TOKEN" >/dev/null

echo "-- Auth: refresh + logout"
if [[ -n "$USER_REFRESH" ]]; then
  REFRESH_JSON=$(curl -s -X POST "$BASE_URL/v1/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"$USER_REFRESH\"}")
  echo "$REFRESH_JSON"
  NEW_USER_TOKEN=$(echo "$REFRESH_JSON" | json_get "tokens.accessToken")
  NEW_USER_REFRESH=$(echo "$REFRESH_JSON" | json_get "tokens.refreshToken")
  if [[ -n "$NEW_USER_TOKEN" ]]; then
    USER_TOKEN="$NEW_USER_TOKEN"
    USER_REFRESH="$NEW_USER_REFRESH"
  fi
  echo
  curl -s -X POST "$BASE_URL/v1/auth/logout" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"$USER_REFRESH\"}"
  echo
fi

echo "-- User-service: list users"
curl -s "$BASE_URL/v1/users?limit=3" -H "Authorization: Bearer $ADMIN_TOKEN"
echo

echo "-- User-service: create/get/update/delete"
NEW_USER_EMAIL="user-$NOW_TS@test.com"
NEW_USER_JSON=$(curl -s -X POST "$BASE_URL/v1/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$NEW_USER_EMAIL\",\"fullName\":\"User $NOW_TS\",\"role\":\"customer\",\"status\":\"active\"}")
echo "$NEW_USER_JSON"
NEW_USER_ID=$(echo "$NEW_USER_JSON" | json_get "data.id")
if [[ -n "$NEW_USER_ID" ]]; then
  curl -s "$BASE_URL/v1/users/$NEW_USER_ID" -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
  curl -s -X PATCH "$BASE_URL/v1/users/$NEW_USER_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"fullName":"User Updated","status":"SUSPENDED"}'
  echo
  curl -s -X DELETE "$BASE_URL/v1/users/$NEW_USER_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
fi

echo "-- Pricing-service: create + get quote"
QUOTE_JSON=$(curl -s -X POST "$BASE_URL/v1/pricing/quotes" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pickup":{"lat":10.76,"lng":106.66},"dropoff":{"lat":10.78,"lng":106.68},"serviceType":"STANDARD"}')
echo "$QUOTE_JSON"
QUOTE_ID=$(echo "$QUOTE_JSON" | json_get "data.quoteId")
if [[ -n "$QUOTE_ID" ]]; then
  curl -s "$BASE_URL/v1/pricing/quotes/$QUOTE_ID" -H "Authorization: Bearer $USER_TOKEN"
  echo
  echo "-- Pricing-service: finalize quote"
  curl -s -X POST "$BASE_URL/v1/pricing/finalize" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"quoteId\":\"$QUOTE_ID\",\"actualDistanceKm\":3.5,\"actualDurationMin\":9}"
  echo
fi

echo "-- ETA-service: estimate"
curl -s -X POST "$BASE_URL/v1/eta/estimate" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.78,"lng":106.68},"traffic_level":0.5}'
echo

echo "-- Booking-service: create + cancel"
BOOKING_JSON=$(curl -s -X POST "$BASE_URL/v1/bookings" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pickup":{"lat":10.76,"lng":106.66},"dropoff":{"lat":10.78,"lng":106.68},"vehicleType":"CAR"}')
echo "$BOOKING_JSON"
BOOKING_ID=$(echo "$BOOKING_JSON" | json_get "booking.bookingId")
if [[ -n "$BOOKING_ID" ]]; then
  curl -s -X POST "$BASE_URL/v1/bookings/$BOOKING_ID/cancel" \
    -H "Authorization: Bearer $USER_TOKEN"
  echo
fi

echo "-- Ride-service: create + list"
RIDE_JSON=$(curl -s -X POST "$BASE_URL/v1/rides" \
  -H "Authorization: Bearer $USER_TOKEN" \
  -H "Idempotency-Key: ride-test-$NOW_TS" \
  -H "Content-Type: application/json" \
  -d '{"pickupLat":10.76,"pickupLng":106.66,"dropoffLat":10.78,"dropoffLng":106.68}')
echo "$RIDE_JSON"
RIDE_ID=$(echo "$RIDE_JSON" | json_get "data.id")
if [[ -n "$RIDE_ID" ]]; then
  curl -s "$BASE_URL/v1/rides/$RIDE_ID" -H "Authorization: Bearer $USER_TOKEN"
  echo
  echo "-- Ride-service: status transitions"
  curl -s -X PATCH "$BASE_URL/v1/rides/$RIDE_ID" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"status":"ASSIGNED"}'
  echo
  curl -s -X PATCH "$BASE_URL/v1/rides/$RIDE_ID" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"status":"ARRIVING"}'
  echo
  curl -s -X PATCH "$BASE_URL/v1/rides/$RIDE_ID" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"status":"IN_PROGRESS"}'
  echo
  curl -s -X PATCH "$BASE_URL/v1/rides/$RIDE_ID" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"status":"COMPLETED"}'
  echo
fi
curl -s "$BASE_URL/v1/rides" -H "Authorization: Bearer $USER_TOKEN"
echo

echo "-- Driver-service: smoke (list admin drivers)"
if [[ -x "./scripts/test-driver-service.sh" ]]; then
  ./scripts/test-driver-service.sh
else
  curl -s "$BASE_URL/v1/admin/drivers?limit=3" \
    -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
fi

echo "-- Notification-service: create/get/retry/cancel/list"
NOTI_JSON=$(curl -s -X POST "$BASE_URL/v1/notifications" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"userId\":\"$USER_ID\",\"title\":\"Test notification\",\"message\":\"Hello\",\"channels\":[\"IN_APP\"],\"sourceService\":\"booking-service\",\"sourceAction\":\"BOOKING_CREATED\",\"dedupeKey\":\"test-$(date +%s)\"}")
echo "$NOTI_JSON"
NOTI_ID=$(echo "$NOTI_JSON" | json_get "id")
if [[ -n "$NOTI_ID" ]]; then
  curl -s "$BASE_URL/v1/notifications/$NOTI_ID" -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
  curl -s -X POST "$BASE_URL/v1/notifications/$NOTI_ID/retry" -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
  curl -s -X PATCH "$BASE_URL/v1/notifications/$NOTI_ID/cancel" -H "Authorization: Bearer $ADMIN_TOKEN"
  echo
fi
curl -s "$BASE_URL/v1/notifications/users/$USER_ID/notifications" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
echo

echo "-- Notification-service: preferences + batch"
curl -s "$BASE_URL/v1/notifications/users/$USER_ID/preferences" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
echo
curl -s -X PUT "$BASE_URL/v1/notifications/users/$USER_ID/preferences" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channels":{"IN_APP":true,"EMAIL":false,"SMS":false,"PUSH":false}}'
echo
curl -s -X POST "$BASE_URL/v1/notifications/batch" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"items\":[{\"userId\":\"$USER_ID\",\"title\":\"Batch 1\",\"message\":\"Hello 1\",\"channels\":[\"IN_APP\"],\"sourceService\":\"booking-service\",\"sourceAction\":\"BOOKING_CREATED\",\"dedupeKey\":\"batch-1-$NOW_TS\"},{\"userId\":\"$USER_ID\",\"title\":\"Batch 2\",\"message\":\"Hello 2\",\"channels\":[\"IN_APP\"],\"sourceService\":\"booking-service\",\"sourceAction\":\"BOOKING_CREATED\",\"dedupeKey\":\"batch-2-$NOW_TS\"}]}"
echo

echo "-- Review-service: list"
curl -s "$BASE_URL/v1/reviews?limit=5" -H "Authorization: Bearer $USER_TOKEN"
echo

echo "-- Review-service: create/get/update/delete"
if [[ -n "$RIDE_ID" ]]; then
  REVIEW_JSON=$(curl -s -X POST "$BASE_URL/v1/reviews" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Idempotency-Key: review-$NOW_TS" \
    -H "Content-Type: application/json" \
    -d "{\"rideId\":\"$RIDE_ID\",\"driverId\":\"11111111-1111-1111-1111-111111111111\",\"rating\":5,\"comment\":\"great\"}")
  echo "$REVIEW_JSON"
  REVIEW_ID=$(echo "$REVIEW_JSON" | json_get "data.id")
  if [[ -n "$REVIEW_ID" ]]; then
    curl -s "$BASE_URL/v1/reviews/$REVIEW_ID" -H "Authorization: Bearer $USER_TOKEN"
    echo
    curl -s -X PATCH "$BASE_URL/v1/reviews/$REVIEW_ID" \
      -H "Authorization: Bearer $USER_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"comment":"updated comment"}'
    echo
    curl -s -X DELETE "$BASE_URL/v1/reviews/$REVIEW_ID" \
      -H "Authorization: Bearer $USER_TOKEN"
    echo
  fi
fi

echo "-- Payment-service: create/get/list/update smoke"
if [[ -x "./scripts/test-payment-service.sh" ]]; then
  ./scripts/test-payment-service.sh
else
  PAYMENT_RIDE_ID="$RIDE_ID"
  if [[ -z "$PAYMENT_RIDE_ID" ]]; then
    PAYMENT_RIDE_ID=$(node -e "console.log(require('crypto').randomUUID())")
  fi

  PAYMENT_JSON=$(curl -s -X POST "$BASE_URL/v1/payments" \
    -H "Authorization: Bearer $USER_TOKEN" \
    -H "Idempotency-Key: payment-test-$NOW_TS" \
    -H "Content-Type: application/json" \
    -d "{\"rideId\":\"$PAYMENT_RIDE_ID\",\"amount\":85000,\"currency\":\"VND\",\"method\":\"VIETQR\"}")
  echo "$PAYMENT_JSON"
  PAYMENT_ID=$(echo "$PAYMENT_JSON" | json_get "data.id")
  if [[ -n "$PAYMENT_ID" ]]; then
    curl -s "$BASE_URL/v1/payments/$PAYMENT_ID" -H "Authorization: Bearer $USER_TOKEN"
    echo
    curl -s -X PATCH "$BASE_URL/v1/payments/$PAYMENT_ID" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"status":"PROCESSING"}'
    echo
    curl -s "$BASE_URL/v1/payments/$PAYMENT_ID/vietqr-codes" \
      -H "Authorization: Bearer $USER_TOKEN"
    echo
  fi
  curl -s "$BASE_URL/v1/payments?limit=5" \
    -H "Authorization: Bearer $USER_TOKEN"
  echo
fi

echo "== Done =="
