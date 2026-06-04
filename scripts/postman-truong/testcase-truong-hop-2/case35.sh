# Xoá users trong auth-service_db
docker-compose -f infra/docker-compose.dev.yml exec -T postgres psql -U cab -d "auth-service_db" -c "DELETE FROM public.users; DELETE FROM public.refresh_tokens;"

# Xoá users trong user-service_db
docker-compose -f infra/docker-compose.dev.yml exec -T postgres psql -U cab -d "user-service_db" -c "DELETE FROM public.users; DELETE FROM public.outbox_events;"

# Xoá bookings trong booking-service_db
docker-compose -f infra/docker-compose.dev.yml exec -T postgres psql -U cab -d "booking-service_db" -c "DELETE FROM public.bookings; DELETE FROM public.idempotency_keys; DELETE FROM public.inbox_events; DELETE FROM public.outbox_events;"

TS=$(date +%s)
EMAIL="case35-time-${TS}@test.com"
PASS="123456"

curl -s -X POST http://localhost:3000/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"name\":\"Case35 Time User\",\"role\":\"user\"}" >/dev/null

TOKEN=$(curl -s -X POST http://localhost:3000/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PASS\"}" | jq -r '.tokens.accessToken')

BODY='{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7711,"lng":106.7011},"vehicleType":"CAR"}'

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

(
  START=$(now_ms)
  curl -s -X POST http://localhost:3000/v1/bookings \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$BODY" \
    -w "\nHTTP_STATUS:%{http_code}\nCURL_TOTAL:%{time_total}\n" \
    > /tmp/case35_time_1.out
  END=$(now_ms)
  echo "REQ1_START_MS=$START" > /tmp/case35_time_1.meta
  echo "REQ1_END_MS=$END" >> /tmp/case35_time_1.meta
) &

(
  START=$(now_ms)
  curl -s -X POST http://localhost:3000/v1/bookings \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "$BODY" \
    -w "\nHTTP_STATUS:%{http_code}\nCURL_TOTAL:%{time_total}\n" \
    > /tmp/case35_time_2.out
  END=$(now_ms)
  echo "REQ2_START_MS=$START" > /tmp/case35_time_2.meta
  echo "REQ2_END_MS=$END" >> /tmp/case35_time_2.meta
) &

wait

cat /tmp/case35_time_1.meta
cat /tmp/case35_time_2.meta
echo "=== REQ1 ==="; cat /tmp/case35_time_1.out
echo "=== REQ2 ==="; cat /tmp/case35_time_2.out
