**Implementing**** ****Long-Lived Connections**

A proposal grounded in the existing benchmark repositories

**1. Summary**

Long-Lived Connections can be added to the existing benchmark suite as **one new k6 script, one Service manifest per framework, and one runner script**, with no change to any application source repository. The /noop endpoint already required by Long-Lived Connections exists in every implementation, and the measurement path (cAdvisor → Prometheus) is already deployed and already queried by the existing scripts.

There is, however, **one design issue that must be resolved before any data is collected**: the NGINX ingress used by S6_load.js terminates client connections, so a connection sweep routed through the ingress would measure the ingress controller rather than the framework. Section 3 sets out the fix. Section 9 additionally reports three discrepancies between the repositories and the current manuscript text that were found while preparing this proposal; one of them affects a claim in Section 4.5 and should be corrected in the same revision.

**2. What the repositories already provide**

The following assets were inspected in the public repositories and can be reused as they stand.

| **Asset** | **Location** | **Role in ****Long-lived connections** |
| --- | --- | --- |
| /noop endpoint | Every application repo (e.g. src/routes/noop_handler.rs; NoopController.kt) | Target endpoint. Returns a constant body, performs no I/O — connection state is the only variable. |
| k6 iso-load script | microservice-infra-benchmark/scripts/S6_load.js | Template for S7: warm-up/measured phase split, tagging, CSV handleSummary all carry over. |
| Prometheus + cAdvisor | monitoring/08-prometheus.yaml | Working-set and CPU collection; same metric names as Section 3.3.3. |
| Deployment manifests | frameworks/<fw>/…-deployment.yaml | Unchanged. Long-Lived Connections adds a Service alongside, not a new Deployment. |
| Runner conventions | scripts/S1_scale_test.sh, S2_startup_measure.sh | Argument style, kubectl usage and CSV output conventions to match. |
| Framework name list | README (14 names, e.g. quarkus-perf-native-micro-compressed) | Drives the sweep loop and the NodePort allocation table. |

**3. The blocking design issue: the ingress terminates connections**

S6_load.js builds its URL as ${TARGET}/${FRAMEWORK}${PATH} and routes through the NGINX ingress defined in infra/07-ingress.yaml. That is correct for Arm A, where the quantity of interest is request throughput and the ingress is a constant overhead on every framework. It is **not** correct for Long-Lived Connections. A client keep-alive connection opened against the ingress terminates at the ingress controller, which then serves the request from its own upstream connection pool (ingress-nginx defaults to upstream-keepalive-connections: 320). Sweeping the client connection count from 100 to 5 000 would therefore hold 5 000 connections open on the *ingress controller pod* while the framework pod continues to see roughly 320 — and the measured working set would be flat, for reasons that have nothing to do with the framework.

**Proposed fix: **Long-Lived Connections connects directly to the framework pod through a dedicated NodePort Service. kube-proxy performs DNAT only, so the TCP connection is genuinely established end-to-end with the application process, and the connection count on the pod equals the VU count in k6.

This is a deliberate deviation from the ingress path described in Section 3.1 of the manuscript and **must be stated in the methodology**. The technology-agnostic principle is preserved, because it concerns the *measurement* path (cAdvisor at the container level, no in-application instrumentation) rather than the *routing* path; and because every framework is reached the same way, the comparison remains internally consistent. Suggested wording for Section 3.3.5:

*Long-Lived Connections** connects directly to the pod through a dedicated **NodePort** service rather than through the NGINX ingress used in Arms A and B, because connections opened against the ingress terminate on the ingress controller and would not exercise the connection-handling machinery of the framework under test. The measurement path remains unchanged: all reported resource values are container-level **cAdvisor** metrics, and no application-level instrumentation is introduced.*

**4. Proposed implementation**

**4.1 Files to add**

| **Path (in microservice-infra-benchmark)** | **Type** | **Purpose** |
| --- | --- | --- |
| scripts/S7_longconn.js | new | k6 connection-holding scenario (Supplement S4). |
| scripts/S7_run_arm_c.sh | new | Sweep runner: restarts the deployment per level, runs k6, pulls memory/CPU from Prometheus, writes one CSV per framework. |
| arm-c/nodeport-<fw>.yaml | new (×n) | Direct NodePort Service per framework, generated from the template in 4.3. |
| README.md | edit | Add an "Long-Lived Connections" section next to the existing S1/S2/S6 sections; add the NodePort allocation table. |
| setup-cluster.sh | edit | Apply arm-c/ after frameworks/ so the direct Services exist from the start. |

No change is required in spring-perf, spring-reactor-perf, ktor-perf, quarkus-perf, quarkus-reactive-perf or perf-actix. This is worth stating explicitly in the response letter: the robustness test reuses the published application images unmodified, so the new results are directly comparable with the existing ones.

**4.2 scripts/S7_longconn.js**

Modelled on S6_load.js so that the two scripts read as a pair. The substantive differences are the executor (ramping-vus holding a fixed VU population rather than constant-arrival-rate), the explicit keep-alive options, and the measured_connecting metric described below.

import http from 'k6/http';

import exec from 'k6/execution';

import { check, sleep } from 'k6';

import { Trend, Rate, Counter } from 'k6/metrics';



// S7_longconn.js — Arm C: long-lived connection sweep.

// Companion to S6_load.js. Holds a fixed population of HTTP keep-alive

// connections open against /noop and measures the per-connection working-set

// cost of each framework.

//

// NOTE: TARGET must be the *direct* NodePort of the framework pod, NOT the

// NGINX ingress. Connections opened against the ingress terminate on the

// ingress controller, not on the application under test.



const TARGET    = __ENV.TARGET    || 'http://127.0.0.1:31090';

const PATH      = __ENV.ENDPOINT  || '/noop';

const FRAMEWORK = __ENV.FRAMEWORK || 'unknown';

const CONNS     = Number(__ENV.CONNS     || 100);  // held connections == VUs

const THINK_S   = Number(__ENV.THINK_S   || 10);   // 1 request / connection / 10 s

const RAMP_S    = Number(__ENV.RAMP_S    || 30);

const HOLD_S    = Number(__ENV.HOLD_S    || 240);

const MEASURE_S = Number(__ENV.MEASURE_S || 180);  // final window that counts



const MEASURE_START_MS = (RAMP_S + HOLD_S - MEASURE_S) * 1000;

const OUT_FILE = `s7_${FRAMEWORK.replace(/[^A-Za-z0-9._-]/g,'_')}_${CONNS}.csv`;



const mLat  = new Trend('measured_latency', true);

const mConn = new Trend('measured_connecting', true); // validity check, see below

const mErr  = new Rate('measured_errors');

const mReq  = new Counter('measured_reqs');



export const options = {

discardResponseBodies: true,

noConnectionReuse: false,    // keep-alive ON: one TCP connection per VU

noVUConnectionReuse: false,  // do not close between iterations

summaryTrendStats: ['avg','min','med','max','p(50)','p(95)','p(99)'],

scenarios: {

    hold_connections: {
 
      executor: 'ramping-vus',
 
      startVUs: 0,
 
      stages: [
 
        { duration: `${RAMP_S}s`, target: CONNS },  // open connections
 
        { duration: `${HOLD_S}s`, target: CONNS },  // hold them
 
      ],
 
      gracefulRampDown: '0s',
 
      gracefulStop: '5s',
 
    },

},

thresholds: { measured_errors: ['rate<0.01'] },

};



export function setup() {

console.log(`[S7] ${FRAMEWORK} conns=${CONNS} url=${TARGET}${PATH} ` +

              `ramp=${RAMP_S}s hold=${HOLD_S}s measured=${MEASURE_S}s -> ${OUT_FILE}`);

}



export default function () {

const phase = exec.instance.currentTestRunDuration >= MEASURE_START_MS

    ? 'measured' : 'ramp';



const res = http.get(`${TARGET}${PATH}`, {

    tags: { framework: FRAMEWORK, conns: String(CONNS), phase },

});

const ok = check(res, { 'status is 2xx': (r) => r.status >= 200 && r.status < 300 },

                   { framework: FRAMEWORK, phase });



if (phase === 'measured') {

    mLat.add(res.timings.duration);
 
    mConn.add(res.timings.connecting);  // ~0 ms proves the connection was reused
 
    mErr.add(!ok);
 
    mReq.add(1);

}

sleep(THINK_S);

}



export function handleSummary(data) {

const v = (m, k) => (data.metrics[m] && data.metrics[m].values[k]) || 0;

const f = (n) => Number(n).toFixed(3);

const header = 'framework,conns,p50_ms,p95_ms,p99_ms,err_pct,' +

                 'mean_connecting_ms,measured_reqs';

const row = [FRAMEWORK, CONNS, f(v('measured_latency','p(50)')),

    f(v('measured_latency','p(95)')), f(v('measured_latency','p(99)')),
 
    f(v('measured_errors','rate') * 100), f(v('measured_connecting','avg')),
 
    v('measured_reqs','count')].join(',');

return { [OUT_FILE]: `${header}\n${row}\n`, stdout: `\n${header}\n${row}\n` };

}

**Why ****measured_connecting**** matters. **k6 reuses one TCP connection per VU, so after the first iteration res.timings.connecting should be approximately 0 ms. If the mean over the measured window is materially above zero, connections are being re-established between iterations and the arm is not measuring what it claims to. This is a cheap, self-contained validity check and its value should be reported in the supplementary data.

**4.3 Direct Service manifest**

# arm-c/nodeport-template.yaml

# One Service per framework. Arm C connects here directly so that the

# keep-alive connections terminate on the application pod rather than on

# the NGINX ingress controller.

apiVersion: v1

kind: Service

metadata:

name: __FW__-direct

namespace: perf-test

labels:

    armc: "true"

spec:

type: NodePort

selector:

    app: __FW__          # must match the deployment's pod label

ports:

    - name: http
 
      port: 8080
 
      targetPort: 8080
 
      nodePort: __PORT__ # 31090, 31091, ... one per framework

Allocate NodePorts sequentially over the 14 framework names listed in the README (31090 for spring-perf through 31103 for quarkus-reactive-perf-distroless), and record the mapping in the README so the assignment is reproducible.

**4.4 scripts/S7_run_arm_c.sh**

#!/usr/bin/env bash

# S7_run_arm_c.sh — Long-Lived Connections (long-lived connections) sweep for one framework.

# usage: bash scripts/S7_run_arm_c.sh <framework-name> <nodePort>

#   e.g. bash scripts/S7_run_arm_c.sh actix-perf 31090

set -euo pipefail



FW="${1:?framework name, e.g. actix-perf}"

PORT="${2:?nodePort of <framework>-direct}"

NS=perf-test

LEVELS="${LEVELS:-0 100 500 2000 5000}"   # 0 = baseline, no connections

REPS="${REPS:-3}"

K6_CPUS="${K6_CPUS:-16-31}"               # keep the generator off the pod's cores

RAMP_S=${RAMP_S:-30}; HOLD_S=${HOLD_S:-240}; MEASURE_S=${MEASURE_S:-180}

OUT="armc_${FW}.csv"



# raise client-side limits before any high level is attempted

ulimit -n 200000



kubectl -n "$NS" port-forward svc/prometheus 9090:9090 >/dev/null 2>&1 &

PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT; sleep 3



promq() {  # $1 = PromQL expression -> scalar

curl -sG --data-urlencode "query=$1" http://127.0.0.1:9090/api/v1/query |

python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "NaN")'

}

SEL="namespace=\"$NS\",pod=~\"${FW}-.*\",container!=\"\""

WS="container_memory_working_set_bytes{$SEL}"

CPU="rate(container_cpu_usage_seconds_total{$SEL}[1m])"



echo "framework,conns,rep,ws_mib,ws_max_mib,cpu_cores,p99_ms,err_pct,connecting_ms" > "$OUT"



for C in $LEVELS; do

for R in $(seq 1 "$REPS"); do

    # fresh process for every level: connection-table state must not carry over
 
    kubectl -n "$NS" rollout restart deployment "$FW"
 
    kubectl -n "$NS" rollout status  deployment "$FW" --timeout=300s
 
    sleep 60                                     # settle before measuring
 
 
 
    if [ "$C" -eq 0 ]; then
 
      sleep "$MEASURE_S"                         # 0-connection baseline
 
      P99=0; ERR=0; CONN=0
 
    else
 
      taskset -c "$K6_CPUS" k6 run \
 
        -e TARGET="http://127.0.0.1:${PORT}" -e FRAMEWORK="$FW" -e CONNS="$C" \
 
        -e RAMP_S="$RAMP_S" -e HOLD_S="$HOLD_S" -e MEASURE_S="$MEASURE_S" \
 
        scripts/S7_longconn.js
 
      read -r P99 ERR CONN < <(awk -F, 'NR==2{print $5,$6,$7}' "s7_${FW}_${C}.csv")
 
    fi
 
 
 
    # window ends now, so the lookback covers exactly the measured window
 
    WSM=$(promq "avg_over_time(${WS}[${MEASURE_S}s])")
 
    WSX=$(promq "max_over_time(${WS}[${MEASURE_S}s])")
 
    CPV=$(promq "avg_over_time(${CPU}[${MEASURE_S}s])")
 
    MIB=$(python3 -c "print(f'{float('$WSM')/1048576:.2f}')")
 
    MIX=$(python3 -c "print(f'{float('$WSX')/1048576:.2f}')")
 
 
 
    echo "$FW,$C,$R,$MIB,$MIX,$CPV,$P99,$ERR,$CONN" >> "$OUT"

done

done

echo "Long-Lived Connections sweep complete -> $OUT"

**5. Configuration that must be pinned and reported**

Long-Lived Connections is unusually sensitive to configuration that does not matter at 100 RPS. Each item below should be fixed, recorded in the repository, and stated in the manuscript; otherwise a difference in per-connection cost may reflect a default rather than a runtime.

| **Item** | **Where** | **Why it matters / action** |
| --- | --- | --- |
| ACTIX_WORKERS | perf-actix/src/main.rs reads it, but frameworks/rust/actix-deployment.yaml does not set it | Falls back to num_cpus::get(). Whether that honours the 1-CPU cgroup quota or returns the host thread count is version-dependent. Set it explicitly and report the value — worker count changes how connection state is distributed. |
| Client file descriptors | load-generator host | ulimit -n must exceed the highest level; 5 000 VUs plus k6 internals will exhaust the default 1024 immediately. |
| Ephemeral port range | load-generator host | One client IP to one server socket caps at roughly 28 000 connections with the default range. 5 000 is safe; record the range anyway. |
| Container nofile limit | k3s / containerd default | Verify the pod can accept the highest level; report the limit. |
| HTTP server connection caps | Tomcat max-connections, Netty/Vert.x defaults, Actix backlog | A framework that silently caps below the top level will show a flat memory curve that looks like efficiency. Record each default and confirm no level is being refused. |
| CPU isolation of the generator | taskset in the runner | k6 at 5 000 VUs is not free. Pin it off the cores the pod uses and state this in Section 3.3.5. |
 
