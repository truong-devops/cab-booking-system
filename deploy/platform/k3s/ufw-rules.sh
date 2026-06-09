#!/bin/sh
set -eu

# Run on each K3s node after setting PRIVATE_CIDR and ADMIN_IP.
PRIVATE_CIDR="${PRIVATE_CIDR:-10.0.0.0/24}"
ADMIN_IP="${ADMIN_IP:-CHANGE_ME_ADMIN_PUBLIC_IP}"

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow from "$ADMIN_IP" to any port 22 proto tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow from "$ADMIN_IP" to any port 6443 proto tcp

sudo ufw allow from "$PRIVATE_CIDR" to any port 2379:2380 proto tcp
sudo ufw allow from "$PRIVATE_CIDR" to any port 6443 proto tcp
sudo ufw allow from "$PRIVATE_CIDR" to any port 10250 proto tcp
sudo ufw allow from "$PRIVATE_CIDR" to any port 8472 proto udp

sudo ufw enable
sudo ufw status verbose
