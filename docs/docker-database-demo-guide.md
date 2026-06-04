# Huong Dan Demo Database That Trong Docker

Tai lieu nay huong dan cach mo va xem database that cua project CAB Booking System dang chay trong Docker Compose.

## 1. Chon Dung Terminal

Neu ban dung **PowerShell tren Windows**, dung path Windows:

```powershell
cd "D:\University\Semester 2_Year 4\MSAD\CAB-BOOKING-SYSTEM\DHHTTT18B-N21-cab-system"
```

Neu ban dung **WSL/Ubuntu terminal**, dung path Linux:

```bash
cd "/mnt/d/University/Semester 2_Year 4/MSAD/CAB-BOOKING-SYSTEM/DHHTTT18B-N21-cab-system"
```

Luu y: Khong dung `/mnt/d/...` trong PowerShell, vi PowerShell se hieu thanh `D:\mnt\d\...` va bao loi path khong ton tai.

## 2. Kiem Tra Docker Compose Dang Chay

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml ps
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml ps
```

Neu container chua chay, khoi dong he thong:

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml up -d
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml up -d
```

## 3. Cac Database Trong Project

Project dung 3 loai storage chinh:

| Storage | Container/Service | Dung cho |
| --- | --- | --- |
| PostgreSQL | `postgres` | auth, user, booking, driver, payment, review, places |
| MongoDB | `mongo` | ride, notification |
| Redis | `redis` | cache, idempotency, state nhanh |
| Kafka | `kafka` | event stream, khong phai database nhung dung de demo event |

Thong tin PostgreSQL trong compose:

```text
user: cab
password: cabpass
host trong docker network: postgres
port trong container: 5432
```

## 4. Xem PostgreSQL

### 4.1. Liet Ke Tat Ca Database

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d postgres -c "\l"
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d postgres -c "\l"
```

Database theo service:

```text
auth-service_db
user-service_db
booking-service_db
driver-service_db
payment-service_db
review-service_db
places-service_db
```

### 4.2. Vao Tung Database De Xem Bang

Vi du vao database cua auth-service:

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
```

Ben trong man hinh `psql`, dung cac lenh:

```sql
\dt
SELECT * FROM users LIMIT 10;
\q
```

Y nghia:

| Lenh | Y nghia |
| --- | --- |
| `\dt` | Liet ke cac table trong database hien tai |
| `SELECT * FROM ten_bang LIMIT 10;` | Xem 10 dong dau cua table |
| `\q` | Thoat psql |

### 4.3. Lenh Vao Nhanh Tung Service DB

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d user-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d booking-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d driver-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d payment-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d review-service_db
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d places-service_db
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d user-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d booking-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d driver-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d payment-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d review-service_db
docker compose -f infra/docker-compose.dev.yml exec postgres psql -U cab -d places-service_db
```

### 4.4. Xem Table Cua Tat Ca PostgreSQL DB Mot Lan

PowerShell:

```powershell
$dbs = "auth-service_db","user-service_db","booking-service_db","driver-service_db","payment-service_db","review-service_db","places-service_db"
foreach ($db in $dbs) {
  Write-Host "===== $db ====="
  docker compose -f .\infra\docker-compose.dev.yml exec -T postgres psql -U cab -d $db -c "\dt"
}
```

WSL/Ubuntu:

```bash
for db in auth-service_db user-service_db booking-service_db driver-service_db payment-service_db review-service_db places-service_db; do
  echo "===== $db ====="
  docker compose -f infra/docker-compose.dev.yml exec -T postgres psql -U cab -d "$db" -c "\dt"
done
```

## 5. Xem MongoDB

MongoDB duoc dung cho `ride_service` va `notification_service`.

### 5.1. Liet Ke Database Mongo

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh --eval "show dbs"
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec mongo mongosh --eval "show dbs"
```

### 5.2. Liet Ke Collection

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh ride_service --eval "show collections"
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh notification_service --eval "show collections"
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec mongo mongosh ride_service --eval "show collections"
docker compose -f infra/docker-compose.dev.yml exec mongo mongosh notification_service --eval "show collections"
```

### 5.3. Xem Du Lieu Mongo

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh ride_service --eval "db.rides.find().limit(5).pretty()"
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh notification_service --eval "db.notifications.find().limit(5).pretty()"
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec mongo mongosh ride_service --eval "db.rides.find().limit(5).pretty()"
docker compose -f infra/docker-compose.dev.yml exec mongo mongosh notification_service --eval "db.notifications.find().limit(5).pretty()"
```

Neu khong biet ten collection, chay `show collections` truoc roi thay `rides`/`notifications` bang ten collection that.

## 6. Xem Redis

Redis dung cho cache, idempotency, session/state nhanh.

### 6.1. Kiem Tra So Key

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli DBSIZE
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec redis redis-cli DBSIZE
```

### 6.2. Liet Ke Mot So Key

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli --scan
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec redis redis-cli --scan | head -50
```

Trong PowerShell, neu muon lay 50 key dau:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli --scan | Select-Object -First 50
```

### 6.3. Xem Value Cua Mot Key

String key:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli GET "ten_key"
```

Hash key:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli HGETALL "ten_key"
```

Kiem tra type truoc:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli TYPE "ten_key"
```

## 7. Xem Kafka Event

Kafka khong phai database, nhung dung de demo event that nhu `ride.created`, `payment.completed`, `payment.failed`.

### 7.1. Liet Ke Topic

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec kafka kafka-topics --bootstrap-server kafka:9092 --list
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec kafka kafka-topics --bootstrap-server kafka:9092 --list
```

### 7.2. Doc Event Trong Topic

PowerShell:

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec kafka kafka-console-consumer --bootstrap-server kafka:9092 --topic ride.created --from-beginning --max-messages 5
```

WSL/Ubuntu:

```bash
docker compose -f infra/docker-compose.dev.yml exec kafka kafka-console-consumer --bootstrap-server kafka:9092 --topic ride.created --from-beginning --max-messages 5
```

Neu topic khac, thay `ride.created` bang ten topic lay tu lenh `--list`.

## 8. Demo Mau Cho Giang Vien/Nguoi Xem

### Buoc 1: Mo danh sach container

```powershell
docker compose -f .\infra\docker-compose.dev.yml ps
```

Noi: He thong dang chay nhieu service va infra container nhu postgres, mongo, redis, kafka.

### Buoc 2: Mo PostgreSQL auth-service

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
```

Trong `psql`:

```sql
\dt
SELECT * FROM users LIMIT 5;
\q
```

Noi: Day la database that cua auth-service, chua user dang ky/dang nhap.

### Buoc 3: Mo booking-service DB

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d booking-service_db
```

Trong `psql`:

```sql
\dt
SELECT * FROM bookings LIMIT 5;
\q
```

Noi: Day la booking duoc tao thong qua API/Postman/app.

### Buoc 4: Mo MongoDB notification/ride

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh --eval "show dbs"
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh notification_service --eval "show collections"
```

Noi: Mot so service dung MongoDB cho document data nhu notification/ride.

### Buoc 5: Mo Redis va Kafka

```powershell
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli DBSIZE
docker compose -f .\infra\docker-compose.dev.yml exec kafka kafka-topics --bootstrap-server kafka:9092 --list
```

Noi: Redis giu cache/state nhanh, Kafka giu event stream giua cac microservice.

## 9. Loi Thuong Gap

### Loi 1: `Cannot find path D:\mnt\d\...`

Nguyen nhan: dang dung PowerShell nhung lai copy path WSL `/mnt/d/...`.

Cach dung dung:

```powershell
cd "D:\University\Semester 2_Year 4\MSAD\CAB-BOOKING-SYSTEM\DHHTTT18B-N21-cab-system"
```

### Loi 2: `no configuration file provided`

Nguyen nhan: dang dung sai thu muc hoac sai duong dan compose file.

Kiem tra lai:

```powershell
pwd
dir .\infra\docker-compose.dev.yml
docker compose -f .\infra\docker-compose.dev.yml ps
```

### Loi 3: `service "postgres" is not running`

Khoi dong lai compose:

```powershell
docker compose -f .\infra\docker-compose.dev.yml up -d postgres mongo redis kafka
```

Hoac khoi dong toan bo:

```powershell
docker compose -f .\infra\docker-compose.dev.yml up -d
```

### Loi 4: Table khong ton tai

Co the migration/seed chua chay hoac service chua tao data. Hay:

1. Goi API tao user/booking bang Postman.
2. Quay lai database va chay `\dt`.
3. Dung dung database cua service, vi moi service co DB rieng.

### Loi 5: Mongo collection rong

Co the chua co notification/ride duoc tao. Hay chay flow booking/notification truoc, sau do xem lai Mongo.

## 10. Lenh Can Nho Nhanh

PowerShell:

```powershell
cd "D:\University\Semester 2_Year 4\MSAD\CAB-BOOKING-SYSTEM\DHHTTT18B-N21-cab-system"
docker compose -f .\infra\docker-compose.dev.yml ps
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d postgres -c "\l"
docker compose -f .\infra\docker-compose.dev.yml exec postgres psql -U cab -d auth-service_db
docker compose -f .\infra\docker-compose.dev.yml exec mongo mongosh --eval "show dbs"
docker compose -f .\infra\docker-compose.dev.yml exec redis redis-cli DBSIZE
docker compose -f .\infra\docker-compose.dev.yml exec kafka kafka-topics --bootstrap-server kafka:9092 --list
```
