// k6 load script. The orchestrator (bench.sh) parameterizes it through env vars
// and reads the JSON summary written by handleSummary.
//
//   TARGET_URL   full URL to request (e.g. http://127.0.0.1:8080/)
//   VUS          number of concurrent virtual users (connections)
//   DURATION     measured duration (e.g. 10s)
//   SUMMARY_OUT  path to write the JSON summary to

import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: Number(__ENV.VUS || 50),
  duration: __ENV.DURATION || '10s',
  // Percentiles reported for every trend metric, including http_req_duration.
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(99)', 'max'],
  discardResponseBodies: false,
};

export default function () {
  const res = http.get(__ENV.TARGET_URL);
  check(res, { 'status is 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const out = __ENV.SUMMARY_OUT || 'summary.json';
  return { [out]: JSON.stringify(data) };
}
