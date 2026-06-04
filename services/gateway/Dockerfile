FROM golang:1.25-alpine AS builder

WORKDIR /src

COPY services/gateway/go.mod services/gateway/go.sum ./
RUN go mod download

COPY services/gateway ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o /out/gateway ./cmd/gateway

FROM alpine:3.20

RUN apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /out/gateway /app/gateway

EXPOSE 3000 3443
ENTRYPOINT ["/app/gateway"]
