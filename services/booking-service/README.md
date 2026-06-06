# booking-service

ExpressJS microservice scaffold.
Contract: /contracts/openapi/booking-service.yaml

1. Giới thiệu

Booking Service chịu trách nhiệm xử lý yêu cầu đặt xe (booking) trong hệ thống CAB Booking System.

Service này đóng vai trò:

Nhận request đặt xe từ client (qua API Gateway)

Gọi pricing-service để lấy giá ước tính

Lưu booking + snapshot giá tại thời điểm đặt

Phát sinh domain event cho các service khác xử lý tiếp

Nhận yêu cầu hủy booking

⚠️ Booking Service không quản lý vòng đời chuyến đi (ride state machine).
Ride state machine thuộc trách nhiệm của ride-service.

2. Trách nhiệm chính

✅ Create booking

✅ Cancel booking

✅ Publish Kafka events:

ride.created

ride.cancelled

3. Kiến trúc & Luồng xử lý
   3.1 Create Booking Flow

Client gọi POST /v1/bookings

Booking Service validate request

Gọi pricing-service lấy giá ước tính

Tạo booking + snapshot giá

Publish event ride.created

Trả response cho client

3.2 Cancel Booking Flow

Client gọi POST /v1/bookings/{id}/cancel

Booking Service update trạng thái booking → CANCELED

Publish event ride.cancelled

Ride Service consume event và xử lý state machine

4. Công nghệ sử dụng

Runtime: Node.js

Framework: Express

Messaging: Apache Kafka (kafkajs)

Validation: Zod

HTTP Client: Axios

Architecture: Microservices + Event-driven

5. Cấu trúc thư mục
   booking-service/
   ├── src/
   │ ├── app.js # Express app
   │ ├── server.js # Start server
   │ ├── routes/
   │ │ └── bookings.js # Booking APIs
   │ ├── clients/
   │ │ └── pricingClient.js # Call pricing-service
   │ ├── repositories/
   │ │ └── bookingRepo.js # Booking storage (MVP)
   │ ├── schemas/
   │ │ └── bookingSchemas.js # Request validation
   │ └── messaging/
   │ ├── producer.js # Kafka producer
   │ └── topics.js # Kafka topics
   ├── Dockerfile
   ├── package.json
   └── README.md

6. Cấu hình môi trường

Luồng bình thường nên gọi qua API Gateway `http://localhost:42100`. Các port `42104`, `42106`, `42133` bên dưới chỉ dùng khi chạy/debug service trực tiếp từ máy host.

Tạo file .env trong thư mục booking-service:

SERVICE_NAME=booking-service
PORT=42104
KAFKA_BROKERS=localhost:42133
PRICING_BASE_URL=http://localhost:42106

7. Chạy service (Local)
   7.1 Chạy hạ tầng Kafka
   docker compose -f infra/docker-compose.dev.yml up -d

Kafka UI:

http://localhost:8080

7.2 Cài dependency
cd services/booking-service
npm install

7.3 Chạy service
node src/server.js

Service chạy tại:

http://localhost:42104

8. API Documentation
   8.1 Health Check

GET /health

Response:

{
"status": "ok",
"service": "booking-service"
}

8.2 Create Booking

POST /v1/bookings

Request body:

{
"pickup": { "lat": 10.76, "lng": 106.66 },
"dropoff": { "lat": 10.78, "lng": 106.68 },
"vehicleType": "CAR"
}

Response:

{
"booking": {
"bookingId": "bk_1710000000000",
"rideId": "ride_1710000000001",
"status": "CREATED",
"priceSnapshot": {
"total": 15000,
"currency": "VND"
}
}
}

Side effect:

Publish Kafka event ride.created

8.3 Cancel Booking

POST /v1/bookings/{bookingId}/cancel

Response:

{
"booking": {
"bookingId": "bk_1710000000000",
"rideId": "ride_1710000000001",
"status": "CANCELED"
}
}

Side effect:

Publish Kafka event ride.cancelled

9. Kafka Topics
   Topic Description
   ride.created Booking created, start ride lifecycle
   ride.cancelled Booking canceled by customer
10. Trạng thái Booking
    Status Ý nghĩa
    CREATED Booking vừa được tạo
    CANCELED Booking đã bị hủy
11. Nguyên tắc thiết kế

Booking Service không chứa business logic phức tạp

Mọi thay đổi trạng thái chuyến đi phải được xử lý ở ride-service

Event-driven giúp:

Giảm coupling

Dễ mở rộng

Dễ scale

12. Hướng phát triển tiếp

Lưu booking vào database (PostgreSQL / MongoDB)

Thêm idempotency key

Thêm authentication (JWT)
