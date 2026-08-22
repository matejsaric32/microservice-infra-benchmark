import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// S9 — long-lived connection sweep (companion to S6 iso-load and S7 compute).
//
// S6 and S7 hold the request rate fixed and ask what the runtime costs per unit
// of work. S9 holds the *work* near zero and asks what the runtime costs per
// open connection: a fixed population of HTTP keep-alive connections is opened
// against /noop, which returns a constant body and performs no I/O, so the only
// variable left is connection state — accept queues, per-connection buffers,
// thread stacks on a thread-per-request server versus event-loop registrations
// on a reactive one.
//
// NOTE: TARGET must be the *direct* NodePort of the framework pod
// (longconn/nodeport-<framework>.yaml), NOT the NGINX ingress used by S6/S7.
// A keep-alive connection opened against the ingress terminates on the ingress
// controller, which then serves the request from its own upstream pool; the pod
// would see a few hundred connections no matter how many the client opens, and
// the working-set curve would be flat for reasons unrelated to the framework.
// Because kube-proxy only DNATs, a NodePort connection is established
// end-to-end with the application process and pod connections == VUs.

const TARGET    = __ENV.TARGET    || 'http://localhost:31090'; // direct NodePort, no path prefix
const PATH      = __ENV.ENDPOINT  || '/noop';
const FRAMEWORK = __ENV.FRAMEWORK || 'unknown';
const CONNS     = Number(__ENV.CONNS     || 100);  // held connections == VUs
// THINK_S must stay BELOW the shortest server-side keep-alive timeout of any
// framework in the comparison, or the server closes idle connections and k6
// silently re-establishes them: the pod then holds only a fraction of CONNS and
// the per-connection cost is understated. Actix-Web sets the binding constraint
// with a 5 s default (HttpServer::keep_alive); measured on this cluster, a 10 s
// think time left only ~50 % of the connections ESTABLISHED at any instant.
// 2 s keeps every connection alive with margin while still loading the pod
// negligibly (2000 connections = 1000 RPS of /noop).
const THINK_S   = Number(__ENV.THINK_S   || 2);    // 1 request / connection / 2 s
const RAMP_S    = Number(__ENV.RAMP_S    || 30);   // opening the connections
const HOLD_S    = Number(__ENV.HOLD_S    || 240);  // holding them
const MEASURE_S = Number(__ENV.MEASURE_S || 180);  // trailing window that counts

// The measured window is the LAST MEASURE_S of the run, so it contains only
// fully-open, already-reused connections. S10 queries Prometheus over exactly
// the same window.
const MEASURE_START_MS = (RAMP_S + HOLD_S - MEASURE_S) * 1000;

const URL      = `${TARGET}${PATH}`;
const OUT_FILE = `s9_${FRAMEWORK.replace(/[^A-Za-z0-9._-]/g, '_')}_${CONNS}.csv`;

const CSV_HEADER = 'framework,conns,p50_ms,p95_ms,p99_ms,err_pct,' +
    'mean_connecting_ms,max_connecting_ms,measured_reqs,achieved_rps,max_vus';

// ---- Measured-window-only metrics ----------------------------------------
const mLatency = new Trend('measured_latency', true);    // time metric (ms)
const mConnect = new Trend('measured_connecting', true); // validity check, see handleSummary
const mErrors  = new Rate('measured_errors');
const mReqs    = new Counter('measured_reqs');

export const options = {
    discardResponseBodies: true,
    // Both default to false; stated explicitly because the whole arm depends on
    // them. One TCP connection per VU, never closed between iterations.
    noConnectionReuse: false,
    noVUConnectionReuse: false,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
    scenarios: {
        hold_connections: {
            executor: 'ramping-vus', // CLOSED model: the VU population *is* the connection count
            startVUs: 0,
            stages: [
                { duration: `${RAMP_S}s`, target: CONNS }, // open
                { duration: `${HOLD_S}s`, target: CONNS }, // hold
            ],
            gracefulRampDown: '0s',
            gracefulStop: '5s',
        },
    },
    thresholds: {
        measured_errors: ['rate<0.01'],
    },
};

export function setup() {
    // Fail fast: a missing NodePort Service would otherwise produce CONNS VUs
    // worth of connection-refused errors and a plausible-looking empty CSV.
    const probe = http.get(URL, { tags: { phase: 'preflight' } });
    if (probe.status < 200 || probe.status >= 300) {
        exec.test.abort(`preflight GET ${URL} returned ${probe.status} ` +
            `(error: ${probe.error || 'none'}) — is the <framework>-direct NodePort Service applied?`);
    }
    console.log(`[S9] framework=${FRAMEWORK} url=${URL} conns=${CONNS} think=${THINK_S}s ` +
        `ramp=${RAMP_S}s hold=${HOLD_S}s measured=${MEASURE_S}s -> ${OUT_FILE}`);
}

export default function () {
    const elapsed = exec.instance.currentTestRunDuration;      // ms since test start
    const phase   = elapsed >= MEASURE_START_MS ? 'measured' : 'ramp';

    const res = http.get(URL, {
        tags: { name: PATH, framework: FRAMEWORK, conns: String(CONNS), phase },
    });

    const ok = check(res, {
        'status is 2xx': (r) => r.status >= 200 && r.status < 300,
    }, { framework: FRAMEWORK, phase });

    if (phase === 'measured') {
        mLatency.add(res.timings.duration);
        mConnect.add(res.timings.connecting);
        mErrors.add(!ok);
        mReqs.add(1);
    }

    sleep(THINK_S);
}

// ---- Per-level CSV: header row + one data row -----------------------------
export function handleSummary(data) {
    const lat  = (data.metrics.measured_latency    && data.metrics.measured_latency.values) || {};
    const conn = (data.metrics.measured_connecting && data.metrics.measured_connecting.values) || {};
    const p50 = lat['p(50)'] != null ? lat['p(50)'] : (lat['med'] || 0);
    const p95 = lat['p(95)'] || 0;
    const p99 = lat['p(99)'] || 0;
    const errRate = (data.metrics.measured_errors && data.metrics.measured_errors.values.rate) || 0;
    const count   = (data.metrics.measured_reqs   && data.metrics.measured_reqs.values.count) || 0;
    const maxVUs  = (data.metrics.vus && data.metrics.vus.values.max) || 0;
    const achievedRps = count / MEASURE_S;

    // Validity checks, both reported in the CSV rather than asserted:
    //  * connecting ~0 ms proves the TCP connection was reused across iterations.
    //    A materially non-zero mean means connections are being re-established
    //    and the arm is not measuring what it claims to.
    //  * max_vus < conns means the client never reached the target population
    //    (file descriptors, ephemeral ports, or a server-side connection cap),
    //    which would otherwise look like a flat, "efficient" memory curve.
    const connMean = conn['avg'] || 0;
    const connMax  = conn['max'] || 0;

    const f = (n) => Number(n).toFixed(3);
    const dataRow = [FRAMEWORK, CONNS, f(p50), f(p95), f(p99), f(errRate * 100),
        f(connMean), f(connMax), count, achievedRps.toFixed(2), maxVUs].join(',');
    const csv = `${CSV_HEADER}\n${dataRow}\n`;

    const expectedRps = CONNS / THINK_S;
    const warn = [];
    if (maxVUs < CONNS) {
        warn.push(`  !! only ${maxVUs}/${CONNS} connections were ever open — client or server cap hit`);
    }
    if (connMean > 0.01) {
        warn.push(`  !! mean connecting ${f(connMean)} ms — connections are NOT being reused`);
    }

    const human =
        `\n─── S9 long-lived connections (${FRAMEWORK} @ ${CONNS} conns) ───────────\n` +
        `  endpoint        : ${URL}\n` +
        `  measured window : last ${MEASURE_S}s of ${RAMP_S}+${HOLD_S}s, ${THINK_S}s think time\n` +
        `  requests counted: ${count}  (achieved ${achievedRps.toFixed(2)} RPS, expected ~${expectedRps.toFixed(2)})\n` +
        `  latency p50/p95/p99 : ${f(p50)} / ${f(p95)} / ${f(p99)} ms\n` +
        `  error rate          : ${f(errRate * 100)} %\n` +
        `  connecting mean/max : ${f(connMean)} / ${f(connMax)} ms  (≈0 = connections reused)\n` +
        `  peak VUs (== conns) : ${maxVUs}\n` +
        (warn.length ? warn.join('\n') + '\n' : '') +
        `  written to          : ${OUT_FILE}\n` +
        `───────────────────────────────────────────────────────────────\n`;

    return {
        [OUT_FILE]: csv,
        'stdout': human,
    };
}

// k6 run -e TARGET=http://localhost:31090 -e FRAMEWORK=spring -e CONNS=500 \
//        -e RAMP_S=10 -e HOLD_S=40 -e MEASURE_S=30 scripts/S9_longconn.js
