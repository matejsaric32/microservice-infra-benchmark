import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const TARGET      = __ENV.TARGET || 'http://localhost:31081'; // base URL (host + optional ingress path)
const PATH        = __ENV.ENDPOINT || '/io/light';            // endpoint path
const FRAMEWORK   = __ENV.FRAMEWORK || 'unknown';
const RPS         = Number(__ENV.RPS || 100);
const MAX_USER_ID = Number(__ENV.MAX_USER_ID || 1000);        // perf.users seeded 1..1000
const WARMUP_S    = Number(__ENV.WARMUP_S || 60);             // discarded from statistics
const MEASURE_S   = Number(__ENV.MEASURE_S || 180);           // steady-state window that counts
const WARMUP_MS   = WARMUP_S * 1000;

const URL_PREFIX = `${TARGET}/${FRAMEWORK}${PATH}`;

const CSV_HEADER = 'framework,rps,p50_ms,p95_ms,p99_ms,err_pct,achieved_rps';
const OUT_FILE   = `s6_${FRAMEWORK.replace(/[^A-Za-z0-9._-]/g, '_')}.csv`;

function randUserId() {
    return Math.floor(Math.random() * MAX_USER_ID) + 1; // uniform in [1, MAX_USER_ID]
}

// ---- Measured-window-only metrics ----------------------------------------
const mLatency = new Trend('measured_latency', true); // time metric (ms)
const mErrors  = new Rate('measured_errors');
const mReqs    = new Counter('measured_reqs');

export const options = {
    discardResponseBodies: true,
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
    console.log(`[S6] framework=${FRAMEWORK} url=${URL_PREFIX}?user_id=[1..${MAX_USER_ID}] ` +
        `rate=${RPS}rps warmup=${WARMUP_S}s measured=${MEASURE_S}s -> ${OUT_FILE}`);
}

export default function () {
    const elapsed = exec.instance.currentTestRunDuration;      // ms since test start
    const phase   = elapsed >= WARMUP_MS ? 'measured' : 'warmup';

    const url = `${URL_PREFIX}?user_id=${randUserId()}`;
    const res = http.get(url, {
        tags: { name: PATH, framework: FRAMEWORK, phase },
    });

    const ok = check(res, {
        'status is 2xx': (r) => r.status >= 200 && r.status < 300,
    }, { framework: FRAMEWORK, phase });

    if (phase === 'measured') {
        mLatency.add(res.timings.duration);
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
    const errRate = (data.metrics.measured_errors && data.metrics.measured_errors.values.rate) || 0;
    const count   = (data.metrics.measured_reqs && data.metrics.measured_reqs.values.count) || 0;
    const achievedRps = count / MEASURE_S;

    const f = (n) => Number(n).toFixed(2);
    const dataRow =
        [FRAMEWORK, RPS, f(p50), f(p95), f(p99), f(errRate * 100), achievedRps.toFixed(1)].join(',');
    const csv = `${CSV_HEADER}\n${dataRow}\n`;

    const human =
        `\n─── S6 iso-load result (${FRAMEWORK}) ─────────────────────────\n` +
        `  endpoint        : ${PATH}?user_id=[1..${MAX_USER_ID}]\n` +
        `  measured window : ${MEASURE_S}s @ ${RPS} RPS target\n` +
        `  requests counted: ${count}  (achieved ${achievedRps.toFixed(1)} RPS)\n` +
        `  latency p50/p95/p99 : ${f(p50)} / ${f(p95)} / ${f(p99)} ms\n` +
        `  error rate          : ${f(errRate * 100)} %\n` +
        `  written to          : ${OUT_FILE}\n` +
        `───────────────────────────────────────────────────────────────\n`;

    return {
        [OUT_FILE]: csv,
        'stdout': human,
    };
}

// k6 run -e FRAMEWORK=spring-perf -e WARMUP_S=5 -e MEASURE_S=10 S6_load.js