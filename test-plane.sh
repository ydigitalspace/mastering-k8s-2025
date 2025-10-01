#!/usr/bin/env bash
# ============================================================
#  k8s-quick-check.sh — швидкий тестовий набір перевірок
#  Мета: одним запуском оцінити стан мінімального control plane
#  УВАГА: команди розраховані на середовище з правами sudo
# ============================================================

set -euo pipefail

# --- Налаштування за замовчуванням ---
# KUBECONFIG для локального кластеру (у нашому лабі)
export KUBECONFIG=${KUBECONFIG:-/root/.kube/config}

# --- Дрібні утиліти ---
# Тихий/стійкий curl для локальних перевірок
curlr() { curl -sS --retry 2 --retry-connrefused --max-time 4 "$@"; }

# Гарний розділювач для читабельності
hr() { printf "\n%s\n" "------------------------------------------------------------"; }

# --- Перевірка портів/сокетів control-plane ---
hr; echo "== Перевірка портів та сокетів =="
NEED_FIX=0

# Перевірка, чи слухає потрібний порт (tcp)
check_port() {
  local port="$1" name="$2"
  if ss -lntp | grep -q ":${port}\b"; then
    echo "✅ ${name} порт ${port} слухає"
  else
    echo "❌ ${name} порт ${port} НЕ слухає"
    NEED_FIX=1
  fi
}

check_port 2379 "etcd (client)"
check_port 2380 "etcd (peer)"
check_port 6443 "kube-apiserver"
check_port 10250 "kubelet"

# Сокет containerd (CRI)
if test -S /run/containerd/containerd.sock; then
  echo "✅ containerd socket OK: /run/containerd/containerd.sock"
else
  echo "❌ containerd socket ВІДСУТНІЙ"
  NEED_FIX=1
fi

# --- etcd /health ---
hr; echo "== etcd /health =="
if curlr http://127.0.0.1:2379/health >/dev/null; then
  curlr http://127.0.0.1:2379/health; echo
else
  echo "❌ etcd /health недоступний"
  NEED_FIX=1
fi

# --- kube-apiserver /readyz ---
hr; echo "== kube-apiserver /readyz (401 без токена — це нормально) =="
if curl -sk --max-time 4 https://127.0.0.1:6443/readyz?verbose >/dev/null; then
  curl -sk https://127.0.0.1:6443/readyz?verbose | head -n 20
else
  echo "❌ kube-apiserver /readyz не відповідає"
  NEED_FIX=1
fi

# --- Статус ноди ---
hr; echo "== Статус ноди =="
if sudo kubebuilder/bin/kubectl get nodes -o wide; then
  : # ок
else
  echo "❌ kubectl не може отримати список нод"
  NEED_FIX=1
fi

# --- Список подів у всіх просторах імен ---
hr; echo "== Поди у всіх namespace (коротко) =="
sudo kubebuilder/bin/kubectl get pods -A -o wide || true

# --- Останні події для швидкої діагностики ---
hr; echo "== Останні події (20 шт.) =="
sudo kubebuilder/bin/kubectl get events -A --sort-by=.lastTimestamp | tail -n 20 || true

# --- Перевірка тестового деплойменту demo (якщо існує) ---
hr; echo "== Перевірка demo (якщо створений) =="
if sudo kubebuilder/bin/kubectl get deploy demo >/dev/null 2>&1; then
  sudo kubebuilder/bin/kubectl rollout status deploy/demo --timeout=30s || true
  sudo kubebuilder/bin/kubectl get deploy/demo pods -o wide || sudo kubebuilder/bin/kubectl get pods -l app=demo -o wide || true
else
  echo "ℹ️  Деплоймент demo відсутній — пропускаємо цю перевірку"
fi

# --- Результат та підказка ---
hr; echo "== Підсумок =="
if [[ $NEED_FIX -eq 0 ]]; then
  echo "✅ Контроль-плейн виглядає ЗДОРОВИМ. Перезапуск скрипта не потрібен."
else
  cat <<'EOF'
❌ ВИЯВЛЕНО ПРОБЛЕМИ.
Рекомендації:
  1) Перезапусти міні-кластер:
       ./restart-minicontrolplane.sh
  2) Переглянь логи компонентів:
       sudo tail -n 60 /var/log/kubernetes/etcd.log
       sudo tail -n 60 /var/log/kubernetes/kube-apiserver.log
       sudo tail -n 60 /var/log/kubernetes/containerd.log
       sudo tail -n 60 /var/log/kubernetes/kubelet.log
  3) Повтори цей тест знову.
EOF
  exit 1
fi
