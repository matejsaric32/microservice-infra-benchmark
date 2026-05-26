#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
NAMESPACE="perf-test"
GHCR="ghcr.io/matejsaric32"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="kubectl"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ─────────────────────────────────────────────
# All GHCR images
# ─────────────────────────────────────────────
declare -a IMAGES=(
  "spring-perf:latest"
  "spring-reactive-perf:latest"
  "actix-perf:latest"
  "ktor-perf:latest"
  "quarkus-perf-jvm:latest"
  "quarkus-perf-native:latest"
  "quarkus-perf-native-micro:latest"
  "quarkus-perf-native-micro-compressed:latest"
  "quarkus-perf-distroless:latest"
  "quarkus-reactive-perf-jvm:latest"
  "quarkus-reactive-perf-native:latest"
  "quarkus-reactive-perf-native-micro:latest"
  "quarkus-reactive-perf-native-micro-compressed:latest"
  "quarkus-reactive-perf-distroless:latest"
)

# ─────────────────────────────────────────────
# STEP 1 — Pre-flight checks
# ─────────────────────────────────────────────
preflight() {
  info "Running pre-flight checks..."

  # Check podman
  command -v podman &>/dev/null || error "'podman' not found. Install it: sudo dnf install -y podman"

  # Check curl (needed for k3s install)
  command -v curl &>/dev/null || error "'curl' not found. Install it: sudo dnf install -y curl"

  success "Pre-flight OK"
}

# ─────────────────────────────────────────────
# STEP 2 — Install k3s if missing, then start it
# ─────────────────────────────────────────────
setup_k3s() {
  info "Checking k3s..."

  if ! command -v k3s &>/dev/null; then
    info "k3s not found — installing..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
    success "k3s installed."
  else
    warn "k3s already installed — skipping install."
  fi

  if ! systemctl is-active --quiet k3s 2>/dev/null; then
    info "Starting k3s service..."
    systemctl start k3s
    sleep 10
  fi

  systemctl is-active --quiet k3s || error "k3s failed to start. Check: journalctl -u k3s -n 50"

  # Fix kubeconfig permissions and copy to user home
  # so kubectl works without sudo for the invoking user
  chmod 644 /etc/rancher/k3s/k3s.yaml

  mkdir -p "$REAL_HOME/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$REAL_HOME/.kube/config"
  chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube/config"
  chmod 600 "$REAL_HOME/.kube/config"

  # Also export for this script session
  export KUBECONFIG="$REAL_HOME/.kube/config"
  KUBECTL="kubectl"

  # Add KUBECONFIG to user's .bashrc if not already there
  BASHRC="$REAL_HOME/.bashrc"
  if ! grep -q "KUBECONFIG" "$BASHRC" 2>/dev/null; then
    echo 'export KUBECONFIG=~/.kube/config' >> "$BASHRC"
    info "Added KUBECONFIG export to $BASHRC"
  fi

  info "Waiting for node to become Ready..."
  $KUBECTL wait node --all --for=condition=Ready --timeout=120s
  success "k3s node is Ready."
}

# ─────────────────────────────────────────────
# STEP 3 — Install nginx ingress controller
# ─────────────────────────────────────────────
install_ingress() {
  info "Installing nginx ingress controller..."

  if $KUBECTL get ns ingress-nginx &>/dev/null 2>&1; then
    warn "ingress-nginx already exists — skipping."
    return
  fi

  $KUBECTL apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml

  # Wait for the deployment to be created before waiting for pods
  info "Waiting for ingress deployment to be created..."
  local retries=0
  until $KUBECTL get deployment ingress-nginx-controller -n ingress-nginx &>/dev/null 2>&1; do
    retries=$((retries + 1))
    [[ $retries -gt 30 ]] && error "ingress-nginx deployment never appeared. Check: kubectl get all -n ingress-nginx"
    sleep 5
  done

  info "Waiting for ingress pods to be ready (up to 3 min)..."
  $KUBECTL wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s

  success "Nginx ingress ready."
}

# ─────────────────────────────────────────────
# STEP 4 — Pull images with podman (as real user)
#
# Podman is rootless — pulling as root means
# images go into root's store and are invisible
# in Podman Desktop. We pull as the real user
# so images show up in Podman Desktop normally.
# ─────────────────────────────────────────────
pull_images() {
  info "Pulling ${#IMAGES[@]} images from GHCR with podman (as user '${REAL_USER}')..."
  for img in "${IMAGES[@]}"; do
    full="${GHCR}/${img}"
    info "  Pulling ${full}..."
    # Run podman as the real user, not root
    sudo -u "$REAL_USER" podman pull "$full" || error "Failed to pull ${full}"
  done
  success "All images pulled — visible in Podman Desktop."
}

# ─────────────────────────────────────────────
# STEP 5 — Import images into k3s containerd
#
# k3s uses its own containerd — completely
# separate from podman's image store.
# We save from the real user's podman store
# and pipe into k3s ctr (which needs root).
# ─────────────────────────────────────────────
import_images_k3s() {
  info "Importing images into k3s containerd (podman save | k3s ctr images import)..."
  for img in "${IMAGES[@]}"; do
    full="${GHCR}/${img}"
    info "  Importing ${full}..."
    # Save from user's podman store, import into root's k3s containerd
    sudo -u "$REAL_USER" podman save "$full" | k3s ctr images import -
  done
  success "All images imported into k3s containerd."
}

# ─────────────────────────────────────────────
# STEP 6 — Patch deployment YAMLs
#   localhost/<name>  →  ghcr.io/matejsaric32/<name>
#   imagePullPolicy: Never  →  IfNotPresent
# ─────────────────────────────────────────────
declare -A IMAGE_MAP=(
  ["spring-perf"]="spring-perf"
  ["spring-reactive-perf"]="spring-reactive-perf"
  ["actix-perf"]="actix-perf"
  ["ktor-perf"]="ktor-perf"
  ["quarkus-perf-jvm"]="quarkus-perf-jvm"
  ["quarkus-perf-native"]="quarkus-perf-native"
  ["quarkus-perf-native-micro"]="quarkus-perf-native-micro"
  ["quarkus-perf-native-micro-compressed"]="quarkus-perf-native-micro-compressed"
  ["quarkus-perf-distroless"]="quarkus-perf-distroless"
  ["quarkus-reactive-perf-jvm"]="quarkus-reactive-perf-jvm"
  ["quarkus-reactive-perf-native"]="quarkus-reactive-perf-native"
  ["quarkus-reactive-perf-native-micro"]="quarkus-reactive-perf-native-micro"
  ["quarkus-reactive-perf-native-micro-compressed"]="quarkus-reactive-perf-native-micro-compressed"
  ["quarkus-reactive-perf-distroless"]="quarkus-reactive-perf-distroless"
)

patch_deployments() {
  info "Patching deployment YAMLs (localhost/ → ${GHCR}/ , Never → IfNotPresent)..."

  while IFS= read -r -d '' file; do
    for local_name in "${!IMAGE_MAP[@]}"; do
      ghcr_name="${IMAGE_MAP[$local_name]}"
      if grep -q "localhost/${local_name}" "$file"; then
        sed -i "s|localhost/${local_name}|${GHCR}/${ghcr_name}|g" "$file"
        sed -i "s|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|g" "$file"
        info "  Patched: $(basename "$file")"
      fi
    done
  done < <(find "$ROOT_DIR/frameworks" -name "*.yaml" -print0)

  success "Deployment YAMLs patched."
}

# ─────────────────────────────────────────────
# STEP 7 — Apply namespace + infra manifests
# ─────────────────────────────────────────────
apply_infra() {
  info "Applying namespace..."
  $KUBECTL apply -f "$ROOT_DIR/cluster/00-namespace.yaml"

  info "Applying secrets..."
  $KUBECTL apply -f "$ROOT_DIR/infra/04-secret.yaml"

  info "Applying Redis..."
  $KUBECTL apply -f "$ROOT_DIR/infra/01-redis.yaml"

  info "Applying PostgreSQL..."
  $KUBECTL apply -f "$ROOT_DIR/infra/02-postgresql.yaml"

  info "Applying Kafka..."
  $KUBECTL apply -f "$ROOT_DIR/infra/03-kafka.yaml"

  info "Applying nginx configmap..."
  $KUBECTL apply -f "$ROOT_DIR/infra/nginx-config.yaml" || warn "nginx-config.yaml skipped"

  info "Applying ingress rules..."
  $KUBECTL apply -f "$ROOT_DIR/infra/07-ingress.yaml"

  info "Applying Kafka UI..."
  $KUBECTL apply -f "$ROOT_DIR/infra/kafka-ui.yaml"

  info "Applying monitoring (Prometheus + Grafana)..."
  $KUBECTL apply -f "$ROOT_DIR/monitoring/08-prometheus.yaml"
  $KUBECTL apply -f "$ROOT_DIR/monitoring/09-grafana.yaml"

  success "Infrastructure manifests applied."
}

# ─────────────────────────────────────────────
# STEP 8 — Apply configmaps
# ─────────────────────────────────────────────
apply_configmaps() {
  info "Applying configmaps..."
  for cm in "$ROOT_DIR"/configmaps/*.yaml; do
    $KUBECTL apply -f "$cm"
  done
  success "Configmaps applied."
}

# ─────────────────────────────────────────────
# STEP 9 — Wait for core infra pods
# ─────────────────────────────────────────────
wait_infra() {
  info "Waiting for PostgreSQL (up to 5 min)..."
  $KUBECTL wait --for=condition=ready pod -l app=postgresql -n "$NAMESPACE" --timeout=300s

  info "Waiting for Redis..."
  $KUBECTL wait --for=condition=ready pod -l app=redis -n "$NAMESPACE" --timeout=120s

  info "Waiting for Kafka (up to 5 min)..."
  $KUBECTL wait --for=condition=ready pod -l app=kafka -n "$NAMESPACE" --timeout=300s

  success "Core infra pods ready."
}

# ─────────────────────────────────────────────
# STEP 10 — Apply framework deployments
# ─────────────────────────────────────────────
apply_frameworks() {
  info "Applying framework services and deployments..."

  declare -a FRAMEWORK_FILES=(
    "frameworks/spring/spring-service.yaml"
    "frameworks/spring/spring-deployment.yaml"
    "frameworks/spring-reactor/spring-reactor-service.yaml"
    "frameworks/spring-reactor/spring-reactor-deployment.yaml"
    "frameworks/rust/actix-service.yaml"
    "frameworks/rust/actix-deployment.yaml"
    "frameworks/ktor/ktor-service.yaml"
    "frameworks/ktor/ktor-deployment.yaml"
    "frameworks/quarkus/jvm/quarkus-jvm-service.yaml"
    "frameworks/quarkus/jvm/quarkus-jvm-deployment.yaml"
    "frameworks/quarkus/native/quarkus-native-service.yaml"
    "frameworks/quarkus/native/quarkus-native-deployment.yaml"
    "frameworks/quarkus/native/quarkus-native-micro-deployment.yaml"
    "frameworks/quarkus/native/quarkus-native-micro-compressed-deployment.yaml"
    "frameworks/quarkus/native/quarkus-native-distroless-deployment.yaml"
    "frameworks/quarkus-reactive/jvm/quarkus-reactive-jvm-service.yaml"
    "frameworks/quarkus-reactive/jvm/quarkus-reactive-jvm-deployment.yaml"
    "frameworks/quarkus-reactive/native/quarkus-reactive-native-service.yaml"
    "frameworks/quarkus-reactive/native/quarkus-reactive-native-deployment.yaml"
    "frameworks/quarkus-reactive/native/quarkus-reactive-distroless-deployment.yaml"
    "frameworks/quarkus-reactive/native/quarkus-reactive-native-micro-deployment.yaml"
    "frameworks/quarkus-reactive/native/quarkus-reactive-native-micro-compressed-deployment.yaml"
  )

  for f in "${FRAMEWORK_FILES[@]}"; do
    path="$ROOT_DIR/$f"
    if [[ -f "$path" ]]; then
      $KUBECTL apply -f "$path"
    else
      warn "  Not found, skipping: $f"
    fi
  done

  success "Framework deployments applied."
}

# ─────────────────────────────────────────────
# STEP 11 — Summary
# ─────────────────────────────────────────────
print_summary() {
  NODE_IP=$(k3s kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")

  echo ""
  echo -e "${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Cluster setup complete!${NC}"
  echo -e "${CYAN}══════════════════════════════════════════${NC}"
  echo ""
  echo "  Node IP:   ${NODE_IP}"
  echo "  Grafana:   http://${NODE_IP}:30300"
  echo "  Kafka UI:  http://${NODE_IP}:30880"
  echo "  Ingress:   http://${NODE_IP}/spring  /actix  /spring-reactor"
  echo ""
  echo -e "${YELLOW}  NOTE: Open a new terminal or run:${NC}"
  echo "    source ~/.bashrc"
  echo "  so kubectl works without sudo for user '${REAL_USER}'"
  echo ""
  info "Pod status:"
  $KUBECTL get pods -n "$NAMESPACE"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
  # Resolve the real user early so all steps can use it
  REAL_USER="${SUDO_USER:-$USER}"
  REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

  if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo ./scripts/setup-cluster.sh"
  fi

  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════╗"
  echo "║  Microservice Benchmark — k3s on Fedora  ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${NC}"

  preflight
  setup_k3s
  install_ingress
  pull_images
  import_images_k3s
  patch_deployments
  apply_infra
  apply_configmaps
  wait_infra
  apply_frameworks
  print_summary
}

main "$@"