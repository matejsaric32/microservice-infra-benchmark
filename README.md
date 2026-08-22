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
./scripts/S10_longconn_with_metrics.sh quarkus-native quarkus-perf-native 31095 3  # connection sweep
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
├── longconn/
│   ├── nodeport-template.yaml.tpl      # template + NodePort allocation notes
│   └── nodeport-<framework>.yaml       # direct NodePort Service per framework (S9/S10)
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
    ├── S5_stats.py                     # Supplement S5 — mean/SD/95% CI + Mann-Whitney
    ├── S6_load.js                      # Supplement S3 — k6 iso-load test (100 RPS, /io/light)
    ├── S7_load.js                      # k6 CPU-bound iso-load (/compute)
    ├── S7_load_with_metrics.sh         # S6 + Prometheus CPU/memory over the measured window
    ├── S8_load_with_metrics.sh         # S7 + Prometheus CPU/memory over the measured window
    ├── S9_longconn.js                  # k6 long-lived connection sweep (/noop, direct NodePort)
    └── S10_longconn_with_metrics.sh    # S9 sweep + Prometheus CPU/memory per connection level
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

### Direct NodePort Routing (long-lived connection sweep only)

The long-lived connection sweep (S9/S10) does **not** go through the ingress: a keep-alive
connection opened against NGINX terminates on the ingress controller, which then serves the
request from its own upstream pool, so the pod would see a few hundred connections no matter
how many the client opens. Each framework therefore also has a `NodePort` Service in
`longconn/`, where kube-proxy performs DNAT only and the connection is established end-to-end
with the application process (pod connections == k6 VUs).

| NodePort | Service                              | Framework label            |
|----------|--------------------------------------|----------------------------|
| 31090    | spring-perf-direct                   | `spring`                   |
| 31091    | spring-reactor-perf-direct           | `spring-reactor`           |
| 31092    | actix-perf-direct                    | `actix`                    |
| 31093    | ktor-perf-direct                     | `ktor`                     |
| 31094    | quarkus-perf-jvm-direct              | `quarkus-jvm`              |
| 31095    | quarkus-perf-native-direct           | `quarkus-native`           |
| 31096    | quarkus-reactive-perf-jvm-direct     | `quarkus-reactive-jvm`     |
| 31097    | quarkus-reactive-perf-native-direct  | `quarkus-reactive-native`  |

Reserved for the image variants that are not deployed by default: 31098 `quarkus-perf-native-micro`,
31099 `quarkus-perf-native-micro-compressed`, 31100 `quarkus-perf-distroless`,
31101 `quarkus-reactive-perf-native-micro`, 31102 `quarkus-reactive-perf-native-micro-compressed`,
31103 `quarkus-reactive-perf-distroless`. Copy `longconn/nodeport-template.yaml.tpl`, substitute
`__APP__`/`__PORT__`, and record the port here.

```bash
kubectl apply -f longconn/                       # applied by setup-cluster.sh as well
kubectl -n perf-test get svc -l longconn=true
curl -s http://localhost:31090/noop              # note: no /<framework> path prefix
```

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

### Long-Lived Connection Sweep (S9 / S10)

Robustness arm: instead of holding the request rate fixed and asking what the runtime costs per
unit of work, this holds the *work* near zero and asks what it costs per **open connection**.
A fixed population of HTTP keep-alive connections is held against `/noop` — a constant body, no
I/O — so the only variable left is connection state: thread stacks and per-connection buffers on
a thread-per-request server versus event-loop registrations on a reactive one. Requires no change
to any application image; `/noop` already exists in all of them.

`S9_longconn.js` is the k6 scenario for one connection level (`ramping-vus`, one TCP connection
per VU, one request per connection every `THINK_S` seconds). `S10_longconn_with_metrics.sh`
sweeps the levels: for each level it restarts the pod cold, runs S9, and queries Prometheus over
exactly the k6 measured window.

```bash
# one level by hand (direct NodePort, no /<framework> prefix in the URL)
k6 run -e TARGET=http://localhost:31090 -e FRAMEWORK=spring -e CONNS=500 scripts/S9_longconn.js

# full sweep with server-side CPU/memory: <framework-label> <deployment> <nodePort> [reps]
./scripts/S10_longconn_with_metrics.sh spring spring-perf 31090 3

# custom levels / timing
LEVELS="0 100 500 1000 2000 5000" REPS=3 K6_CPUS=16-31 \
  ./scripts/S10_longconn_with_metrics.sh actix actix-perf 31092
```

Output: `s10_longconn_<framework>.csv`, one row per level per replicate —

```
framework,conns,run,p50_ms,p95_ms,p99_ms,err_pct,mean_conn_ms,max_conn_ms,measured_reqs,
achieved_rps,max_vus,est_conns_host,cpu_avg_cores,cpu_max_cores,mem_avg_mib,mem_max_mib,pod,k6_exit
```

The per-connection cost is the slope of `mem_avg_mib` against `conns`, with `conns=0` (an idle
pod, timed identically) as the baseline. The environment is recorded alongside it in
`s10_longconn_env_<framework>.txt`.

**Validity columns.** A framework that silently refuses connections above some cap produces a
flat memory curve that reads as efficiency, so three checks travel with every row:

| Column           | Expected                | Meaning if violated                                              |
|------------------|-------------------------|------------------------------------------------------------------|
| `mean_conn_ms`   | 0.000                   | connections are being re-established, not held — arm is invalid   |
| `max_vus`        | == `conns`              | the client never reached the target population                    |
| `est_conns_host` | `conns` + 1             | the kernel's own count of ESTABLISHED sockets to the NodePort (the extra one is k6's `setup()` preflight) |

**Configuration that must be pinned and reported** (defaults, not runtimes, are the risk here):

| Item                       | Where                                  | Note                                                                                                          |
|----------------------------|----------------------------------------|---------------------------------------------------------------------------------------------------------------|
| `THINK_S` (think time)     | `S9_longconn.js` / `S10` default `2`   | Must stay below the shortest server keep-alive timeout in the comparison, or the server closes idle connections and k6 silently re-establishes them. **Actix-Web sets the constraint at 5 s** (`HttpServer::keep_alive` default); a 10 s think time measured only ~48 % of the connections as ESTABLISHED. |
| Client file descriptors    | load generator host                    | S10 raises `ulimit -n` to `4 × max level + 8192` and warns if the hard limit is lower; the value is recorded.   |
| Ephemeral port range       | load generator host                    | One client IP to one server socket caps near 28 000 connections with the default range; recorded per run.       |
| CPU isolation of generator | `K6_CPUS` (e.g. `16-31`)               | k6 at 5 000 VUs is not free; pin it off the pod's cores and state this in the methodology.                      |
| `ACTIX_WORKERS`            | `frameworks/rust/actix-deployment.yaml`| Not set, so Actix falls back to `num_cpus::get()`; whether that honours the 1-CPU cgroup quota is version-dependent. Set it explicitly and report the value before publishing per-connection numbers. |
| Server connection caps     | Tomcat `max-connections`, Netty/Vert.x, Actix backlog | Confirm no level is being refused — `est_conns_host` is the check.                          |

> **Methodology note:** this arm deviates from the ingress routing path used by S6–S8, and that
> must be stated. The *measurement* path is unchanged: all reported values are container-level
> cAdvisor metrics via Prometheus, with no in-application instrumentation.

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