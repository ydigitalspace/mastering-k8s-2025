#!/usr/bin/env bash
set -euo pipefail

HOST_IP=$(hostname -I | awk '{print $1}'); echo "HOST_IP=$HOST_IP"
export KUBECONFIG=~/.kube/config

# /tmp артефакты
test -s /tmp/token.csv || { TOKEN="1234567890"; echo "$TOKEN,admin,admin,system:masters" | sudo tee /tmp/token.csv >/dev/null; sudo chmod 600 /tmp/token.csv; }
test -s /tmp/sa.key || openssl genrsa -out /tmp/sa.key 2048
test -s /tmp/sa.pub || openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub
test -s /tmp/ca.crt || sudo cp /var/lib/kubelet/ca.crt /tmp/ca.crt

# etcd
sudo env HOST_IP=$HOST_IP bash -c 'kubebuilder/bin/etcd \
  --advertise-client-urls http://$HOST_IP:2379 \
  --listen-client-urls http://0.0.0.0:2379 \
  --data-dir ./etcd \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-cluster default=http://$HOST_IP:2380 \
  --initial-advertise-peer-urls http://$HOST_IP:2380 \
  --initial-cluster-state new \
  --initial-cluster-token test-token >> /var/log/kubernetes/etcd.log 2>&1 &' 

# apiserver
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
  --service-account-signing-key-file=/tmp/sa.key >> /var/log/kubernetes/kube-apiserver.log 2>&1 &'

# containerd
sudo bash -c 'PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml >> /var/log/kubernetes/containerd.log 2>&1 &' || true

# scheduler
sudo bash -c 'kubebuilder/bin/kube-scheduler --kubeconfig=/root/.kube/config --leader-elect=false --v=2 --bind-address=0.0.0.0 >> /var/log/kubernetes/kube-scheduler.log 2>&1 &' || true

# kubelet
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

# controller-manager
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

# прибрати taint, якщо піднявся
sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config taint nodes $(hostname) node.cloudprovider.kubernetes.io/uninitialized- || true

# показати статус
sudo kubebuilder/bin/kubectl --kubeconfig=/root/.kube/config get nodes -o wide
