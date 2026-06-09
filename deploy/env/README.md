# Environment Và Secret

Thư mục này chứa checklist env cho deployment. File đã điền secret thật phải để ngoài repo hoặc lưu trong secret manager.

## Các nhóm env

| File | Dùng cho |
| --- | --- |
| `cluster.env` | Domain, IP private của VPS, token K3s, Harbor pull robot. |
| `app-secrets.env` | Secret của app: JWT, database URL, Redis, MongoDB, payment provider. |
| `data-secrets.env` | Secret cho data layer: PostgreSQL, Redis, MongoDB. |

## Tạo Kubernetes Secret cho app

Ví dụ staging:

```bash
kubectl create namespace cab-staging --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cab-staging create secret generic cab-app-secrets \
  --from-env-file=/secure/path/app-secrets.staging.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

Ví dụ production:

```bash
kubectl create namespace cab-prod --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cab-prod create secret generic cab-app-secrets \
  --from-env-file=/secure/path/app-secrets.production.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Tạo image pull secret cho Harbor

```bash
kubectl -n cab-staging create secret docker-registry harbor-pull-secret \
  --docker-server=harbor.your-domain.com \
  --docker-username='robot$cab-k3s' \
  --docker-password='CHANGE_ME_HARBOR_ROBOT_PULL_TOKEN' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Lặp lại lệnh trên cho `cab-prod`.
