# Microservice Infrastructure Benchmark

Empirical benchmark of microservice frameworks across JVM, GraalVM Native Image, and Rust in containerized Kubernetes
environments (k3s).

> **Reproducibility companion.** This repository contains the complete cluster configuration, deployment manifests,
> and measurement scripts (Supplements S1–S3) for the paper *"Empirical Static and Infrastructure Evaluation of
> Microservice Frameworks Across JVM, GraalVM Native Image, and Rust in Containerized Environments"*. The Quick Start
> below reproduces the exact test environment used for all reported measurements.

---

## Quick Start (paper environment)

The reported measurements were collected on a **single bare-metal node** with the following configuration:

| Parameter          | Value                                              |
|--------------------|----------------------------------------------------|
| OS                 | Fedora Workstation 42 (cgroups v2)                 |
| Kubernetes         | K3s v1.35.5 (single node, embedded containerd)     |
| Container build    | Podman 5.7.0 (images pre-built, pushed to GHCR)    |
| CPU / RAM / Disk   | AMD Ryzen 9 9950X3D · 64 GB DDR5 · 2 TB NVMe SSD   |
| Resource profile   | Every framework pod: 1 GiB memory / 1 CPU limit    |
| JVM                | Amazon Corretto 21 (default ergonomics, no flags)  |
| GraalVM            | Mandrel 24.2.2.0-Final (default Serial GC)         |
| Rust               | 1.89.0                                             |

```bash
# 1. Install the pinned K3s version
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.35.5+k3s1" sh -

# 2. Configure kubectl
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config && export KUBECONFIG=~/.kube/config

# 3. Deploy everything (namespace, infra, configmaps, monitoring, ingress, frameworks)
sudo bash setup-cluster.sh

# 4. Verify — all pods Ready (readiness = deep health check incl. PostgreSQL + Kafka)
kubectl get pods -n perf-test

# 5. Reproduce the paper's measurements
bash scripts/S2_startup_measure.sh quarkus-perf-native        # startup (Table 2)
bash scripts/S1_scale_test.sh quarkus-perf-native 1 10        # scaling (Table 4)
k6 run -e FRAMEWORK=quarkus-native -e RPS=100 scripts/S6_load.js  # iso-load (Table 8)
```

To confirm the cgroup configuration on your node: `sudo crictl info | grep -i cgroup`
(the paper environment ran cgroups v2; memory metrics follow cgroups v2 accounting as exposed by cAdvisor).

**Measurement notes (as used in the paper):**

- All container images were **pre-pulled** to the node before startup/scaling measurements — reported times exclude
  image pull time.
- Readiness probes are **deep health checks**: Spring Boot Actuator, Quarkus SmallRye Health, and custom endpoints
  for Ktor and Actix Web, all verifying PostgreSQL and Kafka connectivity (see probe paths under Troubleshooting).
- Database connection pools are configured for **eager initialization** in every framework.
- No JVM heap or GC flags are set anywhere: JDK 21 container-aware ergonomics apply (Serial GC under the 1-CPU limit).

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
│   ├── spring/                         # Spring Boot deployment + service (incl. readiness probe)
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
    ├── S1_scale_test.sh                # Supplement S1 — scale up/down test (bash)
    ├── S1_scale_test.ps1               # Scale up/down test (PowerShell)
    ├── S2_startup_measure.sh           # Supplement S2 — startup time measurement (bash)
    ├── S2_startup_measure.ps1          # Startup time measurement (PowerShell)
    └── S6_load.js                      # Supplement S3 — k6 iso-load test (100 RPS)
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

All frameworks are accessible via NGINX ingress (paths used by the S6 iso-load test):

| Path                       | Service                           |
|----------------------------|-----------------------------------|
| `/spring`                  | spring-perf:8080                  |
| `/spring-reactor`          | spring-reactor-perf:8080          |
| `/ktor`                    | ktor-perf:8080                    |
| `/actix`                   | actix-perf:8080                   |
| `/quarkus-jvm`             | quarkus-perf-jvm:8080             |
| `/quarkus-native`          | quarkus-perf-native:8080          |
| `/quarkus-reactive-jvm`    | quarkus-reactive-perf-jvm:8080    |
| `/quarkus-reactive-native` | quarkus-reactive-perf-native:8080 |
| `/`                        | spring-perf:8080 (default)        |

---

## Prerequisites

- Fedora Linux (or any Linux distro with cgroups v2)
- k3s installed (v1.35.5 used for the paper — see Quick Start)
- `kubectl` configured
- Container images pushed to `ghcr.io/matejsaric32/`
- `k6` (for the S6 load test): https://k6.io/docs/get-started/installation/
- At least 8GB RAM recommended

---

## Deploy — Step by Step

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.35.5+k3s1" sh -
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

The three scripts below correspond to Supplements S1–S3 of the paper.

### Scale Test (Supplement S1)

Tests how fast a framework scales up and down (paper Section 3.3.4, Table 4):

```bash
# bash
bash scripts/S1_scale_test.sh <framework-name> <min-replicas> <max-replicas>

# example
bash scripts/S1_scale_test.sh quarkus-reactive-perf-distroless 1 10

# PowerShell
.\scripts\S1_scale_test.ps1 -Framework quarkus-perf-jvm -Runs 10
```

### Startup Time Measurement (Supplement S2)

Measures how long a pod takes from scheduled to ready — readiness includes the deep health check
(PostgreSQL + Kafka connectivity), see paper Section 3.3.2 (Table 2):

```bash
# bash
bash scripts/S2_startup_measure.sh <framework-name>

# PowerShell
.\scripts\S2_startup_measure.ps1 -Framework quarkus-perf-jvm -Runs 10
```

> **Note:** pre-pull all images before measuring so results exclude image pull time
> (`kubectl apply` once and wait for Ready, or `sudo k3s crictl pull <image>`).

### Iso-Load Test (Supplement S3)

Fixed-rate load test (paper Sections 3.3.5 and 4.5, Table 8): k6 `constant-arrival-rate`,
100 RPS, 60 s warm-up (discarded) + 180 s measured window, routed through the NGINX ingress.
The endpoint reads one row from PostgreSQL by primary key (random ID 1–1000), publishes a Kafka
event and awaits the broker acknowledgment, then returns JSON.

```bash
# one framework (uses ingress path /<FRAMEWORK>)
k6 run -e TARGET=http://<node-ip> -e FRAMEWORK=quarkus-native -e RPS=100 scripts/S6_load.js

# output: s6_<framework>.csv with p50/p95/p99 latency, error rate, achieved RPS
```

Memory and CPU during the measured window are read from Prometheus/Grafana
(`container_memory_working_set_bytes`, `rate(container_cpu_usage_seconds_total[1m])`).

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

The probe path is wrong. Check the framework's health endpoint — note that all health endpoints are
**deep checks** that verify PostgreSQL and Kafka connectivity, so a pod is Ready only once its
infrastructure connections are established:

| Framework   | Health Path        | Implementation        |
|-------------|--------------------|-----------------------|
| Spring Boot | `/actuator/health` | Spring Boot Actuator  |
| Quarkus     | `/q/health/ready`  | SmallRye Health       |
| Ktor        | `/health`          | custom (DB + Kafka)   |
| Actix       | `/health`          | custom (DB + Kafka)   |

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
- Note: under cgroups v2, `container_memory_rss` reports anonymous memory only (heap/stacks),
  not the classic process RSS

**Prometheus** scrapes metrics every 5 seconds from:

- All pods with `prometheus.io/scrape: "true"` annotation
- cAdvisor for container CPU/memory

**Kafka UI** is available at `http://<node-ip>:30880`

---

## Related Repositories (framework source code)

| Framework        | Repository                                              |
|------------------|---------------------------------------------------------|
| Spring Boot      | https://github.com/matejsaric32/spring-perf              |
| Spring WebFlux   | https://github.com/matejsaric32/spring-reactor-perf      |
| Ktor             | https://github.com/matejsaric32/ktor-perf                |
| Quarkus          | https://github.com/matejsaric32/quarkus-perf             |
| Quarkus Reactive | https://github.com/matejsaric32/quarkus-reactive-perf    |
| Actix Web        | https://github.com/matejsaric32/perf-actix               |

Pre-built container images for all variants are published to GitHub Container Registry (`ghcr.io/matejsaric32/`).

---

## Connect to IntelliJ IDEA

1. Install the **Kubernetes plugin** in IntelliJ: `File → Settings → Plugins → Kubernetes`
2. Copy kubeconfig to your machine:

```bash
scp user@<node-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

3. Edit the file and replace `127.0.0.1` with your node's actual IP
4. IntelliJ will auto-detect `~/.kube/config` and show your cluster in the Kubernetes tab