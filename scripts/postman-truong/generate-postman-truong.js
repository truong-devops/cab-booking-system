const fs = require('fs');
const path = require('path');

const SOURCE_DIR = path.resolve(__dirname, '../postman');
const OUTPUT_DIR = __dirname;

function range(start, end) {
  const out = [];
  for (let i = start; i <= end; i += 1) out.push(i);
  return out;
}

const DIRECT_CASES = [
  ...range(1, 24),
  29,
  ...range(41, 46),
  50,
  ...range(81, 86),
  ...range(91, 93),
  ...range(95, 96),
  98,
  102
];

const PARTIAL_CASES = [
  ...range(25, 28),
  ...range(30, 40),
  ...range(47, 49),
  ...range(51, 60),
  67,
  ...range(71, 80),
  ...range(87, 90),
  94,
  97,
  ...range(99, 100),
  ...range(103, 105),
  ...range(111, 120)
];

const NON_POSTMAN_CASES = [0, ...range(61, 66), ...range(68, 70), 101, ...range(106, 110)];

function uniqNumbers(values) {
  return [...new Set(values)].sort((a, b) => a - b);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function parseCaseId(name) {
  if (!name || typeof name !== 'string') return null;
  const m = name.match(/^\s*(\d{1,3})([A-Z])?\b/);
  if (!m) return null;
  return Number(m[1]);
}

function flattenRequests(items, out = []) {
  for (const item of items || []) {
    if (item && item.request) out.push(item);
    if (item && item.item) flattenRequests(item.item, out);
  }
  return out;
}

function requestTemplate(name, method, url, { headers = [], body = null, tests = [], description = '' } = {}) {
  const req = {
    name,
    request: {
      method,
      header: headers.map(([key, value]) => ({ key, value })),
      url,
      description
    }
  };
  if (body !== null && method !== 'GET' && method !== 'HEAD') {
    req.request.body = {
      mode: 'raw',
      raw: typeof body === 'string' ? body : JSON.stringify(body)
    };
    if (!req.request.header.some((h) => String(h.key).toLowerCase() === 'content-type')) {
      req.request.header.push({ key: 'Content-Type', value: 'application/json' });
    }
  }
  if (tests.length) {
    req.event = [
      {
        listen: 'test',
        script: {
          type: 'text/javascript',
          exec: tests
        }
      }
    ];
  }
  return req;
}

function buildCollection(name, description, items, variables = []) {
  return {
    info: {
      _postman_id: `${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${Date.now()}`,
      name,
      description,
      schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'
    },
    event: [
      {
        listen: 'prerequest',
        script: {
          type: 'text/javascript',
          exec: [
            "if (!pm.collectionVariables.get('uniq')) pm.collectionVariables.set('uniq', Date.now() + '-' + Math.floor(Math.random() * 100000));",
            "if (!pm.collectionVariables.get('userPass')) pm.collectionVariables.set('userPass', '123456');",
            "const uniq = pm.collectionVariables.get('uniq');",
            "pm.collectionVariables.set('userEmail', pm.collectionVariables.get('userEmail') || ('postman-user-' + uniq + '@test.com'));",
            "pm.collectionVariables.set('adminEmail', pm.collectionVariables.get('adminEmail') || ('postman-admin-' + uniq + '@test.com'));",
            "pm.collectionVariables.set('driverEmail', pm.collectionVariables.get('driverEmail') || ('postman-driver-' + uniq + '@test.com'));",
            "pm.collectionVariables.set('replayEmail', pm.collectionVariables.get('replayEmail') || ('postman-replay-' + uniq + '@test.com'));"
          ]
        }
      }
    ],
    variable: variables,
    item: items
  };
}

function findFirstByName(requestEntries, regexes) {
  for (const regex of regexes) {
    const found = requestEntries.find((entry) => regex.test(entry.name || ''));
    if (found) return clone(found.requestObj);
  }
  return null;
}

function collectPlaceholdersFromValue(value, out) {
  if (value == null) return;
  if (typeof value === 'string') {
    const matches = value.match(/\{\{[^{}]+\}\}/g) || [];
    for (const m of matches) {
      out.add(m.slice(2, -2));
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectPlaceholdersFromValue(item, out);
    return;
  }
  if (typeof value === 'object') {
    for (const v of Object.values(value)) collectPlaceholdersFromValue(v, out);
  }
}

function collectPlaceholdersFromItems(items) {
  const names = new Set();
  collectPlaceholdersFromValue(items, names);
  return names;
}

function createCaseFolder(caseId, requests, suffix = '') {
  return {
    name: `Case ${caseId}${suffix}`,
    item: requests
  };
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

const sourceFiles = fs
  .readdirSync(SOURCE_DIR)
  .filter((f) => f.endsWith('.postman_collection.json'))
  .sort();

const requestEntries = [];
const caseMap = new Map();

for (const file of sourceFiles) {
  const fullPath = path.join(SOURCE_DIR, file);
  const collection = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
  const requests = flattenRequests(collection.item || []);
  for (const req of requests) {
    const entry = {
      file,
      name: req.name || '',
      requestObj: req
    };
    requestEntries.push(entry);
    const caseId = parseCaseId(req.name || '');
    if (caseId == null) continue;
    if (!caseMap.has(caseId)) caseMap.set(caseId, []);
    caseMap.get(caseId).push(clone(req));
  }
}

const setupRequests = [];
const setupPatterns = [
  [/^Health Check$/i],
  [/^Register User$/i, /^01 Register User$/i],
  [/^Login User$/i, /^02 Login User$/i],
  [/^Register Admin$/i],
  [/^Login Admin$/i],
  [/^Register Driver$/i],
  [/^Login Driver$/i],
  [/^Create Driver Profile$/i, /^05 Create Driver Profile$/i],
  [/^Approve Driver Profile$/i, /^05 Approve Driver Profile$/i],
  [/^Register Driver Vehicle$/i, /^05 Register Driver Vehicle$/i],
  [/^Set Driver Online Near Pickup$/i, /^05 Set Driver Online$/i],
  [/^Verify Driver Availability$/i, /^05 Availability Check$/i],
  [/^Register Replay User$/i],
  [/^Login Replay User$/i]
];

for (const regexes of setupPatterns) {
  const picked = findFirstByName(requestEntries, regexes);
  if (picked) setupRequests.push(picked);
}

const directFolders = [
  {
    name: '00 Setup',
    item: setupRequests
  }
];

for (const caseId of uniqNumbers(DIRECT_CASES)) {
  if (caseId === 102) {
    directFolders.push(
      createCaseFolder(102, [
        requestTemplate('102 Health Check Endpoint', 'GET', '{{baseUrl}}/health', {
          tests: [
            "pm.test('HTTP 200', () => pm.expect(pm.response.code).to.eql(200));",
            "let j={}; try { j = pm.response.json(); } catch (e) {}",
            "pm.test('health payload ok', () => pm.expect(Boolean(j.ok)).to.eql(true));"
          ],
          description: 'Case 102: health check endpoint (directly testable via Postman).'
        })
      ])
    );
    continue;
  }

  const requests = caseMap.get(caseId) || [];
  if (requests.length) {
    directFolders.push(createCaseFolder(caseId, requests));
  }
}

const partialFolders = [
  {
    name: '00 Setup',
    item: setupRequests
  }
];

for (const caseId of uniqNumbers(PARTIAL_CASES)) {
  const requests = caseMap.get(caseId) || [];
  if (requests.length) {
    partialFolders.push(createCaseFolder(caseId, requests));
    continue;
  }

  const manual = [];
  if (caseId === 87) {
    manual.push(
      requestTemplate('87 Payment Listing (masking hint only)', 'GET', '{{baseUrl}}/v1/payments?limit=10', {
        headers: [['Authorization', 'Bearer {{userToken}}']],
        tests: [
          "pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"
        ],
        description:
          'Postman only triggers API read. You must verify encryption-at-rest in DB/KMS and ensure sensitive fields are not plaintext in storage.'
      })
    );
  }
  if (caseId === 88) {
    manual.push(
      requestTemplate('88 HTTPS/mTLS Evidence Probe', 'GET', '{{httpsBaseUrl}}/health', {
        tests: [
          "pm.test('Reachable HTTPS endpoint', () => pm.expect([200,401,403]).to.include(pm.response.code));"
        ],
        description:
          'mTLS must be verified at mesh/ingress layer with client certificate evidence. Postman request is only a probe.'
      })
    );
  }
  if (caseId === 103) {
    manual.push(
      requestTemplate('103 Service ENV Smoke via Health', 'GET', '{{baseUrl}}/health', {
        tests: ["pm.test('HTTP 200', () => pm.expect(pm.response.code).to.eql(200));"],
        description: 'Validate env variables with container logs/config, not just this API response.'
      })
    );
  }
  if (caseId === 104) {
    manual.push(
      requestTemplate('104 DB Connectivity Smoke', 'GET', '{{baseUrl}}/v1/bookings?limit=1', {
        headers: [['Authorization', 'Bearer {{userToken}}']],
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Need DB log/query evidence to confirm true connectivity and query success.'
      })
    );
  }
  if (caseId === 105) {
    manual.push(
      requestTemplate('105 Kafka Connectivity Trigger', 'POST', '{{bookingUrl}}/demo/ride-created', {
        headers: [['x-internal-key', '{{internalApiKey}}']],
        body: {
          ride_id: 'ride-case105-{{uniq}}',
          user_id: '{{userId}}',
          status: 'REQUESTED'
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Confirm broker/topic/consumer externally in Kafka UI/CLI.'
      })
    );
  }
  if (caseId === 111) {
    manual.push(
      requestTemplate('111 Traceable Booking Request', 'POST', '{{baseUrl}}/v1/bookings', {
        headers: [
          ['Authorization', 'Bearer {{userToken}}'],
          ['x-trace-id', 'case111-{{uniq}}']
        ],
        body: {
          pickup: { lat: 10.76, lng: 106.66 },
          drop: { lat: 10.77, lng: 106.7 },
          vehicleType: 'CAR'
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Use this to generate log records. Verify structured logs externally.'
      })
    );
  }
  if (caseId === 112) {
    manual.push(
      requestTemplate('112 Structured Log Trigger', 'POST', '{{baseUrl}}/v1/notifications', {
        headers: [['Authorization', 'Bearer {{userToken}}']],
        body: {
          user_id: '{{userId}}',
          message: 'structured-log-case-112'
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Verify JSON log schema in ELK/Loki after request.'
      })
    );
  }
  if (caseId === 113) {
    manual.push(
      requestTemplate('113 Metrics Endpoint Probe', 'GET', '{{aiUrl}}/metrics', {
        tests: ["pm.test('Metrics endpoint reachable', () => pm.expect(pm.response.code).to.eql(200));"],
        description: 'Real validation requires Prometheus scrape confirmation.'
      })
    );
  }
  if (caseId === 114) {
    manual.push(
      requestTemplate('114 Prometheus Query Probe', 'GET', '{{prometheusUrl}}/api/v1/query?query=up', {
        tests: ["pm.test('Prometheus reachable', () => pm.expect([200,401]).to.include(pm.response.code));"],
        description: 'Dashboard correctness must be verified in Grafana UI.'
      })
    );
  }
  if (caseId === 115) {
    manual.push(
      requestTemplate('115 Distributed Trace Trigger', 'POST', '{{baseUrl}}/v1/bookings', {
        headers: [
          ['Authorization', 'Bearer {{userToken}}'],
          ['x-trace-id', 'case115-{{uniq}}']
        ],
        body: {
          pickup: { lat: 10.7605, lng: 106.6605 },
          drop: { lat: 10.771, lng: 106.701 },
          vehicleType: 'CAR'
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Inspect full span chain in Jaeger/Tempo by trace_id.'
      })
    );
  }
  if (caseId === 116) {
    manual.push(
      requestTemplate('116 Error Rate Alert Trigger Seed', 'POST', '{{baseUrl}}/v1/bookings', {
        headers: [['Authorization', 'Bearer {{userToken}}']],
        body: {
          drop: { lat: 10.77, lng: 106.7 }
        },
        tests: ["pm.test('Validation error expected', () => pm.expect([400,422]).to.include(pm.response.code));"],
        description: 'Repeat requests with load tool to cross alert threshold.'
      })
    );
  }
  if (caseId === 117) {
    manual.push(
      requestTemplate('117 Latency Alert Trigger Seed', 'POST', '{{baseUrl}}/v1/bookings', {
        headers: [['Authorization', 'Bearer {{userToken}}']],
        body: {
          pickup: { lat: 10.76, lng: 106.66 },
          drop: { lat: 10.77, lng: 106.7 },
          vehicleType: 'CAR',
          simulate_pricing_timeout: true
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Use k6 to sustain latency spike; Postman request is only a seed.'
      })
    );
  }
  if (caseId === 118) {
    manual.push(
      requestTemplate('118 AI Monitoring Trigger', 'POST', '{{aiUrl}}/v1/ai/forecast-demand', {
        body: {
          zone_id: 'SGN-D1',
          horizon_min: 30,
          timestamp: '{{$isoTimestamp}}'
        },
        tests: ["pm.test('HTTP 200', () => pm.expect(pm.response.code).to.eql(200));"],
        description: 'Verify inference metrics/model_version/drift dashboards externally.'
      })
    );
  }
  if (caseId === 119) {
    manual.push(
      requestTemplate('119 Kafka Monitoring Trigger', 'POST', '{{bookingUrl}}/demo/ride-created', {
        headers: [['x-internal-key', '{{internalApiKey}}']],
        body: {
          ride_id: 'ride-case119-{{uniq}}',
          user_id: '{{userId}}',
          status: 'REQUESTED'
        },
        tests: ["pm.test('No 5xx', () => pm.expect(pm.response.code).to.not.be.within(500,599));"],
        description: 'Verify lag/offset/backlog in Kafka monitoring stack.'
      })
    );
  }
  if (caseId === 120) {
    manual.push(
      requestTemplate('120 Resource Monitoring Probe', 'GET', '{{baseUrl}}/health', {
        tests: ["pm.test('HTTP 200', () => pm.expect(pm.response.code).to.eql(200));"],
        description: 'CPU/memory checks require Prometheus/Grafana or container runtime metrics.'
      })
    );
  }

  if (manual.length) {
    partialFolders.push(createCaseFolder(caseId, manual, ' (Manual Evidence)'));
  }
}

const nonPostmanFolders = uniqNumbers(NON_POSTMAN_CASES).map((caseId) => ({
  name: `Case ${caseId}`,
  description:
    'Not suitable for Postman-only verification. Use k6/load tools and infra-level validation (Kafka/DB/K8s/monitoring).',
  item: []
}));

const baseVariables = [
  ['baseUrl', 'http://localhost:3000'],
  ['httpsBaseUrl', 'https://localhost:3443'],
  ['authUrl', 'http://localhost:4001'],
  ['bookingUrl', 'http://localhost:3003'],
  ['driverUrl', 'http://localhost:3011'],
  ['etaUrl', 'http://localhost:3012'],
  ['pricingUrl', 'http://localhost:3006'],
  ['aiUrl', 'http://localhost:3013'],
  ['paymentUrl', 'http://localhost:3007'],
  ['notificationUrl', 'http://localhost:3010'],
  ['prometheusUrl', 'http://localhost:9090'],
  ['grafanaUrl', 'http://localhost:3001'],
  ['jaegerUrl', 'http://localhost:16686'],
  ['internalApiKey', 'dev-internal-key'],
  ['userPass', '123456'],
  ['uniq', ''],
  ['userEmail', ''],
  ['adminEmail', ''],
  ['driverEmail', ''],
  ['replayEmail', ''],
  ['expiredToken', 'replace-with-expired-token']
];

function buildVariables(items) {
  const placeholders = collectPlaceholdersFromItems(items);
  const known = new Set(baseVariables.map(([k]) => k));
  const variables = baseVariables.map(([key, value]) => ({ key, value }));

  for (const key of [...placeholders].sort()) {
    if (key.startsWith('$')) continue;
    if (known.has(key)) continue;
    variables.push({ key, value: '' });
    known.add(key);
  }

  return variables;
}

const directCollection = buildCollection(
  'CAB System - Truong - Direct Postman Cases',
  'Cases directly testable with Postman (request/response/auth/validation) per grading mapping.',
  directFolders,
  buildVariables(directFolders)
);

const partialCollection = buildCollection(
  'CAB System - Truong - Partial Postman Cases',
  'Cases that can be triggered by Postman but require external evidence (DB/Kafka/logs/metrics/traces/certs).',
  partialFolders,
  buildVariables(partialFolders)
);

const nonPostmanCollection = buildCollection(
  'CAB System - Truong - Non-Postman Cases',
  'Cases not suitable for Postman-only testing. Folders intentionally left empty by request.',
  nonPostmanFolders,
  buildVariables(nonPostmanFolders)
);

const environment = {
  id: `cab-system-truong-env-${Date.now()}`,
  name: 'CAB System - Truong - Local',
  values: buildVariables([...directFolders, ...partialFolders]).map((v) => ({
    key: v.key,
    value: v.value,
    enabled: true
  })),
  _postman_variable_scope: 'environment',
  _postman_exported_at: new Date().toISOString(),
  _postman_exported_using: 'Codex'
};

ensureDir(OUTPUT_DIR);

fs.writeFileSync(
  path.join(OUTPUT_DIR, 'truong-direct.postman_collection.json'),
  `${JSON.stringify(directCollection, null, 2)}\n`
);
fs.writeFileSync(
  path.join(OUTPUT_DIR, 'truong-partial.postman_collection.json'),
  `${JSON.stringify(partialCollection, null, 2)}\n`
);
fs.writeFileSync(
  path.join(OUTPUT_DIR, 'truong-non-postman.postman_collection.json'),
  `${JSON.stringify(nonPostmanCollection, null, 2)}\n`
);
fs.writeFileSync(path.join(OUTPUT_DIR, 'truong-local.postman_environment.json'), `${JSON.stringify(environment, null, 2)}\n`);

console.log('Generated files in scripts/postman-truong:');
console.log('- truong-direct.postman_collection.json');
console.log('- truong-partial.postman_collection.json');
console.log('- truong-non-postman.postman_collection.json');
console.log('- truong-local.postman_environment.json');
