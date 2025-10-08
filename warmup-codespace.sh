#!/usr/bin/env bash
set -euo pipefail

HOST_IP=$(hostname -I | awk '{print $1}')
STATIC_PODS_DIR="/workspaces/mastering-k8s-2025/manifests/staticpods"
LOG_DIR="/var/log/kubernetes"
PKI_DIR="/etc/kubernetes/pki"

echo "HOST_IP=${HOST_IP}"
sudo mkdir -p "$LOG_DIR" "$PKI_DIR" /root/.kube /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /run/containerd

log(){ echo -e "[warmup] $*"; }

# 1) PKI + токен
test -s /tmp/token.csv || { TOKEN="1234567890"; echo "$TOKEN,admin,admin,system:masters" | sudo tee /tmp/token.csv >/dev/null; sudo chmod 600 /tmp/token.csv; }
test -s /tmp/sa.key || openssl genrsa -out /tmp/sa.key 2048 >/dev/null 2>&1
test -s /tmp/sa.pub || openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub >/dev/null 2>&1
# ca.crt беремо із попередніх запусків kubelet (як у тебе)
test -s /tmp/ca.crt || { sudo test -s /var/lib/kubelet/ca.crt && sudo cp /var/lib/kubelet/ca.crt /tmp/ca.crt || true; }

sudo install -m600 /tmp/token.csv "${PKI_DIR}/token.csv"
sudo install -m600 /tmp/sa.key    "${PKI_DIR}/sa.key"
sudo install -m644 /tmp/sa.pub    "${PKI_DIR}/sa.pub"
test -s /tmp/ca.crt && sudo install -m644 /tmp/ca.crt "${PKI_DIR}/ca.crt" || true

# 2) kubeconfig під токен
if ! sudo test -s /root/.kube/config; then
  log "генерую /root/.kube/config"
  token=$(sudo awk -F, 'NR==1{print $1}' "${PKI_DIR}/token.csv")
  sudo tee /root/.kube/config >/dev/null <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://127.0.0.1:6443
    insecure-skip-tls-verify: true
  name: lab
contexts:
- context:
    cluster: lab
    user: admin
  name: lab
current-context: lab
users:
- name: admin
  user:
    token: ${token}
EOF
  sudo chmod 600 /root/.kube/config
fi
sudo cp /root/.kube/config /var/lib/kubelet/kubeconfig
sudo chmod 600 /var/lib/kubelet/kubeconfig

# 3) containerd: запустити і дочекатися сокета (болтDB інколи «довго прокидається»)
if ! pgrep -x containerd >/dev/null 2>&1 || ! test -S /run/containerd/containerd.sock; then
  log "стартую containerd"
  sudo bash -c "PATH=\$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml >> ${LOG_DIR}/containerd.log 2>&1 &"
fi
for i in {1..20}; do
  test -S /run/containerd/containerd.sock && { log "containerd socket OK"; break; }
  sleep 1
done

# 4) попереднє завантаження образів (щоб staticPod не чекав pull на холодному кеші)
IMAGES=(
  "registry.k8s.io/etcd:3.5.13-0"
  "registry.k8s.io/kube-apiserver:v1.30.0"
  "registry.k8s.io/kube-controller-manager:v1.30.0"
  "registry.k8s.io/kube-scheduler:v1.30.0"
  "registry.k8s.io/pause:3.10"
  "nginx:1.25-alpine"
)
for img in "${IMAGES[@]}"; do
  sudo /opt/cni/bin/ctr -n k8s.io images pull "$img" >/dev/null 2>&1 || true
done
log "images pre-pulled (best-effort)"

# 5) kubelet config: staticPodPath → наш каталог
sudo mkdir -p "$STATIC_PODS_DIR"
if sudo grep -q '^staticPodPath:' /var/lib/kubelet/config.yaml; then
  sudo sed -i "s#^staticPodPath:.*#staticPodPath: \"${STATIC_PODS_DIR}\"#" /var/lib/kubelet/config.yaml
else
  echo "staticPodPath: \"${STATIC_PODS_DIR}\"" | sudo tee -a /var/lib/kubelet/config.yaml >/dev/null
fi

log "warmup done"
