#!/bin/sh
set -eu

: "${K3S_TOKEN:?K3S_TOKEN is required}"
: "${K3S_SERVER_1_PRIVATE_IP:?K3S_SERVER_1_PRIVATE_IP is required}"
: "${K3S_JOIN_NODE_PRIVATE_IP:?K3S_JOIN_NODE_PRIVATE_IP is required}"
: "${K3S_API_HOST:?K3S_API_HOST is required}"

curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --server "https://$K3S_SERVER_1_PRIVATE_IP:6443" \
  --disable=traefik \
  --secrets-encryption \
  --node-ip "$K3S_JOIN_NODE_PRIVATE_IP" \
  --advertise-address "$K3S_JOIN_NODE_PRIVATE_IP" \
  --tls-san "$K3S_API_HOST"

