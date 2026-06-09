# Storage Cho K3s

K3s có `local-path` mặc định, nhưng storage đó bám vào từng node. Với database trên nhiều VPS, bạn nên dùng storage có replication như Longhorn để khi một node chết thì PVC vẫn có bản sao ở node khác.

## Cài Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install longhorn longhorn/longhorn \
  -n longhorn-system \
  -f deploy/platform/storage/longhorn.values.yaml
```

Sau khi cài xong, kiểm tra:

```bash
kubectl -n longhorn-system get pods
kubectl get storageclass
```

Với lab nhỏ, `defaultReplicaCount: 2` là điểm cân bằng giữa an toàn và dung lượng. Production thật nên tính lại theo dung lượng VPS, IOPS và backup policy.
