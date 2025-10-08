#!/usr/bin/env bash
set -euo pipefail

# =========================
#  Мінімальний restart CP
#  з підтримкою staticPods
# =========================

# --- Базові змінні ---
HOST_IP=$(hostname -I | awk '{print $1}')
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
STATIC_PODS_DIR="/workspaces/mastering-k8s-2025/manifests/staticpods"
LOG_DIR="/var/log/kubernetes"
PKI_DIR="/etc/kubernetes/pki"

echo "HOST_IP=${HOST_IP}"
sudo mkdir -p "$STATIC_PODS_DIR" "$LOG_DIR" "$PKI_DIR" /root/.kube /var/lib/kubelet /var/lib/etcd

# --- Допоміжні функції ---
log()  { echo -e "[info] $*"; }
warn() { echo -e "[warn] $*"; }
err()  { echo -e "[ERR ] $*" >&2; }

wait_for_readyz() {
  local tries=${1:-60}
  for _ in $(seq 1 "$tries"); do
    if curl -sk --max-time 1 https://127.0.0.1:6443/readyz >/dev/null 2>&1; then
      log "kube-apiserver готовий (readyz=ok)"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_port() {
  local port="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    if ss -lnt "( sport = :${port} )" | grep -q ":${port}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Генеруємо/копіюємо kubeconfig у /root/.kube/config і дубль у /var/lib/kubelet/kubeconfig
ensure_root_kubeconfig() {
  if sudo test -s /root/.kube/config; then
    log "/root/.kube/config існує — ок"
  else
    if [ -n "${KUBECONFIG:-}" ] && sudo test -s "$KUBECONFIG"; then
      log "Копіюю kubeconfig з \$KUBECONFIG ($KUBECONFIG) у /root/.kube/config"
      sudo cp "$KUBECONFIG" /root/.kube/config
      sudo chmod 600 /root/.kube/config
    else
      log "Генерую мінімальний /root/.kube/config на основі токена"
      local token
      token=$(sudo awk -F, 'NR==1{print $1}' "${PKI_DIR}/token.csv" 2>/dev/null || echo "1234567890")
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
  fi

  # Дубль для controller-manager (його staticPod монтує /var/lib/kubelet/kubeconfig)
  sudo cp /root/.kube/config /var/lib/kubelet/kubeconfig
  sudo chmod 600 /var/lib/kubelet/kubeconfig
}

# --- Артефакти у /tmp (токен/ключі) ---
test -s /tmp/token.csv || { TOKEN="1234567890"; echo "$TOKEN,admin,admin,system:masters" | sudo tee /tmp/token.csv >/dev/null; sudo chmod 600 /tmp/token.csv; }
test -s /tmp/sa.key    || openssl genrsa -out /tmp/sa.key 2048 >/dev/null 2>&1
test -s /tmp/sa.pub    || openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub >/dev/null 2>&1
test -s /tmp/ca.crt    || sudo cp /var/lib/kubelet/ca.crt /tmp/ca.crt

# --- PKI для staticPods: розміщуємо туди, куди дивляться маніфести ---
log "Синхронізую PKI у ${PKI_DIR}"
sudo install -m 600 /tmp/token.csv "${PKI_DIR}/token.csv"
sudo install -m 600 /tmp/sa.key    "${PKI_DIR}/sa.key"
sudo install -m 644 /tmp/sa.pub    "${PKI_DIR}/sa.pub"
sudo install -m 644 /tmp/ca.crt    "${PKI_DIR}/ca.crt"

# --- kubeconfig для scheduler/controller-manager ---
ensure_root_kubeconfig

# --- kubelet: налаштовуємо staticPodPath на каталог з нашими YAML ---
if sudo grep -q '^staticPodPath:' /var/lib/kubelet/config.yaml; then
  sudo sed -i "s#^staticPodPath:.*#staticPodPath: \"${STATIC_PODS_DIR}\"#" /var/lib/kubelet/config.yaml
else
  echo "staticPodPath: \"${STATIC_PODS_DIR}\"" | sudo tee -a /var/lib/kubelet/config.yaml >/dev/null
fi

# --- Якщо є static pod YAML-и — вбиваємо ручні процеси, даємо kubelet’у керувати ---
if ls "${STATIC_PODS_DIR}"/*.yaml >/dev/null 2>&1; then
  log "Знайдено static pod маніфести у ${STATIC_PODS_DIR} — перемикаємось на режим staticPods"
  sudo pkill -f 'kubebuilder/bin/kube-apiserver'          || true
  sudo pkill -f 'kubebuilder/bin/kube-controller-manager' || true
  sudo pkill -f 'kubebuilder/bin/kube-scheduler'          || true
  sudo pkill -f 'kubebuilder/bin/etcd'                    || true
else
  log "StaticPod маніфестів ще нема — запускаю control plane вручну (тимчасово)"
  # etcd
  sudo env HOST_IP="$HOST_IP" bash -c "kubebuilder/bin/etcd \
    --advertise-client-urls http://${HOST_IP}:2379 \
    --listen-client-urls http://0.0.0.0:2379 \
    --data-dir ./etcd \
    --listen-peer-urls http://0.0.0.0:2380 \
    --initial-cluster default=http://${HOST_IP}:2380 \
    --initial-advertise-peer-urls http://${HOST_IP}:2380 \
    --initial-cluster-state new \
    --initial-cluster-token test-token >> ${LOG_DIR}/etcd.log 2>&1 &"

  # kube-apiserver
  sudo env HOST_IP="$HOST_IP" bash -c "kubebuilder/bin/kube-apiserver \
    --etcd-servers=http://${HOST_IP}:2379 \
    --service-cluster-ip-range=10.0.0.0/24 \
    --bind-address=0.0.0.0 \
    --secure-port=6443 \
    --advertise-address=${HOST_IP} \
    --authorization-mode=AlwaysAllow \
    --token-auth-file=${PKI_DIR}/token.csv \
    --enable-priority-and-fairness=false \
    --allow-privileged=true \
    --profiling=false \
    --storage-backend=etcd3 \
    --storage-media-type=application/json \
    --v=0 \
    --cloud-provider=external \
    --service-account-issuer=https://kubernetes.default.svc.cluster.local \
    --service-account-key-file=${PKI_DIR}/sa.pub \
    --service-account-signing-key-file=${PKI_DIR}/sa.key >> ${LOG_DIR}/kube-apiserver.log 2>&1 &"

  # kube-controller-manager
  sudo bash -c "PATH=\$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kube-controller-manager \
    --kubeconfig=/var/lib/kubelet/kubeconfig \
    --leader-elect=false \
    --cloud-provider=external \
    --service-cluster-ip-range=10.0.0.0/24 \
    --cluster-name=kubernetes \
    --root-ca-file=${PKI_DIR}/ca.crt \
    --service-account-private-key-file=${PKI_DIR}/sa.key \
    --use-service-account-credentials=true \
    --v=2 >> ${LOG_DIR}/kube-controller-manager.log 2>&1 &"

  # kube-scheduler
  sudo bash -c "kubebuilder/bin/kube-scheduler \
    --kubeconfig=/root/.kube/config \
    --leader-elect=false \
    --v=2 \
    --bind-address=0.0.0.0 >> ${LOG_DIR}/kube-scheduler.log 2>&1 &"
fi

# --- containerd (автовмикання, якщо не працює) ---
if ! pgrep -x containerd >/dev/null 2>&1 || ! test -S /run/containerd/containerd.sock; then
  log "containerd не працює — стартую локальний containerd"
  sudo mkdir -p /var/log/kubernetes /run/containerd /var/lib/containerd
  sudo bash -c "PATH=\$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml >> ${LOG_DIR}/containerd.log 2>&1 &" || true
  for i in {1..30}; do
    if test -S /run/containerd/containerd.sock; then
      log "containerd socket OK"
      break
    fi
    sleep 1
  done
  if ! test -S /run/containerd/containerd.sock; then
    warn "containerd socket не з’явився за 30с; останні логи:"
    sudo tail -n 100 "${LOG_DIR}/containerd.log" || true
  fi
fi

# --- kubelet перезапуск (щоб підхопив staticPodPath та PKI) ---
sudo pkill -f 'kubebuilder/bin/kubelet' || true
sudo env HOST_IP="$HOST_IP" bash -c "PATH=\$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --config=/var/lib/kubelet/config.yaml \
  --root-dir=/var/lib/kubelet \
  --cert-dir=/var/lib/kubelet/pki \
  --hostname-override=$(hostname) \
  --pod-infra-container-image=registry.k8s.io/pause:3.10 \
  --node-ip=${HOST_IP} \
  --cloud-provider=external \
  --cgroup-driver=cgroupfs \
  --max-pods=20 \
  --v=1 >> ${LOG_DIR}/kubelet.log 2>&1 &"

# --- Автовиправлення після зміни IP ноди ---
if sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get nodes >/dev/null 2>&1; then
  CUR_IP=$(sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
  if [ -n "$CUR_IP" ] && [ "$CUR_IP" != "$HOST_IP" ]; then
    warn "InternalIP ноди в API ($CUR_IP) != поточний HOST_IP ($HOST_IP). Перереєструю ноду…"
    sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config delete node "$(hostname)" || true
    # зачекати, поки kubelet знову зареєструє ноду
    for i in {1..30}; do
      NEW_IP=$(sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
      [ "$NEW_IP" = "$HOST_IP" ] && { log "Ноду перереєстровано з IP $NEW_IP"; break; }
      sleep 1
    done
  fi
fi


# --- Очікуємо порт/готовність API ---
log "Чекаю на порт 6443..."
wait_for_port 6443 60 || warn "порт 6443 ще не слухає (може APIServer підіймається повільніше)"
if ! wait_for_readyz 90; then
  warn "kube-apiserver не повернув readyz=ok за відведений час"
fi

# --- Прибрати taint (якщо був) ---
sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config taint nodes "$(hostname)" node.cloudprovider.kubernetes.io/uninitialized- >/dev/null 2>&1 || true

# --- Показати поточний стан ---
set +e
sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get nodes -o wide
sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get pods -A -o wide
set -e
