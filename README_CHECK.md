# Manual Kubernetes Control Plane (single‑node) — Codespaces‑safe README

**Goal:** reproduce a minimal Kubernetes control plane on one VM/container (e.g. GitHub Codespaces) using raw binaries. This README fixes the rough edges in the original guide so the system comes up **cleanly and repeatably**.

> ⚠️ Education only. Insecure settings, static tokens, no HA. **Do not** use in production.

---

## What’s different vs original
- Ensures `$HOST_IP` is available inside `sudo` (or the value will be empty and etcd/apiserver fail).
- Restores ephemeral `/tmp` artifacts after a Codespaces stop (token, SA keys, CA copy).
- Explains the **cloud-provider=external** taint and two ways to handle it (run CCM *or* remove taint).
- Adds strict start order, health checks, and a one‑shot **restart script**.
- Adds minimal troubleshooting notes.

---

## Versions
- Kubernetes: **v1.30.0** (kubelet, kube‑apiserver, kube‑controller‑manager, kube‑scheduler)
- etcd via kubebuilder-tools (**3.5.x**)
- containerd: **v2.0.5**
- runc: **v1.2.6**
- CNI plugins: **v1.6.2**

---

## 0) Prereqs
```bash
set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"
# Useful alias for verbose curl
alias curlr='curl -sS --retry 3 --retry-connrefused --max-time 5'
```

> **Codespaces notes**
> - `$HOST_IP` changes between restarts.
> - Background processes die on stop.
> - `/tmp` is ephemeral. Recreate files there after each stop.

---

## 1) Create required directories
```bash
sudo mkdir -p ./kubebuilder/bin \
  /etc/cni/net.d \
  /var/lib/kubelet/pki \
  /var/lib/kubelet \
  /etc/kubernetes/manifests \
  /var/log/kubernetes \
  /etc/containerd \
  /run/containerd \
  /opt/cni/bin
```

---

## 2) Download core components
```bash
# kubebuilder tools (includes etcd, kubectl, etc.)
curl -L https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-1.30.0-linux-amd64.tar.gz -o /tmp/kubebuilder-tools.tar.gz
sudo tar -C ./kubebuilder --strip-components=1 -zxf /tmp/kubebuilder-tools.tar.gz
rm /tmp/kubebuilder-tools.tar.gz
sudo chmod -R 755 ./kubebuilder/bin

# kubelet
sudo curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kubelet" -o kubebuilder/bin/kubelet
sudo chmod 755 kubebuilder/bin/kubelet
```

---

## 3) Install container runtime (containerd + runc + CNI)
```bash
# containerd (static build)
wget https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-static-2.0.5-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
sudo tar zxf /tmp/containerd.tar.gz -C /opt/cni/
rm /tmp/containerd.tar.gz

# runc
sudo curl -L "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64" -o /opt/cni/bin/runc
sudo chmod +x /opt/cni/bin/runc

# CNI plugins
wget https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -O /tmp/cni-plugins.tgz
sudo tar zxf /tmp/cni-plugins.tgz -C /opt/cni/bin/
rm /tmp/cni-plugins.tgz
```

---

## 4) Download additional control plane binaries
```bash
sudo curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-controller-manager" -o kubebuilder/bin/kube-controller-manager
sudo curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-scheduler" -o kubebuilder/bin/kube-scheduler
sudo curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/cloud-controller-manager" -o kubebuilder/bin/cloud-controller-manager
sudo chmod 755 kubebuilder/bin/kube-controller-manager kubebuilder/bin/kube-scheduler kubebuilder/bin/cloud-controller-manager
```

---

## 5) Generate certificates & tokens
> `/tmp` is ephemeral → this block is idempotent and can be rerun.
```bash
# SA keypair
[ -s /tmp/sa.key ] || openssl genrsa -out /tmp/sa.key 2048
[ -s /tmp/sa.pub ] || openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub

# static bootstrap token for kubectl
[ -s /tmp/token.csv ] || {
  TOKEN="1234567890"
  echo "$TOKEN,admin,admin,system:masters" | sudo tee /tmp/token.csv >/dev/null
  sudo chmod 600 /tmp/token.csv
}

# CA for kubelet (self-signed)
[ -s /tmp/ca.key ] || openssl genrsa -out /tmp/ca.key 2048
[ -s /tmp/ca.crt ] || openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
sudo cp /tmp/ca.crt /var/lib/kubelet/ca.crt
sudo cp /tmp/ca.crt /var/lib/kubelet/pki/ca.crt
```

---

## 6) Configure kubectl (local admin context)
```bash
sudo kubebuilder/bin/kubectl config set-credentials test-user --token=1234567890
sudo kubebuilder/bin/kubectl config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
sudo kubebuilder/bin/kubectl config set-context test-context --cluster=test-env --user=test-user --namespace=default
sudo kubebuilder/bin/kubectl config use-context test-context
```

---

## 7) Configure CNI (bridge + host-local)
Create `/etc/cni/net.d/10-mynet.conf`:
```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.22.0.0/16",
    "routes": [{ "dst": "0.0.0.0/0" }]
  }
}
```
Quick checks:
```bash
test -s /etc/cni/net.d/10-mynet.conf && echo "CNI config OK" || echo "CNI config MISSING"
ls /opt/cni/bin | grep -E '(^|-)bridge$|(^|-)host-local$' >/dev/null && echo "CNI plugins OK" || echo "CNI plugins MISSING"
```

---

## 8) Configure containerd
Create `/etc/containerd/config.toml`:
```toml
version = 3

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "native"
  disable_snapshot_annotations = true

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false
```

---

## 9) Configure kubelet
Create `/var/lib/kubelet/config.yaml`:
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubelet/ca.crt"
authorization:
  mode: AlwaysAllow
clusterDomain: "cluster.local"
clusterDNS:
  - "10.0.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
failSwapOn: false
seccompDefault: true
serverTLSBootstrap: false
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
staticPodPath: "/etc/kubernetes/manifests"
```

---

## 10) Start components (strict order)

> **Important:** make `$HOST_IP` visible inside `sudo`.
```bash
HOST_IP=$(hostname -I | awk '{print $1}'); echo "HOST_IP=$HOST_IP"
export KUBECONFIG="$HOME/.kube/config"
export PATH=$PATH:/opt/cni/bin:kubebuilder/bin
```

### 10.1 etcd
```bash
sudo env HOST_IP=$HOST_IP bash -c 'kubebuilder/bin/etcd \
  --advertise-client-urls http://$HOST_IP:2379 \
  --listen-client-urls http://0.0.0.0:2379 \
  --data-dir ./etcd \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-cluster default=http://$HOST_IP:2380 \
  --initial-advertise-peer-urls http://$HOST_IP:2380 \
  --initial-cluster-state new \
  --initial-cluster-token test-token >> /var/log/kubernetes/etcd.log 2>&1 &'
ss -lntp | grep -E '(:2379|:2380)' || true
curlr http://127.0.0.1:2379/health; echo
```

### 10.2 kube‑apiserver
```bash
sudo env HOST_IP=$HOST_IP bash -c 'kubebuilder/bin/kube-apiserver \
  --etcd-servers=http://$HOST_IP:2379 \
  --service-cluster-ip-range=10.0.0.0/24 \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --advertise-address=$HOST_IP \
  --authorization-mode=AlwaysAllow \
  --token-auth-file=/tmp/token.csv \
  --enable-priority-and-fairness=false \
  --allow-privileged=true \
  --profiling=false \
  --storage-backend=etcd3 \
  --storage-media-type=application/json \
  --v=0 \
  --cloud-provider=external \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --service-account-key-file=/tmp/sa.pub \
  --service-account-signing-key-file=/tmp/sa.key \
  >> /var/log/kubernetes/kube-apiserver.log 2>&1 &'
ss -lntp | grep 6443 || true
curl -sk https://127.0.0.1:6443/readyz?verbose | head
```

### 10.3 containerd
```bash
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml \
  >> /var/log/kubernetes/containerd.log 2>&1 &
```

### 10.4 kube‑scheduler
```bash
sudo bash -c 'kubebuilder/bin/kube-scheduler \
  --kubeconfig=/root/.kube/config \
  --leader-elect=false \
  --v=2 \
  --bind-address=0.0.0.0 \
  >> /var/log/kubernetes/kube-scheduler.log 2>&1 &'
```

### 10.5 Prep objects for kubelet
```bash
# kubeconfig for kubelet
sudo cp /root/.kube/config /var/lib/kubelet/kubeconfig
# convenience copies
cp -f /tmp/sa.pub /tmp/ca.crt
# core objects in default
sudo kubebuilder/bin/kubectl create sa default || true
sudo kubebuilder/bin/kubectl -n default create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt || true
```

### 10.6 kubelet
```bash
sudo env HOST_IP=$HOST_IP bash -c 'PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --config=/var/lib/kubelet/config.yaml \
  --root-dir=/var/lib/kubelet \
  --cert-dir=/var/lib/kubelet/pki \
  --hostname-override=$(hostname) \
  --pod-infra-container-image=registry.k8s.io/pause:3.10 \
  --node-ip=$HOST_IP \
  --cloud-provider=external \
  --cgroup-driver=cgroupfs \
  --max-pods=4 \
  --v=1 >> /var/log/kubernetes/kubelet.log 2>&1 &'
```

### 10.7 label node (master)
```bash
NODE_NAME=$(hostname)
sudo kubebuilder/bin/kubectl label node "$NODE_NAME" node-role.kubernetes.io/master="" --overwrite
```

### 10.8 kube‑controller‑manager
```bash
sudo bash -c 'PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kube-controller-manager \
  --kubeconfig=/var/lib/kubelet/kubeconfig \
  --leader-elect=false \
  --cloud-provider=external \
  --service-cluster-ip-range=10.0.0.0/24 \
  --cluster-name=kubernetes \
  --root-ca-file=/var/lib/kubelet/ca.crt \
  --service-account-private-key-file=/tmp/sa.key \
  --use-service-account-credentials=true \
  --v=2 >> /var/log/kubernetes/kube-controller-manager.log 2>&1 &'
```

> **About `--cloud-provider=external`:** Kubernetes adds taint
> `node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule` until a Cloud Controller Manager (CCM) runs. If you **don’t** start CCM in this lab, remove the taint:
```bash
sudo kubebuilder/bin/kubectl taint nodes $(hostname) node.cloudprovider.kubernetes.io/uninitialized- || true
```

---

## 11) Verify
```bash
sudo kubebuilder/bin/kubectl get nodes -o wide
sudo kubebuilder/bin/kubectl get --raw='/readyz?verbose' | head -n 20
# Deprecated but ok for lab
sudo kubebuilder/bin/kubectl get componentstatuses || true

# Test workload
sudo kubebuilder/bin/kubectl create deploy demo --image=nginx || true
sudo kubebuilder/bin/kubectl rollout status deploy/demo --timeout=2m
sudo kubebuilder/bin/kubectl get pods -o wide
sudo kubebuilder/bin/kubectl get all -A
```
**Expected:** node `Ready`, `demo` pod `Running`, PodIP from `10.22.0.0/16`.

> No kube-proxy/CoreDNS in this lab. Use `port-forward` to test:
```bash
sudo kubebuilder/bin/kubectl port-forward deploy/demo 8080:80 &
curl -s http://127.0.0.1:8080 | head
```

---

## 12) Quick restart after Codespaces stop
Save as `hack/restart-minicontrolplane.sh` and run from repo root:
```bash
#!/usr/bin/env bash
set -euo pipefail
HOST_IP=$(hostname -I | awk '{print $1}'); echo "HOST_IP=$HOST_IP"
export KUBECONFIG="$HOME/.kube/config"
export PATH=$PATH:/opt/cni/bin:kubebuilder/bin

# /tmp artifacts
[ -s /tmp/token.csv ] || { TOKEN="1234567890"; echo "$TOKEN,admin,admin,system:masters" | sudo tee /tmp/token.csv >/dev/null; sudo chmod 600 /tmp/token.csv; }
[ -s /tmp/sa.key ] || openssl genrsa -out /tmp/sa.key 2048
[ -s /tmp/sa.pub ] || openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub
[ -s /tmp/ca.crt ] || sudo cp /var/lib/kubelet/ca.crt /tmp/ca.crt

# etcd
sudo env HOST_IP=$HOST_IP bash -c 'kubebuilder/bin/etcd --advertise-client-urls http://$HOST_IP:2379 --listen-client-urls http://0.0.0.0:2379 --data-dir ./etcd --listen-peer-urls http://0.0.0.0:2380 --initial-cluster default=http://$HOST_IP:2380 --initial-advertise-peer-urls http://$HOST_IP:2380 --initial-cluster-state new --initial-cluster-token test-token >> /var/log/kubernetes/etcd.log 2>&1 &'

# apiserver
sudo env HOST_IP=$HOST_IP bash -c 'kubebuilder/bin/kube-apiserver --etcd-servers=http://$HOST_IP:2379 --service-cluster-ip-range=10.0.0.0/24 --bind-address=0.0.0.0 --secure-port=6443 --advertise-address=$HOST_IP --authorization-mode=AlwaysAllow --token-auth-file=/tmp/token.csv --enable-priority-and-fairness=false --allow-privileged=true --profiling=false --storage-backend=etcd3 --storage-media-type=application/json --v=0 --cloud-provider=external --service-account-issuer=https://kubernetes.default.svc.cluster.local --service-account-key-file=/tmp/sa.pub --service-account-signing-key-file=/tmp/sa.key >> /var/log/kubernetes/kube-apiserver.log 2>&1 &'

# containerd
sudo PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml >> /var/log/kubernetes/containerd.log 2>&1 &

# scheduler
sudo bash -c 'kubebuilder/bin/kube-scheduler --kubeconfig=/root/.kube/config --leader-elect=false --v=2 --bind-address=0.0.0.0 >> /var/log/kubernetes/kube-scheduler.log 2>&1 &'

# kubelet
sudo env HOST_IP=$HOST_IP bash -c 'PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kubelet --kubeconfig=/var/lib/kubelet/kubeconfig --config=/var/lib/kubelet/config.yaml --root-dir=/var/lib/kubelet --cert-dir=/var/lib/kubelet/pki --hostname-override=$(hostname) --pod-infra-container-image=registry.k8s.io/pause:3.10 --node-ip=$HOST_IP --cloud-provider=external --cgroup-driver=cgroupfs --max-pods=4 --v=1 >> /var/log/kubernetes/kubelet.log 2>&1 &'

# controller-manager
sudo bash -c 'PATH=$PATH:/opt/cni/bin:/usr/sbin kubebuilder/bin/kube-controller-manager --kubeconfig=/var/lib/kubelet/kubeconfig --leader-elect=false --cloud-provider=external --service-cluster-ip-range=10.0.0.0/24 --cluster-name=kubernetes --root-ca-file=/var/lib/kubelet/ca.crt --service-account-private-key-file=/tmp/sa.key --use-service-account-credentials=true --v=2 >> /var/log/kubernetes/kube-controller-manager.log 2>&1 &'

# remove taint if CCM is not running
sudo kubebuilder/bin/kubectl taint nodes $(hostname) node.cloudprovider.kubernetes.io/uninitialized- || true

sudo kubebuilder/bin/kubectl get nodes -o wide
```

---

## Troubleshooting quick hits
- **etcd doesn’t start, log shows empty host** → you forgot to pass `HOST_IP` into `sudo`. Use `sudo env HOST_IP=$HOST_IP bash -c '…'`.
- **apiserver 6443 not listening** → check etcd health and the same `HOST_IP` issue.
- **kubelet dies: CRI unavailable** → ensure containerd is started; socket at `/run/containerd/containerd.sock`.
- **Pods Pending: taint** `node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule` → run CCM or remove taint.
- **Pods ContainerCreating for long time** → first image pull or CNI. Check `/var/log/kubernetes/{kubelet.log,containerd.log}` for `cni`/`image`.
- **After Codespaces stop** → rerun step **12** (restart script) to restore `/tmp` & processes.

---

## Optional next steps
- **Cloud Controller Manager (CCM):** run your provider’s CCM to lift the `uninitialized` taint automatically.
- **kube‑proxy & CoreDNS:** to enable ClusterIP routing and DNS inside pods.

---

## Security reminders
- Static token & `AlwaysAllow` are for labs only.
- Self‑signed CA & anonymous auth enabled in kubelet config — never ship to prod.

