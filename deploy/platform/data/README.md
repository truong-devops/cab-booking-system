# Data Layer Chuẩn Bị Deploy

App cần 4 nhóm data service:

- PostgreSQL cho auth, booking, user, driver, review, payment, places.
- Redis cho cache/rate/session nhẹ.
- MongoDB cho ride và notification.
- Kafka cho event giữa booking, ride, payment, review.

Các file `*.values.yaml` là cấu hình Helm cho lab K3s. Khi production thật, bạn có thể thay bằng managed database hoặc operator chuyên dụng, nhưng interface với app vẫn giữ qua DNS và Secret.

## Namespace

```bash
kubectl create namespace data-staging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace data-prod --dry-run=client -o yaml | kubectl apply -f -
```

## Secret cho data layer

Staging:

```bash
kubectl -n data-staging create secret generic cab-postgres-secret \
  --from-literal=POSTGRES_PASSWORD='CHANGE_ME_POSTGRES_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n data-staging create secret generic cab-redis-secret \
  --from-literal=REDIS_PASSWORD='CHANGE_ME_REDIS_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n data-staging create secret generic cab-mongodb-secret \
  --from-literal=mongodb-root-password='CHANGE_ME_MONGODB_ROOT_PASSWORD' \
  --from-literal=mongodb-passwords='CHANGE_ME_MONGODB_APP_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Production làm tương tự trong namespace `data-prod`.

## Cài bằng Helm

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install postgres bitnami/postgresql \
  -n data-staging \
  -f deploy/platform/data/postgresql.values.yaml

helm upgrade --install redis bitnami/redis \
  -n data-staging \
  -f deploy/platform/data/redis.values.yaml

helm upgrade --install mongodb bitnami/mongodb \
  -n data-staging \
  -f deploy/platform/data/mongodb.values.yaml

helm upgrade --install kafka bitnami/kafka \
  -n data-staging \
  -f deploy/platform/data/kafka.values.yaml
```

## DNS mà app đang dùng

| Service | DNS nội bộ |
| --- | --- |
| PostgreSQL | `postgres.data-staging.svc.cluster.local:5432` |
| Redis | `redis-master.data-staging.svc.cluster.local:6379` |
| MongoDB | `mongodb.data-staging.svc.cluster.local:27017` |
| Kafka | `kafka.data-staging.svc.cluster.local:9092` |

Production đổi `data-staging` thành `data-prod`.
