# K3s DevSecOps Deployment Plan - 4 VPS

Tài liệu này là kế hoạch triển khai dự án `cab-booking-system` theo hướng học thật, làm thật trên VPS. Mục tiêu là giúp một sinh viên mới ra trường hiểu từng bước vì sao làm như vậy, không chỉ copy lệnh.

Stack được chọn:

- CI/CD: GitLab CI
- Registry: Harbor
- GitOps deploy: Argo CD
- Security scan: Trivy, Gitleaks, Semgrep, SonarQube
- Policy: Kyverno
- Monitoring: Prometheus, Grafana, Loki
- Ingress/TLS: Nginx Ingress + cert-manager
- Runtime platform: K3s

Repo đã có bộ file chuẩn bị deploy trong `deploy/`. Tài liệu này giải thích kiến trúc và thứ tự triển khai; còn `deploy/README.md` là nơi chứa script, Helm chart, GitLab CI, Argo CD app, policy, monitoring và data layer để bạn bắt đầu thực hành.

## 1. Mục tiêu triển khai

Sau khi hoàn thành, hệ thống nên có luồng như sau:

```text
Developer push code
  -> GitLab CI chạy test và security scan
  -> Build Docker image
  -> Scan image bằng Trivy
  -> Push image vào Harbor
  -> GitLab CI update GitOps repo hoặc manifest path
  -> Argo CD sync vào namespace staging
  -> Smoke test/DAST
  -> Manual approval
  -> Argo CD sync vào namespace production
  -> Prometheus/Grafana/Loki theo dõi vận hành
```

Kết quả mong muốn:

- Production VM không build image.
- K3s chỉ pull image đã scan từ Harbor.
- Deploy không SSH vào từng server để sửa tay.
- Mọi thay đổi hạ tầng/app đi qua Git.
- Staging và production tách namespace.
- Security gate có ở cả CI và Kubernetes admission.

## 2. Kiến trúc 4 VPS

Với đúng 4 VPS, chia như sau là cân bằng nhất:

| VM | Vai trò | Thành phần |
| --- | --- | --- |
| VM1 | DevSecOps control plane | GitLab CE, GitLab Runner, Harbor, SonarQube |
| VM2 | K3s server 1 | control-plane, embedded etcd, workload |
| VM3 | K3s server 2 | control-plane, embedded etcd, workload |
| VM4 | K3s server 3 | control-plane, embedded etcd, workload |

Vì K3s HA embedded etcd nên dùng 3 server nodes. Etcd cần số server lẻ để giữ quorum; 3 node chịu được mất 1 node.

Khuyến nghị cấu hình VPS để học:

| VM | CPU | RAM | Disk | Ghi chú |
| --- | ---: | ---: | ---: | --- |
| VM1 | 4 vCPU | 12-16 GB | 160-250 GB SSD | GitLab + Harbor + SonarQube khá nặng |
| VM2 | 2-4 vCPU | 8 GB | 100-160 GB SSD | K3s server + workload |
| VM3 | 2-4 vCPU | 8 GB | 100-160 GB SSD | K3s server + workload |
| VM4 | 2-4 vCPU | 8 GB | 100-160 GB SSD | K3s server + workload |

Nếu ngân sách thấp, có thể bắt đầu VM1 8 GB RAM và VM2-VM4 4 GB RAM, nhưng SonarQube/Harbor/Kafka/monitoring sẽ dễ thiếu tài nguyên. Khi học DevSecOps, thiếu RAM thường làm bạn mất thời gian debug sai vấn đề.

## 3. DNS đề xuất

Giả sử domain là `your-domain.com`, tạo các record:

| DNS | Trỏ về | Mục đích |
| --- | --- | --- |
| `gitlab.your-domain.com` | VM1 | GitLab |
| `harbor.your-domain.com` | VM1 | Harbor registry |
| `sonar.your-domain.com` | VM1 | SonarQube |
| `argocd.your-domain.com` | K3s ingress | Argo CD UI |
| `grafana.your-domain.com` | K3s ingress | Grafana |
| `api-staging.your-domain.com` | K3s ingress | API Gateway staging |
| `api.your-domain.com` | K3s ingress | API Gateway production |

Với lab 4 VPS, có 2 lựa chọn cho ingress DNS:

- Đơn giản: trỏ DNS vào IP public của VM2, nếu VM2 lỗi thì đổi DNS thủ công sang VM3/VM4.
- Tốt hơn: dùng load balancer của nhà cung cấp VPS hoặc thêm kube-vip/MetalLB sau này.

Không nên cố làm HA ingress hoàn hảo ngay ngày đầu. Trước tiên hãy triển khai được pipeline end-to-end.

## 4. Network và firewall

Yêu cầu tối thiểu:

- VM2, VM3, VM4 phải nói chuyện được với nhau bằng private IP.
- Nếu nhà cung cấp VPS không có private network, dùng WireGuard hoặc Tailscale.
- K3s embedded etcd nên chạy qua private network, không phơi etcd ra internet.

Port gợi ý:

| Port | Scope | Mục đích |
| --- | --- | --- |
| 22/tcp | IP cá nhân của bạn | SSH |
| 80/tcp, 443/tcp | public | HTTP/HTTPS |
| 6443/tcp | IP cá nhân hoặc VM1 | Kubernetes API |
| 2379-2380/tcp | private VM2-VM4 | etcd |
| 10250/tcp | private VM2-VM4 | kubelet |
| 8472/udp | private VM2-VM4 | Flannel VXLAN |
| 30000-32767/tcp | hạn chế | NodePort nếu cần debug |

Quy tắc mentor:

- Public chỉ nên mở 80/443.
- Kubernetes API `6443` chỉ mở cho IP quản trị hoặc VPN.
- Etcd không bao giờ mở public.

## 5. Namespace trong K3s

Tạo namespace theo trách nhiệm:

```text
argocd
cert-manager
ingress-nginx
kyverno
monitoring
logging
cab-staging
cab-prod
data-staging
data-prod
```

Vì chỉ có một K3s cluster, staging và production chưa cách ly hoàn toàn như 2 cluster riêng. Với mục tiêu học, tách namespace là chấp nhận được. Khi đi production thật, nên tách cluster hoặc ít nhất tách node pool, network policy, resource quota, secrets và database.

## 6. Thứ tự triển khai tổng thể

Không triển khai tất cả cùng lúc. Làm theo thứ tự này:

1. Chuẩn bị VPS, DNS, SSH, firewall.
2. Cài VM1: GitLab, GitLab Runner, Harbor, SonarQube.
3. Cài K3s HA trên VM2-VM4.
4. Cấu hình K3s pull image từ Harbor.
5. Cài Nginx Ingress và cert-manager.
6. Cài Argo CD.
7. Cài Kyverno ở chế độ `Audit`.
8. Cài monitoring: Prometheus, Grafana, Loki.
9. Tạo Helm/Kustomize manifests cho app.
10. Tạo GitLab CI pipeline.
11. Deploy staging bằng Argo CD.
12. Thêm smoke test và DAST.
13. Promote production bằng manual approval.
14. Chuyển Kyverno từ `Audit` sang `Enforce` từng policy.

## 7. VM1 - DevSecOps control plane

VM1 chạy các tool không thuộc cluster app:

- GitLab CE: lưu source code, chạy CI/CD.
- GitLab Runner: runner dùng Docker executor.
- Harbor: private registry.
- SonarQube: code quality và quality gate.

### 7.1. Lý do không để VM1 vào K3s cluster

Bạn đang học với 4 VPS. Nếu nhét GitLab, Harbor, SonarQube vào cùng K3s cluster thì bootstrapping khó hơn:

- K3s cần image registry.
- Registry lại chạy trong K3s.
- Pipeline cần GitLab/Runner.
- GitLab/Runner lại phụ thuộc cluster ổn định.

Tách VM1 giúp bạn dễ debug hơn: GitLab/Harbor còn sống kể cả khi K3s đang lỗi.

### 7.2. Công cụ chạy trên VM1

Gợi ý chạy bằng Docker Compose:

```text
/opt/devsecops/
  docker-compose.yml
  gitlab/
  harbor/
  sonarqube/
  nginx/
```

Bạn có thể dùng Nginx hoặc Caddy làm reverse proxy cho:

- `gitlab.your-domain.com`
- `harbor.your-domain.com`
- `sonar.your-domain.com`

GitLab Runner nên dùng Docker executor và tag runner:

```text
docker
build
security
protected
```

Protected runner chỉ chạy branch protected như `main`, `release/*`, hoặc tag release.

## 8. K3s cluster trên VM2-VM4

### 8.1. Chuẩn bị chung trên cả 3 node

Trên VM2, VM3, VM4:

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates open-iscsi nfs-common jq
sudo systemctl enable --now iscsid
```

Đặt hostname:

```bash
sudo hostnamectl set-hostname k3s-1 # VM2
sudo hostnamectl set-hostname k3s-2 # VM3
sudo hostnamectl set-hostname k3s-3 # VM4
```

Nếu dùng Longhorn sau này, `open-iscsi` là bắt buộc.

### 8.2. Cài server node đầu tiên

Trên VM2:

```bash
export K3S_TOKEN='CHANGE_ME_LONG_RANDOM_K3S_TOKEN'
export VM2_PRIVATE_IP='10.0.0.2'
export K3S_API_DNS='k3s-api.your-domain.com'

curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --cluster-init \
  --disable=traefik \
  --secrets-encryption \
  --node-ip "$VM2_PRIVATE_IP" \
  --advertise-address "$VM2_PRIVATE_IP" \
  --tls-san "$K3S_API_DNS"
```

Giải thích:

- `--cluster-init`: khởi tạo embedded etcd cluster.
- `--disable=traefik`: dùng Nginx Ingress thay Traefik mặc định.
- `--secrets-encryption`: bật encryption cho Kubernetes Secrets ở datastore.
- `--node-ip` và `--advertise-address`: dùng private IP cho cluster traffic.
- `--tls-san`: thêm DNS/IP cố định vào cert của Kubernetes API.

### 8.3. Join VM3 và VM4

Trên VM3:

```bash
export K3S_TOKEN='CHANGE_ME_LONG_RANDOM_K3S_TOKEN'
export VM2_PRIVATE_IP='10.0.0.2'
export VM3_PRIVATE_IP='10.0.0.3'
export K3S_API_DNS='k3s-api.your-domain.com'

curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server "https://$VM2_PRIVATE_IP:6443" \
  --disable=traefik \
  --secrets-encryption \
  --node-ip "$VM3_PRIVATE_IP" \
  --advertise-address "$VM3_PRIVATE_IP" \
  --tls-san "$K3S_API_DNS"
```

Trên VM4 đổi `VM3_PRIVATE_IP` thành `VM4_PRIVATE_IP`.

Kiểm tra:

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
```

Kỳ vọng thấy 3 node đều `Ready`.

## 9. Kubeconfig cho máy cá nhân

Trên VM2:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy về máy cá nhân, sửa `server: https://127.0.0.1:6443` thành:

```yaml
server: https://k3s-api.your-domain.com:6443
```

Test từ máy cá nhân:

```bash
kubectl get nodes
```

Không commit kubeconfig vào repo.

## 10. Cấu hình K3s pull image từ Harbor

Trên cả VM2, VM3, VM4 tạo file:

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<'YAML'
mirrors:
  harbor.your-domain.com:
    endpoint:
      - "https://harbor.your-domain.com"
configs:
  "harbor.your-domain.com":
    auth:
      username: "robot$cab-k3s"
      password: "CHANGE_ME_HARBOR_ROBOT_PULL_TOKEN"
YAML
```

Restart K3s trên từng node:

```bash
sudo systemctl restart k3s
```

Quy tắc:

- Dùng Harbor robot account, không dùng admin password.
- Token robot account nên chỉ có quyền pull trong K3s.
- CI dùng robot account khác có quyền push.

## 11. Add-ons nền tảng trong K3s

### 11.1. Nginx Ingress

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

Với VPS không có cloud load balancer, có thể cần chỉnh chart values theo cách bạn expose public IP. Cách học đơn giản là trỏ DNS vào một node trước, sau đó nâng cấp bằng provider LB, kube-vip hoặc MetalLB.

### 11.2. cert-manager

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Tạo `ClusterIssuer` Let's Encrypt staging trước:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: your-email@your-domain.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
```

Sau khi staging TLS ổn, tạo issuer production:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: your-email@your-domain.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
```

### 11.3. Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Expose bằng Ingress:

```text
argocd.your-domain.com -> argocd-server
```

Khuyến nghị:

- Tắt admin password mặc định sau khi tạo user riêng.
- Kết nối GitOps repo bằng deploy key read-only.
- Dùng `AppProject` để giới hạn namespace được deploy.

### 11.4. Kyverno

Bắt đầu bằng mode dễ học:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace
```

Sau khi ổn, nâng replicas:

```bash
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set cleanupController.replicas=2 \
  --set reportsController.replicas=2
```

Chiến lược policy:

1. Tuần đầu để `Audit`.
2. Fix manifest vi phạm.
3. Chuyển từng policy sang `Enforce`.

Policy nên có:

- Cấm image tag `latest`.
- Chỉ cho image từ `harbor.your-domain.com`.
- Bắt buộc `resources.requests` và `resources.limits`.
- Cấm `privileged: true`.
- Bắt buộc `runAsNonRoot`.
- Cấm `hostPath`.
- Bắt buộc Ingress có TLS.
- Sau này: verify Cosign signature.

### 11.5. Monitoring

Cài Prometheus/Grafana bằng `kube-prometheus-stack`:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace
```

Cài Loki:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  --namespace logging \
  --create-namespace
```

Với lab nhỏ, cấu hình Loki monolithic hoặc single binary trước. Khi dữ liệu log nhiều, chuyển sang mode scalable và dùng object storage.

Dashboard cần có:

- Node CPU/RAM/disk.
- Pod restart count.
- API Gateway latency/error rate.
- Service HTTP status code.
- Kafka lag.
- PostgreSQL connections.
- Redis memory.
- MongoDB ops.
- Argo CD sync status.
- Kyverno policy violations.

## 12. Data layer cho dự án

Dự án hiện dùng:

- PostgreSQL: auth, user, driver, booking, payment, review, places.
- MongoDB: ride, notification.
- Redis: driver, ride, pricing, payment, review.
- Kafka: booking, ride, payment event workflows.

### 12.1. Lộ trình học khuyến nghị

Giai đoạn 1 - chạy được:

- PostgreSQL trong K3s, một cluster, nhiều database.
- MongoDB trong K3s.
- Redis trong K3s.
- Kafka trong K3s.
- PersistentVolume dùng Longhorn hoặc local-path nếu chỉ lab.

Giai đoạn 2 - gần production hơn:

- PostgreSQL dùng CloudNativePG hoặc managed PostgreSQL.
- Kafka dùng Strimzi hoặc managed Kafka.
- MongoDB/Redis có backup và resource limit rõ ràng.
- Data namespace tách riêng `data-staging`, `data-prod`.

Giai đoạn 3 - production thật:

- Database/Kafka nên là managed service hoặc cluster riêng.
- App cluster không nên gánh toàn bộ stateful workload nếu ngân sách/ops chưa đủ.

### 12.2. Nguyên tắc migrate database

Trong Docker Compose production hiện có:

- `postgres-databases`
- `postgres-migrations`
- `auth-admin-bootstrap`
- `kafka-topics-bootstrap`

Khi chuyển sang K3s, mapping sang Kubernetes:

| Compose job | Kubernetes |
| --- | --- |
| `postgres-databases` | `Job` |
| `postgres-migrations` | `Job` hoặc Helm hook |
| `auth-admin-bootstrap` | `Job` |
| `kafka-topics-bootstrap` | `Job` |

Không chạy migration bằng tay trong pod app. App deployment nên chờ job migration hoàn tất trong release flow.

## 13. Repository strategy

Khuyến nghị dùng 2 repo:

```text
cab-booking-system          # app source code
cab-booking-gitops          # Kubernetes manifests/Helm values
```

Lý do:

- App repo chứa code và Dockerfile.
- GitOps repo chứa desired state của cluster.
- GitLab CI chỉ update image tag trong GitOps repo.
- Argo CD chỉ đọc GitOps repo.

Nếu mới học, có thể để trong cùng repo ở thư mục `deploy/`, nhưng sau đó nên tách.

GitOps repo gợi ý:

```text
cab-booking-gitops/
  apps/
    staging/
      cab-booking-system.yaml
    production/
      cab-booking-system.yaml
  charts/
    cab-booking-system/
      Chart.yaml
      values.yaml
      templates/
  values/
    staging.yaml
    production.yaml
  platform/
    ingress-nginx/
    cert-manager/
    kyverno/
    monitoring/
  policies/
    kyverno/
```

Trong app repo có thể thêm sau:

```text
deploy/
  helm/
    cab-booking-system/
  values/
    staging.yaml
    production.yaml
```

## 14. Mapping service sang Kubernetes

Mỗi backend service nên có:

- `Deployment`
- `Service` loại `ClusterIP`
- `ConfigMap` cho config không nhạy cảm
- `Secret` cho secret
- `ServiceMonitor` nếu expose metrics
- `HorizontalPodAutoscaler` sau khi có metrics ổn

Chỉ expose public:

- API Gateway
- Admin dashboard nếu cần
- Argo CD/Grafana với auth chặt

Không expose public:

- Auth service
- Booking service
- Payment service
- PostgreSQL
- MongoDB
- Redis
- Kafka

Ingress production:

```text
api.your-domain.com -> api-gateway service
admin.your-domain.com -> admin-dashboard service
```

Ingress staging:

```text
api-staging.your-domain.com -> api-gateway service in cab-staging
admin-staging.your-domain.com -> admin-dashboard service in cab-staging
```

## 15. Image tagging strategy

Không dùng `latest`.

Tag đề xuất:

```text
harbor.your-domain.com/cab/booking-service:<commit-sha>
harbor.your-domain.com/cab/booking-service:<semver>
harbor.your-domain.com/cab/booking-service:staging-<commit-sha>
```

Trong GitOps values:

```yaml
bookingService:
  image:
    repository: harbor.your-domain.com/cab/booking-service
    tag: 8f3a9c2
```

Production chỉ deploy image tag đã đi qua staging.

## 16. GitLab CI pipeline chi tiết

### 16.1. Stages

```yaml
stages:
  - validate
  - test
  - security-code
  - quality
  - build
  - security-image
  - publish
  - deploy-staging
  - verify-staging
  - promote-production
```

### 16.2. Validate

Mục tiêu: bắt lỗi config sớm.

```bash
docker compose --env-file /secure/path/pro.required.env -f infra/docker-compose.pro.yml config
sh -n infra/postgres/pro-init/*.sh infra/kafka/*.sh scripts/postgres/*.sh
```

### 16.3. Test

```bash
npm ci
npm test --workspaces --if-present -- --runInBand
cd services/gateway && go test ./...
```

### 16.4. Secret scan bằng Gitleaks

```bash
gitleaks detect --source . --redact --exit-code 1
```

Quy tắc:

- Fail ngay nếu phát hiện secret thật.
- Nếu false positive, thêm allowlist có lý do rõ ràng.
- Không bao giờ allowlist cả file `.env` production.

### 16.5. SAST bằng Semgrep

```bash
semgrep scan --config auto --error
```

Lúc mới áp dụng, có thể chạy non-blocking vài ngày:

```bash
semgrep scan --config auto || true
```

Sau khi fix baseline, chuyển sang blocking.

### 16.6. SonarQube quality gate

```bash
sonar-scanner \
  -Dsonar.projectKey=cab-booking-system \
  -Dsonar.sources=. \
  -Dsonar.host.url="$SONAR_HOST_URL" \
  -Dsonar.token="$SONAR_TOKEN"
```

Quality gate nên bắt:

- New code coverage không giảm mạnh.
- Không có blocker/critical issue trên new code.
- Duplications ở mức kiểm soát được.

### 16.7. IaC/Kubernetes scan bằng Trivy

```bash
trivy config --exit-code 1 --severity HIGH,CRITICAL .
```

Scan Helm rendered manifests tốt hơn scan template thô:

```bash
helm template cab deploy/helm/cab-booking-system -f deploy/values/staging.yaml > rendered.yaml
trivy config --exit-code 1 --severity HIGH,CRITICAL rendered.yaml
```

### 16.8. Build image

Vì repo nhiều service, ban đầu có thể build tất cả. Sau này tối ưu build service thay đổi.

Ví dụ booking-service:

```bash
docker build \
  -f services/booking-service/Dockerfile \
  -t "$HARBOR_REGISTRY/cab/booking-service:$CI_COMMIT_SHA" \
  .
```

### 16.9. Image scan bằng Trivy

```bash
trivy image \
  --exit-code 1 \
  --severity CRITICAL,HIGH \
  "$HARBOR_REGISTRY/cab/booking-service:$CI_COMMIT_SHA"
```

Giai đoạn học:

- Fail `CRITICAL`.
- Ghi report `HIGH` để học cách triage.

Giai đoạn hardening:

- Fail `CRITICAL,HIGH`.
- Chỉ allowlist CVE có lý do và expiry date.

### 16.10. Push Harbor

```bash
docker login "$HARBOR_REGISTRY" -u "$HARBOR_PUSH_USER" -p "$HARBOR_PUSH_PASSWORD"
docker push "$HARBOR_REGISTRY/cab/booking-service:$CI_COMMIT_SHA"
```

Harbor nên bật scan on push. CI scan là gate thứ nhất, Harbor scan là gate thứ hai.

### 16.11. Update GitOps staging

CI clone GitOps repo bằng deploy key:

```bash
git clone git@gitlab.your-domain.com:cab/cab-booking-gitops.git
cd cab-booking-gitops
yq -i '.bookingService.image.tag = strenv(CI_COMMIT_SHA)' values/staging.yaml
git commit -am "deploy staging $CI_COMMIT_SHA"
git push
```

Argo CD thấy GitOps repo đổi và sync vào `cab-staging`.

### 16.12. Verify staging

Smoke test:

```bash
curl -f https://api-staging.your-domain.com/health
curl -f https://api-staging.your-domain.com/readyz
```

Test API:

```bash
newman run scripts/postman/level1-1-10.postman_collection.json \
  --env-var baseUrl=https://api-staging.your-domain.com
```

DAST cơ bản:

```bash
zap-baseline.py -t https://api-staging.your-domain.com -r zap-report.html
```

### 16.13. Promote production

Không auto production từ mọi commit.

Luồng khuyến nghị:

1. Staging pass.
2. Tạo merge request trong GitOps repo từ `staging` sang `production`.
3. Review diff image tags.
4. Manual approval.
5. Merge.
6. Argo CD sync `cab-prod`.

Production rollback:

```bash
git revert <gitops-commit>
```

Argo CD sẽ đưa cluster về image tag trước đó.

## 17. Biến GitLab CI cần tạo

Trong GitLab project/group settings:

| Variable | Protected | Masked | Mục đích |
| --- | --- | --- | --- |
| `HARBOR_REGISTRY` | yes | no | `harbor.your-domain.com` |
| `HARBOR_PUSH_USER` | yes | yes | robot push user |
| `HARBOR_PUSH_PASSWORD` | yes | yes | robot push token |
| `SONAR_HOST_URL` | yes | no | `https://sonar.your-domain.com` |
| `SONAR_TOKEN` | yes | yes | token scanner |
| `GITOPS_REPO_SSH_KEY` | yes | yes | deploy key push GitOps repo |
| `ARGOCD_AUTH_TOKEN` | optional | yes | chỉ dùng nếu CI gọi Argo CD API |

Không đưa production app secrets vào GitLab CI nếu Argo CD không cần. App secrets nên nằm trong Kubernetes Secret hoặc secret manager.

## 18. Secrets cho ứng dụng

Tạm thời khi học:

```bash
kubectl -n cab-staging create secret generic cab-secrets \
  --from-env-file=/secure/path/app-secrets.staging.env
```

Nhưng không dùng file production thật từ repo.

Hardening sau:

- Dùng SOPS hoặc Sealed Secrets.
- Hoặc dùng External Secrets Operator với Vault/1Password/AWS/GCP.
- GitOps repo không chứa secret plaintext.

Nguyên tắc:

- Secret staging khác production.
- Rotate `JWT_SECRET`, `INTERNAL_API_KEY`, DB passwords, PayOS keys.
- Không dùng `.env` local cho K3s.

## 19. Argo CD Applications

Tạo app cho staging:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cab-staging
  namespace: argocd
spec:
  project: cab
  source:
    repoURL: git@gitlab.your-domain.com:cab/cab-booking-gitops.git
    targetRevision: main
    path: charts/cab-booking-system
    helm:
      valueFiles:
        - ../../values/staging.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cab-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Production nên cân nhắc không auto-sync lúc đầu:

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true
```

Khi đã tự tin, có thể bật auto-sync production nhưng vẫn yêu cầu GitLab manual approval trước khi update GitOps repo.

## 20. Kyverno policy baseline

Triển khai policy theo thứ tự:

1. `disallow-latest-tag`
2. `require-requests-limits`
3. `require-run-as-non-root`
4. `disallow-privileged`
5. `restrict-image-registries`
6. `require-ingress-tls`
7. `verify-image-signatures`

Ví dụ restrict registry:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Audit
  rules:
    - name: only-harbor
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must come from harbor.your-domain.com"
        pattern:
          spec:
            containers:
              - image: "harbor.your-domain.com/*"
```

Khi không còn violation:

```yaml
validationFailureAction: Enforce
```

## 21. Monitoring và alert tối thiểu

Alert nên có ngay:

| Alert | Điều kiện |
| --- | --- |
| Node disk high | disk > 80% |
| Node memory high | memory > 85% |
| Pod crashloop | restart tăng liên tục |
| Deployment unavailable | replicas available = 0 |
| API gateway 5xx high | 5xx rate vượt ngưỡng |
| API latency high | p95 latency vượt ngưỡng |
| Kafka consumer lag high | lag tăng liên tục |
| Argo app out of sync | app drift |
| Certificate expiring | TLS cert sắp hết hạn |
| Kyverno policy violation | violation mới |

Grafana dashboards:

- Kubernetes cluster overview.
- Node exporter full.
- Nginx Ingress controller.
- Argo CD.
- Loki logs by namespace/app.
- Application HTTP metrics.

## 22. Resource quota cho namespace

Staging:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: cab-staging-quota
  namespace: cab-staging
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
```

Production:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: cab-prod-quota
  namespace: cab-prod
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
```

Số này chỉ là ví dụ. Sau khi có metrics thật, chỉnh lại.

## 23. Chiến lược rollout

Mỗi service nên dùng:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

Probe tối thiểu:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
readinessProbe:
  httpGet:
    path: /readyz
    port: http
```

Nếu service chưa có `/readyz`, thêm trước khi production hóa.

## 24. Backup và restore

Không gọi là production nếu chưa có restore test.

Backup tối thiểu:

- GitLab backup.
- Harbor registry data.
- SonarQube DB.
- K3s etcd snapshot.
- PostgreSQL dump/base backup.
- MongoDB dump.
- Redis snapshot nếu dữ liệu cần giữ.
- Kafka topic configs và critical topic retention.

K3s etcd snapshot nên chạy định kỳ. Lưu snapshot ra object storage hoặc VPS khác, không chỉ để trên cùng node.

Restore drill mỗi tháng:

1. Tạo cluster test.
2. Restore database.
3. Restore secrets.
4. Deploy app bằng Argo CD.
5. Chạy smoke test.

## 25. Lộ trình học theo tuần

### Tuần 1 - Nền tảng

- Mua VPS.
- Setup DNS, SSH key, firewall.
- Cài GitLab, Harbor, SonarQube trên VM1.
- Cài K3s 3 node.
- Cài kubectl/helm local.

Kết quả: `kubectl get nodes` thấy 3 node Ready.

### Tuần 2 - Platform add-ons

- Cài Nginx Ingress.
- Cài cert-manager.
- Cài Argo CD.
- Cài Kyverno Audit.
- Cài Prometheus/Grafana/Loki.

Kết quả: mở được Argo CD và Grafana qua HTTPS.

### Tuần 3 - App packaging

- Viết Helm chart hoặc Kustomize cho app.
- Mapping ConfigMap/Secret.
- Mapping migration jobs.
- Deploy staging bằng Argo CD.

Kết quả: `api-staging.your-domain.com/health` OK.

### Tuần 4 - CI/CD

- GitLab CI test.
- Gitleaks/Semgrep/SonarQube.
- Build image.
- Trivy image scan.
- Push Harbor.
- Update GitOps staging.

Kết quả: push code tự deploy staging.

### Tuần 5 - Production flow

- Tạo namespace `cab-prod`.
- Manual approval production.
- Promote bằng GitOps MR.
- Rollback bằng git revert.

Kết quả: staging và production deploy độc lập.

### Tuần 6 - Hardening

- Kyverno Enforce từng policy.
- Resource quota.
- Alert rules.
- Backup/restore drill.
- Runbook sự cố.

Kết quả: có quy trình vận hành, không chỉ deploy được.

## 26. Definition of Done

Bạn chỉ xem là hoàn thành khi:

- GitLab pipeline pass từ test tới image scan.
- Harbor có image theo commit SHA.
- Argo CD tự sync staging.
- Production deploy qua manual approval.
- Không dùng image `latest`.
- K3s pull image từ Harbor.
- API Gateway public qua HTTPS.
- Các service nội bộ chỉ là ClusterIP.
- Kyverno có ít nhất 5 policy ở `Enforce`.
- Grafana có dashboard cluster và app.
- Loki xem được log theo namespace/service.
- Có backup và restore test tối thiểu một lần.

## 27. Những lỗi người mới hay mắc

- Mua VPS quá yếu rồi tưởng Kubernetes lỗi.
- Chạy production bằng `.env` local.
- Dùng image `latest`.
- Push thẳng production không qua staging.
- Cài hết tool cùng lúc rồi không biết lỗi từ đâu.
- Public Kubernetes API và etcd ra internet.
- Lưu secret plaintext trong GitOps repo.
- Không có resource limits nên một service ăn hết RAM node.
- Cài Kyverno `Enforce` quá sớm làm deploy chết hàng loạt.
- Có backup nhưng chưa từng restore.

## 28. Thứ tự ưu tiên khi gặp lỗi

Khi lỗi deploy, debug theo thứ tự:

```bash
kubectl get nodes
kubectl get pods -A
kubectl -n argocd get applications
kubectl -n cab-staging get deploy,svc,ingress
kubectl -n cab-staging describe pod <pod>
kubectl -n cab-staging logs <pod>
kubectl -n kyverno get policyreport -A
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller
```

Nếu image pull lỗi:

1. Kiểm tra image có trong Harbor không.
2. Kiểm tra tag đúng commit SHA không.
3. Kiểm tra `registries.yaml` trên cả 3 K3s nodes.
4. Restart K3s sau khi sửa registry config.
5. Kiểm tra Harbor robot token.

Nếu TLS lỗi:

1. Kiểm tra DNS trỏ đúng ingress IP.
2. Kiểm tra `ClusterIssuer`.
3. Kiểm tra `Certificate`.
4. Kiểm tra cert-manager logs.
5. Dùng Let's Encrypt staging trước production.

## 29. Việc nên làm sau khi chạy được

- Tách GitOps repo riêng.
- Thêm Cosign image signing.
- Thêm Kyverno verify images.
- Thêm External Secrets hoặc SOPS.
- Thêm NetworkPolicy.
- Thêm backup tự động.
- Thêm DAST bằng OWASP ZAP trong pipeline.
- Thêm load test nhẹ cho staging.
- Tách database/Kafka khỏi app cluster nếu muốn production thật.

## 30. Tài liệu chính thức nên đọc

- K3s HA embedded etcd: https://docs.k3s.io/datastore/ha-embedded
- K3s private registry: https://docs.k3s.io/installation/private-registry
- K3s packaged components và disable Traefik: https://docs.k3s.io/installation/packaged-components
- GitLab CI pipelines: https://docs.gitlab.com/ci/pipelines/
- GitLab CI YAML syntax: https://docs.gitlab.com/ci/yaml/
- Harbor vulnerability scanning: https://goharbor.io/docs/main/administration/vulnerability-scanning/
- Trivy CLI image scan: https://trivy.dev/docs/v0.69/guide/references/configuration/cli/trivy_image/
- Semgrep CE in CI: https://semgrep.dev/docs/deployment/oss-deployment
- SonarScanner CLI: https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/scanners/sonarscanner/
- Argo CD declarative setup: https://argo-cd.readthedocs.io/en/latest/operator-manual/declarative-setup/
- Kyverno installation: https://kyverno.io/docs/installation/installation/
- Kyverno validate rules: https://kyverno.io/docs/policy-types/cluster-policy/validate/
- Ingress Nginx installation: https://kubernetes.github.io/ingress-nginx/deploy/
- cert-manager Helm install: https://cert-manager.io/docs/installation/helm/
- Grafana Loki Helm install: https://grafana.com/docs/loki/latest/setup/install/helm/
