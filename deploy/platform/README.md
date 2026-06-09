# Platform Layer

Platform layer là phần cài trước app. Hãy hiểu theo thứ tự:

```text
VPS network -> K3s -> storage -> ingress/TLS -> policy -> monitoring -> Argo CD -> app
```

Nếu thiếu platform layer, app có thể vẫn chạy tạm, nhưng sẽ thiếu HTTPS, thiếu policy, thiếu log/metric và không đúng GitOps.

## 1. Chuẩn bị mạng VPS

Trên 4 VPS, nên có 2 loại IP:

- Public IP: nhận request từ Internet.
- Private IP: K3s nodes nói chuyện với nhau.

Không nên để etcd, kubelet, overlay network mở public. File `k3s/ufw-rules.sh` chỉ mở:

| Port | Nguồn | Lý do |
| --- | --- | --- |
| `22` | IP máy bạn | SSH quản trị. |
| `80`, `443` | Internet | HTTP/HTTPS qua Nginx Ingress. |
| `6443` | IP máy bạn và private CIDR | Kubernetes API. |
| `2379-2380` | private CIDR | etcd giữa 3 server node. |
| `10250` | private CIDR | kubelet metrics/exec/log. |
| `8472/udp` | private CIDR | Flannel VXLAN. |

Ví dụ:

```bash
export PRIVATE_CIDR=10.0.0.0/24
export ADMIN_IP=1.2.3.4
sh deploy/platform/k3s/ufw-rules.sh
```

## 2. Cài K3s HA

Trên node đầu tiên:

```bash
set -a
. /secure/path/cluster.env
set +a

sudo mkdir -p /etc/rancher/k3s
sudo cp /secure/path/registries.yaml /etc/rancher/k3s/registries.yaml
sh deploy/platform/k3s/install-first-server.sh
```

Trên node thứ 2 và thứ 3:

```bash
set -a
. /secure/path/cluster.env
set +a

export K3S_JOIN_NODE_PRIVATE_IP=10.0.0.3
sudo mkdir -p /etc/rancher/k3s
sudo cp /secure/path/registries.yaml /etc/rancher/k3s/registries.yaml
sh deploy/platform/k3s/install-join-server.sh
```

Sau đó lấy kubeconfig từ node đầu:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Đổi `127.0.0.1` trong kubeconfig thành DNS/IP của K3s API.

## 3. Cài namespace nền

```bash
kubectl apply -f deploy/platform/namespaces.yaml
```

## 4. Cài storage

Xem `storage/README.md`. Với database chạy trong K3s, nên cài Longhorn trước data layer.

## 5. Cài ingress và TLS

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f deploy/platform/ingress-nginx/values.yaml

helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --set crds.enabled=true

kubectl apply -f deploy/platform/cert-manager/cluster-issuers.yaml
```

`cluster-issuers.yaml` có staging và production issuer. Khi mới học, dùng staging issuer trước để tránh bị Let's Encrypt rate limit.

## 6. Cài policy bằng Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno -n kyverno
kubectl apply -f deploy/platform/kyverno/baseline-policies.yaml
```

Policy đang để `Audit` để bạn học trước. Khi đã chắc, đổi dần policy quan trọng sang `Enforce`.

## 7. Cài monitoring

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f deploy/platform/monitoring/kube-prometheus-stack.values.yaml

helm upgrade --install loki grafana/loki \
  -n monitoring \
  -f deploy/platform/monitoring/loki.values.yaml
```

Prometheus/Grafana theo dõi metric. Loki giữ log để debug khi service lỗi trên K3s.

## 8. Cài Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd -n argocd

kubectl apply -f deploy/platform/argocd/appproject.yaml
kubectl apply -f deploy/platform/argocd/application-staging.yaml
kubectl apply -f deploy/platform/argocd/application-production.yaml
```

Argo CD là người deploy app. GitLab CI chỉ cập nhật image tag trong GitOps repo, không chạy `kubectl apply` trực tiếp vào production.
