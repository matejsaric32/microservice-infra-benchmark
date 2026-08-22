import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// S7 — CPU-bound iso-load (companion to S6, which is the IO-bound test).
//
// S6 hits /io/light (Redis + PostgreSQL + Kafka): latency there is dominated by
// network and broker acknowledgment, so it says little about how efficiently a
// runtime executes application code. S7 hits /compute, a pure arithmetic loop
// with no external calls, so the measured latency is the runtime itself —
// JIT-compiled JVM vs. AOT GraalVM native vs. Rust.
//
// The endpoint is deterministic: the same `iterations` value yields the same
// result on every framework, so all runtimes perform identical work per request.

const TARGET     = __ENV.TARGET || 'http://localhost:31081'; // base URL (host + optional ingress path)
const PATH       = __ENV.ENDPOINT || '/compute';             // endpoint path
const FRAMEWORK  = __ENV.FRAMEWORK || 'unknown';
const RPS        = Number(__ENV.RPS || 10);
const ITERATIONS = Number(__ENV.ITERATIONS || 1000000);      // per-request work size (~26ms warm JVM)
const WARMUP_S   = Number(__ENV.WARMUP_S || 60);             // discarded from statistics
const MEASURE_S  = Number(__ENV.MEASURE_S || 180);           // steady-state window that counts
const WARMUP_MS  = WARMUP_S * 1000;

// Server-reported compute time is parsed out of the JSON body by default. It
// separates "time spent computing" from "time spent queueing behind the 1-CPU
// limit", which is exactly where a saturated JVM diverges from a native binary.
const PARSE_BODY = (__ENV.PARSE_BODY || '1') !== '0';

const URL = `${TARGET}/${FRAMEWORK}${PATH}?iterations=${ITERATIONS}`;

const CSV_HEADER = 'framework,rps,iterations,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps,srv_p50_ms,srv_p95_ms';
const OUT_FILE   = `s7_${FRAMEWORK.replace(/[^A-Za-z0-9._-]/g, '_')}.csv`;

// ---- Measured-window-only metrics ----------------------------------------
const mLatency = new Trend('measured_latency', true); // end-to-end, time metric (ms)
const mCompute = new Trend('measured_compute', true); // server-reported computeTimeMs
const mErrors  = new Rate('measured_errors');
const mReqs    = new Counter('measured_reqs');

export const options = {
    // Bodies are tiny (~70 bytes); keeping them costs nothing and buys the
    // server-side compute timing plus a correctness check on the work done.
    discardResponseBodies: !PARSE_BODY,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
    scenarios: {
        iso_load: {
            executor: 'constant-arrival-rate', // OPEN model: rate is fixed regardless of latency
            rate: RPS,
            timeUnit: '1s',
            duration: `${WARMUP_S + MEASURE_S}s`,
            preAllocatedVUs: Math.max(50, RPS),
            maxVUs: Math.max(200, RPS * 4),
            gracefulStop: '10s',
        },
    },
    thresholds: {
        measured_errors: ['rate<0.01'],
    },
};

export function setup() {
    console.log(`[S7] framework=${FRAMEWORK} url=${URL} ` +
        `rate=${RPS}rps warmup=${WARMUP_S}s measured=${MEASURE_S}s -> ${OUT_FILE}`);

    // A CPU-bound test is only meaningful below saturation: the pods run under a
    // 1 CPU limit, so RPS * per-request CPU time must stay under ~1 core-second
    // per second. Probe once and warn rather than silently reporting queueing
    // delay as if it were runtime performance.
    const probe = http.get(URL, { tags: { name: 'setup' } });
    if (probe.status >= 200 && probe.status < 300) {
        let ms = NaN;
        try { ms = Number(JSON.parse(probe.body).computeTimeMs); } catch (e) { /* ignore */ }
        if (isFinite(ms)) {
            const cores = (ms / 1000) * RPS;
            console.log(`[S7] probe: computeTimeMs=${ms} -> ~${cores.toFixed(2)} cores needed at ${RPS} RPS`);
            if (cores > 0.8) {
                console.warn(`[S7] WARNING: ~${cores.toFixed(2)} cores needed but pods are limited to 1 CPU. ` +
                    `Lower RPS or ITERATIONS, or latency will measure queueing, not compute.`);
            }
        }
    } else {
        console.warn(`[S7] WARNING: setup probe returned HTTP ${probe.status} for ${URL}`);
    }
}

export default function () {
    const elapsed = exec.instance.currentTestRunDuration;      // ms since test start
    const phase   = elapsed >= WARMUP_MS ? 'measured' : 'warmup';

    const res = http.get(URL, {
        tags: { name: PATH, framework: FRAMEWORK, phase },
    });

    // Verifying the echoed `iterations` catches a framework that answers 200
    // while ignoring the query parameter — which would look like a spectacular
    // latency win instead of the measurement error it is.
    let computeMs = null;
    let workDone  = true;
    if (PARSE_BODY && res.status >= 200 && res.status < 300) {
        try {
            const body = JSON.parse(res.body);
            computeMs = Number(body.computeTimeMs);
            workDone  = Number(body.iterations) === ITERATIONS;
        } catch (e) {
            workDone = false;
        }
    }

    const ok = check(res, {
        'status is 2xx': (r) => r.status >= 200 && r.status < 300,
        'requested iterations performed': () => workDone,
    }, { framework: FRAMEWORK, phase });

    if (phase === 'measured') {
        mLatency.add(res.timings.duration);
        if (computeMs !== null && isFinite(computeMs)) mCompute.add(computeMs);
        mErrors.add(!ok);
        mReqs.add(1);
    }
}

// ---- Per-framework CSV: header row + one data row -------------------------
export function handleSummary(data) {
    const lat = (data.metrics.measured_latency && data.metrics.measured_latency.values) || {};
    const p50 = lat['p(50)'] != null ? lat['p(50)'] : (lat['med'] || 0);
    const p95 = lat['p(95)'] || 0;
    const p99 = lat['p(99)'] || 0;

    const srv    = (data.metrics.measured_compute && data.metrics.measured_compute.values) || {};
    const srvP50 = srv['p(50)'] != null ? srv['p(50)'] : (srv['med'] || 0);
    const srvP95 = srv['p(95)'] || 0;

    const errRate = (data.metrics.measured_errors && data.metrics.measured_errors.values.rate) || 0;
    const count   = (data.metrics.measured_reqs && data.metrics.measured_reqs.values.count) || 0;
    const achievedRps = count / MEASURE_S;

    const f = (n) => Number(n).toFixed(2);
    const dataRow = [
        FRAMEWORK, RPS, ITERATIONS,
        f(p50), f(p95), f(p99),
        f(errRate * 100), achievedRps.toFixed(1),
        f(srvP50), f(srvP95),
    ].join(',');
    const csv = `${CSV_HEADER}\n${dataRow}\n`;

    const human =
        `\n─── S7 CPU iso-load result (${FRAMEWORK}) ─────────────────────\n` +
        `  endpoint        : ${PATH}?iterations=${ITERATIONS}\n` +
        `  measured window : ${MEASURE_S}s @ ${RPS} RPS target\n` +
        `  requests counted: ${count}  (achieved ${achievedRps.toFixed(1)} RPS)\n` +
        `  latency p50/p95/p99 : ${f(p50)} / ${f(p95)} / ${f(p99)} ms\n` +
        `  server compute p50/p95 : ${f(srvP50)} / ${f(srvP95)} ms\n` +
        `  error rate          : ${f(errRate * 100)} %\n` +
        `  written to          : ${OUT_FILE}\n` +
        `───────────────────────────────────────────────────────────────\n`;

    return {
        [OUT_FILE]: csv,
        'stdout': human,
    };
}

// k6 run -e FRAMEWORK=actix -e ITERATIONS=1000000 -e RPS=10 -e WARMUP_S=5 -e MEASURE_S=10 S7_load.js
