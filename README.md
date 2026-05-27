# Microservice Infrastructure Benchmark

Empirical benchmark of microservice frameworks across JVM, GraalVM Native Image, and Rust in containerized Kubernetes
environments (k3s).

---

## Frameworks Benchmarked

| Framework                | Runtime                         | Type     |
|--------------------------|---------------------------------|----------|
| Spring Boot              | JVM                             | Blocking |
| Spring WebFlux (Reactor) | JVM                             | Reactive |
| Quarkus                  | JVM                             | Blocking |
| Quarkus                  | GraalVM Native                  | Blocking |
| Quarkus                  | GraalVM Native Micro            | Blocking |
| Quarkus                  | GraalVM Native Micro Compressed | Blocking |
| Quarkus                  | GraalVM Distroless              | Blocking |
| Quarkus Reactive         | JVM                             | Reactive |
| Quarkus Reactive         | GraalVM Native                  | Reactive |
| Quarkus Reactive         | GraalVM Native Micro            | Reactive |
| Quarkus Reactive         | GraalVM Native Micro Compressed | Reactive |
| Quarkus Reactive         | GraalVM Distroless              | Reactive |
| Ktor                     | JVM                             | Blocking |
| Actix-Web                | Rust                            | Async    |

---

## Repository Structure

```
microservice-infra-benchmark/
│
├── cluster/
│   ├── 00-namespace.yaml               # perf-test namespace definition
│   └── 00-kind-cluster-config.yaml     # cluster config (k3s/kind)
│
├── infra/
│   ├── 01-redis.yaml                   # Redis deployment + PVC
│   ├── 02-postgresql.yaml              # PostgreSQL + init scripts + PVC
│   ├── 03-kafka.yaml                   # Kafka in KRaft mode (no Zookeeper)
│   ├── 04-secret.yaml                  # DB credentials secret
│   ├── 07-ingress.yaml                 # NGINX ingress config
│   ├── kafka-ui.yaml                   # Kafka UI (NodePort 30880)
│   └── nginx-config.yaml               # NGINX performance tuning
│
├── configmaps/
│   ├── 04-configmap-spring.yaml
│   ├── 04-configmap-spring-reactor.yaml
│   ├── 04-configmap-quarkus.yaml
│   ├── 04-configmap-quarkus-reactive.yaml
│   ├── 04-configmap-ktor.yaml
│   └── 04-configmap-actix.yaml
│
├── frameworks/
│   ├── spring/                         # Spring Boot deployment + service
│   ├── spring-reactor/                 # Spring WebFlux deployment + service
│   ├── ktor/                           # Ktor deployment + service
│   ├── rust/                           # Actix-Web deployment + service
│   ├── quarkus/
│   │   ├── jvm/                        # Quarkus JVM
│   │   └── native/                     # Quarkus Native variants
│   └── quarkus-reactive/
│       ├── jvm/                        # Quarkus Reactive JVM
│       └── native/                     # Quarkus Reactive Native variants
│
├── monitoring/
│   ├── 08-prometheus.yaml              # Prometheus + RBAC
│   └── 09-grafana.yaml                 # Grafana + dashboards
│
└── scripts/
    ├── setup-cluster.sh                # Full cluster setup script
    ├── S1_scale_test.sh                # Scale up/down test (bash)
    ├── S1_scale_test.ps1               # Scale up/down test (PowerShell)
    ├── S2_startup_measure.sh           # Startup time measurement (bash)
    └── S2_startup_measure.ps1          # Startup time measurement (PowerShell)
```

---

## Infrastructure Overview

| Component     | Image                   | Port                  | Purpose                      |
|---------------|-------------------------|-----------------------|------------------------------|
| PostgreSQL    | postgres:15-alpine      | 5432                  | Primary database             |
| Redis         | redis:7-alpine          | 6379                  | Caching                      |
| Kafka         | apache/kafka:3.7.0      | 9092                  | Event streaming (KRaft mode) |
| Prometheus    | prom/prometheus:v2.48.0 | 9090                  | Metrics collection           |
| Grafana       | grafana/grafana:10.2.0  | 3000 (NodePort 30300) | Metrics visualization        |
| Kafka UI      | provectuslabs/kafka-ui  | 8080 (NodePort 30880) | Kafka management             |
| NGINX Ingress | —                       | 80/443                | Routing to frameworks        |

---

## Ingress Routing

All frameworks are accessible via NGINX ingress:

| Path              | Service                    |
|-------------------|----------------------------|
| `/spring`         | spring-perf:8080           |
| `/actix`          | actix-perf:8080            |
| `/spring-reactor` | spring-reactor-perf:8080   |
| `/`               | spring-perf:8080 (default) |

---

## Prerequisites

- Fedora Linux (or any Linux distro)
- k3s installed
- `kubectl` configured
- Container images pushed to `ghcr.io/matejsaric32/`
- At least 8GB RAM recommended

---

## Deploy — Step by Step

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

Set up kubeconfig:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
echo "export KUBECONFIG=~/.kube/config" >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
kubectl get nodes
```

### 2. Run the Setup Script

```bash
sudo bash setup-cluster.sh
```

This will automatically deploy everything in the correct order.

---

### Manual Deploy (step by step)

If you prefer to deploy manually or the script fails:

```bash
# 1. Namespace
kubectl apply -f cluster/00-namespace.yaml
sleep 3

# 2. Secrets first
kubectl apply -f infra/04-secret.yaml -n perf-test

# 3. Infrastructure
kubectl apply -f infra/01-redis.yaml -n perf-test
kubectl apply -f infra/02-postgresql.yaml -n perf-test
kubectl apply -f infra/03-kafka.yaml -n perf-test

# 4. ConfigMaps
kubectl apply -f configmaps/ -n perf-test

# 5. Wait for PostgreSQL to be ready before deploying apps
kubectl wait --for=condition=ready pod -l app=postgresql -n perf-test --timeout=120s

# 6. Monitoring
kubectl apply -f monitoring/ -n perf-test

# 7. Ingress
kubectl apply -f infra/07-ingress.yaml -n perf-test
kubectl apply -f infra/kafka-ui.yaml -n perf-test

# 8. Deploy frameworks
kubectl apply -f frameworks/spring/ -n perf-test
kubectl apply -f frameworks/spring-reactor/ -n perf-test
kubectl apply -f frameworks/ktor/ -n perf-test
kubectl apply -f frameworks/rust/ -n perf-test
kubectl apply -f frameworks/quarkus/jvm/ -n perf-test
kubectl apply -f frameworks/quarkus/native/ -n perf-test
kubectl apply -f frameworks/quarkus-reactive/jvm/ -n perf-test
kubectl apply -f frameworks/quarkus-reactive/native/ -n perf-test
```

Watch everything come up:

```bash
kubectl get pods -n perf-test -w
```

---

## Running Benchmark Scripts

### Scale Test

Tests how fast a framework scales up and down:

```bash
# bash
bash scripts/S1_scale_test.sh <framework-name> <min-replicas> <max-replicas>

# example
bash scripts/S1_scale_test.sh quarkus-reactive-perf-distroless 1 10

# PowerShell
.\scripts\S1_scale_test.ps1 -Framework quarkus-perf-jvm -Runs 10
```

### Startup Time Measurement

Measures how long a pod takes from scheduled to ready:

```bash
# bash
bash scripts/S2_startup_measure.sh <framework-name>

# PowerShell
.\scripts\S2_startup_measure.ps1 -Framework quarkus-perf-jvm -Runs 10
```

Available framework names:

- `spring-perf`
- `spring-reactor-perf`
- `actix-perf`
- `ktor-perf`
- `quarkus-perf-jvm`
- `quarkus-perf-native`
- `quarkus-perf-native-micro`
- `quarkus-perf-native-micro-compressed`
- `quarkus-perf-distroless`
- `quarkus-reactive-perf-jvm`
- `quarkus-reactive-perf-native`
- `quarkus-reactive-perf-native-micro`
- `quarkus-reactive-perf-native-micro-compressed`
- `quarkus-reactive-perf-distroless`

---

## Common Commands

### Cluster Status

```bash
# All pods in perf-test
kubectl get pods -n perf-test

# All pods with node and IP info
kubectl get pods -n perf-test -o wide

# All resources
kubectl get all -n perf-test

# Node status
kubectl get nodes -o wide
```

### Logs

```bash
# Logs for a specific pod
kubectl logs -n perf-test <pod-name>

# Logs for a crashed/restarted pod
kubectl logs -n perf-test <pod-name> --previous

# Follow logs live
kubectl logs -n perf-test -l app=ktor-perf --follow

# Last 100 lines
kubectl logs -n perf-test <pod-name> --tail=100
```

### Deployments

```bash
# Restart a deployment
kubectl rollout restart deployment <name> -n perf-test

# Scale a deployment
kubectl scale deployment <name> -n perf-test --replicas=3

# Scale to 0 (stop without deleting)
kubectl scale deployment <name> -n perf-test --replicas=0

# Check rollout status
kubectl rollout status deployment <name> -n perf-test
```

### ConfigMaps

```bash
# List all configmaps
kubectl get configmaps -n perf-test

# View a configmap
kubectl get configmap ktor-perf-config -n perf-test -o yaml

# Edit a configmap directly
kubectl edit configmap ktor-perf-config -n perf-test

# Patch a single value
kubectl patch configmap quarkus-reactive-perf-config -n perf-test \
  --type merge \
  -p '{"data":{"SOME_KEY":"some-value"}}'
```

### Describe & Events

```bash
# Describe a pod (shows events, probe status, etc.)
kubectl describe pod <pod-name> -n perf-test

# Describe a deployment
kubectl describe deployment <name> -n perf-test
```

### Delete & Redeploy

```bash
# Delete and redeploy a single framework
kubectl delete -f frameworks/ktor/ktor-deployment.yaml -n perf-test
kubectl apply -f frameworks/ktor/ktor-deployment.yaml -n perf-test

# Wipe entire namespace and start fresh
kubectl delete namespace perf-test
kubectl apply -f cluster/00-namespace.yaml
# then redeploy everything
```

---

## Troubleshooting

### Pod stuck in CrashLoopBackOff

```bash
# Check logs from the crashed container
kubectl logs -n perf-test <pod-name> --previous

# Describe the pod to see events
kubectl describe pod <pod-name> -n perf-test
```

Common causes:

- Database not ready yet → wait for PostgreSQL and retry
- Wrong config key → check the configmap matches what the app expects
- Missing config value → add the missing key to the configmap and restart

### Pod stuck in Terminating

```bash
kubectl delete pod <pod-name> -n perf-test --force --grace-period=0
```

### Namespace stuck in Terminating

```bash
kubectl proxy &
curl -X PUT http://localhost:8001/api/v1/namespaces/perf-test/finalize \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Namespace",
    "metadata": {"name": "perf-test"},
    "spec": {"finalizers": []}
  }'
kill %1
```

### Readiness probe failing with 404

The probe path is wrong. Check the framework's health endpoint:

| Framework   | Health Path        |
|-------------|--------------------|
| Ktor        | `/health`          |
| Spring Boot | `/actuator/health` |
| Quarkus     | `/q/health/ready`  |
| Actix       | `/health`          |

### Connection refused on startup

The app can't reach the database or Kafka. Make sure infra pods are running:

```bash
kubectl get pods -n perf-test | grep -E "postgres|redis|kafka"
```

Wait for them to be ready before deploying app pods:

```bash
kubectl wait --for=condition=ready pod -l app=postgresql -n perf-test --timeout=120s
kubectl wait --for=condition=ready pod -l app=kafka -n perf-test --timeout=120s
```

### Native micro/distroless images crashing immediately

These images are compiled with aggressive CPU optimizations. Check if your CPU supports the required instruction sets:

```bash
lscpu | grep -i avx
```

If not supported, scale those deployments to 0:

```bash
kubectl scale deployment quarkus-reactive-perf-distroless -n perf-test --replicas=0
kubectl scale deployment quarkus-reactive-perf-native-micro -n perf-test --replicas=0
kubectl scale deployment quarkus-reactive-perf-native-micro-compressed -n perf-test --replicas=0
```

### k3s not starting

```bash
# Check service status
sudo systemctl status k3s

# Check logs
sudo journalctl -u k3s -n 50

# Restart k3s
sudo systemctl restart k3s

# Full reinstall if broken
sudo /usr/local/bin/k3s-uninstall.sh
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s
curl -sfL https://get.k3s.io | sh -
```

### kubectl connection refused

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# or
export KUBECONFIG=~/.kube/config

kubectl get nodes
```

---

## Monitoring

**Grafana** is available at `http://<node-ip>:30300`

- Default login: anonymous (admin access enabled)
- Pre-loaded dashboard: `Perf Test - Memory & CPU Metrics`
- Metrics: container memory (working set, RSS, cache) and CPU usage

**Prometheus** scrapes metrics every 5 seconds from:

- All pods with `prometheus.io/scrape: "true"` annotation
- cAdvisor for container CPU/memory

**Kafka UI** is available at `http://<node-ip>:30880`

---

## Connect to IntelliJ IDEA

1. Install the **Kubernetes plugin** in IntelliJ: `File → Settings → Plugins → Kubernetes`
2. Copy kubeconfig to your machine:

```bash
scp user@<node-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

3. Edit the file and replace `127.0.0.1` with your node's actual IP
4. IntelliJ will auto-detect `~/.kube/config` and show your cluster in the Kubernetes tab