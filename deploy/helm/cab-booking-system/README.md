# Helm Chart: cab-booking-system

Chart này biến cấu hình service trong `values.yaml` thành Kubernetes resource.

## File quan trọng

| File | Vai trò |
| --- | --- |
| `Chart.yaml` | Metadata của chart. |
| `values.yaml` | Cấu hình mặc định cho service, env, probes, jobs, ingress, network policy. |
| `values-staging.yaml` | Override cho staging. |
| `values-production.yaml` | Override cho production. |
| `templates/deployment.yaml` | Tạo Deployment cho từng backend service. |
| `templates/service.yaml` | Tạo ClusterIP Service để service gọi nhau bằng DNS nội bộ. |
| `templates/ingress.yaml` | Public API Gateway qua Nginx Ingress và cert-manager TLS. |
| `templates/job-*.yaml` | Chạy bootstrap database, migration, admin user và Kafka topics. |
| `templates/networkpolicy.yaml` | Giới hạn traffic giữa app, ingress, data layer và Internet. |
| `templates/resourcequota.yaml` | Chặn namespace dùng quá tài nguyên. |
| `templates/limitrange.yaml` | Bắt container có request/limit mặc định. |

## Vì sao service vẫn dùng internal port?

Trong Kubernetes, service-to-service nên gọi qua DNS nội bộ:

```text
http://booking-service:3003
http://payment-service:3007
```

Port public duy nhất là `80/443` ở Ingress. Các port như `3003`, `3007`, `4001` chỉ nằm trong cluster, không mở ra VPS. Cách này tốt hơn cho production vì firewall và ingress kiểm soát mặt public.

## Render thử

```bash
helm lint deploy/helm/cab-booking-system

helm template cab-staging deploy/helm/cab-booking-system \
  -f deploy/helm/cab-booking-system/values-staging.yaml

helm template cab-prod deploy/helm/cab-booking-system \
  -f deploy/helm/cab-booking-system/values-production.yaml
```

## Deploy thủ công để test lab

Argo CD là cách deploy chính. Nhưng khi học, bạn có thể test chart thủ công:

```bash
helm upgrade --install cab-staging deploy/helm/cab-booking-system \
  -n cab-staging \
  -f deploy/helm/cab-booking-system/values-staging.yaml
```

Nếu dùng cách này, vẫn phải tạo `cab-app-secrets` và `harbor-pull-secret` trước.

## Những giá trị bắt buộc phải thay

- `global.imageRegistry`
- `global.imageTag`
- `ingress.host`
- `ingress.tlsSecretName`
- database URL trong `cab-app-secrets`
- Redis/MongoDB/Kafka endpoint nếu bạn không dùng data layer trong `deploy/platform/data`
