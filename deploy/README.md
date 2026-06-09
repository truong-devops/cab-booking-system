# Cab Booking System Deployment Preparation

Thư mục này chứa bộ file chuẩn bị triển khai `cab-booking-system` lên K3s theo luồng DevSecOps:

```text
GitLab CI -> build/scan image -> Harbor -> GitOps repo -> Argo CD -> K3s
```

Mục tiêu của bộ file này là giúp bạn chuẩn bị deployment theo hướng production-like. Những giá trị dạng `your-domain.com` và `CHANGE_ME_*` là checklist bắt buộc phải thay bằng domain, IP, secret và image tag thật trước khi deploy.

## Cấu trúc

```text
deploy/
  env/                         # Checklist env cho cluster, app secret và data secret
  gitlab/                      # GitLab CI pipeline chuẩn bị deploy
  helm/cab-booking-system/     # Helm chart deploy backend services lên K3s
  images/                      # Helper images cho migration/topic jobs
  platform/                    # Add-ons nền tảng: K3s, storage, data, Argo CD, Kyverno, TLS, monitoring
```

## Vì sao cần các nhóm file này?

| Nhóm file | Lý do tồn tại |
| --- | --- |
| `env/` | Tách cấu hình môi trường khỏi code. Các file ở đây là checklist biến cần có, không chứa secret thật. |
| `gitlab/` | Pipeline để test, scan, build, push image và update GitOps repo. |
| `helm/` | Helm chart là cách đóng gói Kubernetes manifests có biến môi trường staging/production. |
| `images/` | Migration và Kafka topic bootstrap nên chạy bằng Job riêng, không chạy tay trong pod app. |
| `platform/` | K3s cần add-ons nền tảng trước khi deploy app: network, storage, data, ingress, TLS, Argo CD, policy, monitoring. |

## Thứ tự dùng

1. Đọc `docs/deployment/README.md` để hiểu plan tổng thể.
2. Điền `deploy/env/cluster.env` thành file riêng trên máy bạn, không commit.
3. Cài K3s bằng scripts trong `deploy/platform/k3s`.
4. Cài storage trong `deploy/platform/storage` nếu database chạy trong K3s.
5. Cài data layer trong `deploy/platform/data` hoặc chuẩn bị managed database.
6. Cài add-ons trong `deploy/platform`.
7. Tạo Kubernetes Secret từ `deploy/env/app-secrets.env` đã thay giá trị thật.
8. Render thử Helm chart:

```bash
helm template cab-staging deploy/helm/cab-booking-system \
  -f deploy/helm/cab-booking-system/values-staging.yaml
```

9. Đưa chart/values sang GitOps repo và để Argo CD deploy.
10. Copy `deploy/gitlab/gitlab-ci.yml` thành `.gitlab-ci.yml` khi bạn đã có GitLab Runner và Harbor.

## Quy tắc quan trọng

- Không commit secret thật.
- Không dùng image tag `latest`.
- Không deploy production bằng root `.env` local.
- Production deploy bằng Argo CD/GitOps, không SSH vào server sửa tay.
- Database/Kafka nên được cài riêng trong namespace data hoặc dùng managed service.
