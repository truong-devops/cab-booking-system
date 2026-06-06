const fs = require('fs');
const path = require('path');

const outDir = __dirname;

function raw(body) {
  return typeof body === 'string' ? body : JSON.stringify(body);
}

function tests(lines) {
  return [{ listen: 'test', script: { type: 'text/javascript', exec: lines } }];
}

function prereq(lines) {
  return [{ listen: 'prerequest', script: { type: 'text/javascript', exec: lines } }];
}

function request(name, method, url, { headers = [], body, event = [], description = '' } = {}) {
  const req = {
    name,
    request: {
      method,
      header: headers.map(([key, value]) => ({ key, value })),
      url,
      description
    }
  };
  if (body !== undefined && method !== 'GET' && method !== 'HEAD') {
    req.request.body = { mode: 'raw', raw: raw(body) };
    if (!req.request.header.some((h) => h.key.toLowerCase() === 'content-type')) {
      req.request.header.push({ key: 'Content-Type', value: 'application/json' });
    }
  }
  if (event.length) req.event = event;
  return req;
}

function bearer(v) {
  return ['Authorization', `Bearer {{${v}}}`];
}

function jsonHeader() {
  return ['Content-Type', 'application/json'];
}

function internalKey() {
  return ['x-internal-key', '{{internalApiKey}}'];
}

function basicStatus(...codes) {
  return tests([`pm.test('Expected status ${codes.join(' or ')}', function () { pm.expect(${JSON.stringify(codes)}).to.include(pm.response.code); });`]);
}

function no5xx() {
  return tests(["pm.test('No 5xx backend collapse', function () { pm.expect(pm.response.code).to.not.be.within(500, 599); });"]);
}

function collection(name, description, items, variables = []) {
  return {
    info: {
      _postman_id: `${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${Date.now()}`,
      name,
      description,
      schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'
    },
    event: prereq([
      "if (!pm.collectionVariables.get('uniq')) pm.collectionVariables.set('uniq', Date.now() + '-' + Math.floor(Math.random() * 100000));",
      "if (!pm.collectionVariables.get('userPass')) pm.collectionVariables.set('userPass', '123456');",
      "const uniq = pm.collectionVariables.get('uniq');",
      "pm.collectionVariables.set('userEmail', 'postman-user-' + uniq + '@test.com');",
      "pm.collectionVariables.set('adminEmail', 'postman-admin-' + uniq + '@test.com');",
      "pm.collectionVariables.set('driverEmail', 'postman-driver-' + uniq + '@test.com');"
    ]),
    variable: [
      { key: 'baseUrl', value: 'http://localhost:42100' },
      { key: 'aiUrl', value: 'http://localhost:42112' },
      { key: 'etaUrl', value: 'http://localhost:42111' },
      { key: 'pricingUrl', value: 'http://localhost:42106' },
      { key: 'bookingUrl', value: 'http://localhost:42104' },
      { key: 'paymentUrl', value: 'http://localhost:42107' },
      { key: 'internalApiKey', value: 'dev-internal-key' },
      { key: 'userPass', value: '123456' },
      { key: 'uniq', value: '' },
      { key: 'userEmail', value: '' },
      { key: 'adminEmail', value: '' },
      { key: 'driverEmail', value: '' },
      ...variables
    ],
    item: items
  };
}

const extractToken = [
  "const j = pm.response.json();",
  "const token = j?.tokens?.accessToken;",
  "const userId = j?.data?.user_id || j?.data?.id || j?.user_id || j?.id;",
  "pm.collectionVariables.set(pm.info.requestName.includes('Admin') ? 'adminToken' : pm.info.requestName.includes('Driver') ? 'driverToken' : 'userToken', token || '');",
  "if (userId) pm.collectionVariables.set(pm.info.requestName.includes('Admin') ? 'adminId' : pm.info.requestName.includes('Driver') ? 'driverUserId' : 'userId', userId);",
  "pm.test('Login returns token', function () { pm.expect(token).to.be.ok; });"
];

function setupFolder({ user = true, admin = true, driver = false } = {}) {
  const items = [
    request('Health Check', 'GET', '{{baseUrl}}/health', { event: basicStatus(200) })
  ];
  if (user) {
    items.push(
      request('Register User', 'POST', '{{baseUrl}}/v1/auth/register', {
        body: '{"email":"{{userEmail}}","password":"{{userPass}}","name":"Postman User {{uniq}}","role":"user"}'
      }),
      request('Login User', 'POST', '{{baseUrl}}/v1/auth/login', {
        body: '{"identifier":"{{userEmail}}","password":"{{userPass}}"}',
        event: tests(extractToken)
      })
    );
  }
  if (admin) {
    items.push(
      request('Register Admin', 'POST', '{{baseUrl}}/v1/auth/register', {
        body: '{"email":"{{adminEmail}}","password":"{{userPass}}","name":"Postman Admin {{uniq}}","role":"admin"}'
      }),
      request('Login Admin', 'POST', '{{baseUrl}}/v1/auth/login', {
        body: '{"identifier":"{{adminEmail}}","password":"{{userPass}}"}',
        event: tests(extractToken)
      })
    );
  }
  if (driver) {
    items.push(
      request('Register Driver', 'POST', '{{baseUrl}}/v1/auth/register', {
        body: '{"email":"{{driverEmail}}","password":"{{userPass}}","name":"Postman Driver {{uniq}}","role":"driver"}'
      }),
      request('Login Driver', 'POST', '{{baseUrl}}/v1/auth/login', {
        body: '{"identifier":"{{driverEmail}}","password":"{{userPass}}"}',
        event: tests(extractToken)
      })
    );
  }
  return { name: '00 Setup', item: items };
}

function driverInventorySetupFolder() {
  return { name: '00 Driver Inventory Setup', item: [
    request('Create Driver Profile', 'POST', '{{baseUrl}}/v1/admin/drivers', { headers: [bearer('adminToken')], body: '{"userId":"{{driverUserId}}","fullName":"Postman Driver {{uniq}}","phone":"0900000000"}', event: tests(["if (pm.response.code < 300) { const j=pm.response.json(); pm.collectionVariables.set('driverId', j?.data?.driver?.id || j?.data?.id || j?.driver?.id || j?.id || ''); }", "pm.test('Create driver accepted or already exists', function () { pm.expect([200,201,409]).to.include(pm.response.code); });"]) }),
    request('Approve Driver Profile', 'PATCH', '{{baseUrl}}/v1/admin/drivers/{{driverId}}/approve', { headers: [bearer('adminToken')], body: '{}', event: basicStatus(200) }),
    request('Register Driver Vehicle', 'PUT', '{{baseUrl}}/v1/driver/me/vehicle', { headers: [bearer('driverToken')], body: '{"vehicleType":"CAR","plateNumber":"PM-{{uniq}}"}', event: basicStatus(200) }),
    request('Reset Driver Offline', 'POST', '{{baseUrl}}/v1/driver/status', { headers: [bearer('adminToken')], body: '{"driver_id":"{{driverId}}","status":"OFFLINE"}', event: basicStatus(200, 409) }),
    request('Set Driver Online Near Pickup', 'POST', '{{baseUrl}}/v1/driver/status', { headers: [bearer('adminToken')], body: '{"driver_id":"{{driverId}}","status":"ONLINE","initial_location":{"lat":10.76,"lng":106.66}}', event: basicStatus(200) }),
    request('Verify Driver Availability', 'GET', '{{baseUrl}}/v1/driver/availability?lat=10.76&lng=106.66&limit=5', { headers: [bearer('userToken')], event: basicStatus(200) })
  ] };
}

function write(file, data) {
  fs.writeFileSync(path.join(outDir, file), `${JSON.stringify(data, null, 2)}\n`);
}

const bookingPayload = '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicleType":"CAR"}';
const bookingPayloadKm = '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"distance_km":5}';

write('level1-1-10.postman_collection.json', collection(
  'CAB System - Level 1 Cases 1-10',
  'Postman collection for API-runnable Level 1 baseline cases.',
  [
    setupFolder({ user: false, admin: true, driver: true }),
    { name: 'Case 1-2 - Register and Login User', item: [
      request('01 Register User', 'POST', '{{baseUrl}}/v1/auth/register', { body: '{"email":"{{userEmail}}","username":"postman{{uniq}}","password":"{{userPass}}","name":"Postman User {{uniq}}"}', event: basicStatus(201, 200, 409) }),
      request('02 Login User', 'POST', '{{baseUrl}}/v1/auth/login', { body: '{"identifier":"{{userEmail}}","password":"{{userPass}}"}', event: tests(extractToken) })
    ] },
    { name: 'Case 3-4 - Booking Create/List', item: [
      request('03 Create Booking Valid Input', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayloadKm, event: tests(["pm.test('Booking created', function () { pm.expect([200,201]).to.include(pm.response.code); });", "const j=pm.response.json(); pm.collectionVariables.set('bookingId', j?.booking?.booking_id || j?.booking?.bookingId || j?.data?.id || j?.data?.booking_id || '');"]) }),
      request('04 List User Bookings', 'GET', '{{baseUrl}}/v1/bookings?user_id={{userId}}', { headers: [bearer('userToken')], event: basicStatus(200) })
    ] },
    { name: 'Case 5 - Driver Online', item: [
      request('05 Create Driver Profile', 'POST', '{{baseUrl}}/v1/admin/drivers', { headers: [bearer('adminToken')], body: '{"userId":"{{driverUserId}}","fullName":"Postman Driver {{uniq}}","phone":"0900000000"}', event: tests(["if (pm.response.code < 300) { const j=pm.response.json(); pm.collectionVariables.set('driverId', j?.data?.driver?.id || j?.data?.id || j?.driver?.id || j?.id || ''); }", "pm.test('Create driver accepted or already exists', function () { pm.expect([200,201,409]).to.include(pm.response.code); });"]) }),
      request('05 Approve Driver Profile', 'PATCH', '{{baseUrl}}/v1/admin/drivers/{{driverId}}/approve', { headers: [bearer('adminToken')], body: '{}', event: basicStatus(200) }),
      request('05 Register Driver Vehicle', 'PUT', '{{baseUrl}}/v1/driver/me/vehicle', { headers: [bearer('driverToken')], body: '{"vehicleType":"CAR","plateNumber":"PM-{{uniq}}"}', event: basicStatus(200) }),
      request('05 Set Driver Online', 'POST', '{{baseUrl}}/v1/driver/status', { headers: [bearer('adminToken')], body: '{"driver_id":"{{driverId}}","status":"ONLINE","initial_location":{"lat":10.76,"lng":106.66}}', event: basicStatus(200) }),
      request('05 Availability Check', 'GET', '{{baseUrl}}/v1/driver/availability?lat=10.76&lng=106.66&limit=5', { headers: [bearer('userToken')], event: basicStatus(200) })
    ] },
    { name: 'Case 6-10 - Core APIs', item: [
      request('06 Read Created Booking', 'GET', '{{baseUrl}}/v1/bookings/{{bookingId}}', { headers: [bearer('userToken')], event: basicStatus(200) }),
      request('07 ETA Estimate', 'POST', '{{baseUrl}}/v1/eta/estimate', { headers: [bearer('userToken')], body: '{"distance_km":5,"traffic_level":0.5}', event: basicStatus(200) }),
      request('08 Pricing Estimate', 'POST', '{{baseUrl}}/v1/pricing/estimate', { headers: [bearer('userToken')], body: '{"distance_km":5,"demand_index":1.0}', event: basicStatus(200) }),
      request('09 Send Notification', 'POST', '{{baseUrl}}/v1/notifications', { headers: [bearer('userToken')], body: '{"user_id":"{{userId}}","message":"Your ride is confirmed"}', event: basicStatus(200, 201) }),
      request('10 Logout', 'POST', '{{baseUrl}}/v1/auth/logout', { headers: [bearer('userToken')], body: '{}', event: basicStatus(200) }),
      request('10 Verify Old Token Rejected', 'GET', '{{baseUrl}}/v1/bookings?user_id={{userId}}', { headers: [bearer('userToken')], event: basicStatus(401, 403) })
    ] }
  ],
  [{ key: 'bookingId', value: '' }, { key: 'driverId', value: '' }, { key: 'driverUserId', value: '' }]
));

write('level2-11-20.postman_collection.json', collection(
  'CAB System - Level 2 Cases 11-20',
  'Postman collection for Level 2 validation and error-path cases.',
  [
    setupFolder({ user: true, admin: true }),
    { name: 'Cases 11-18 - Validation/Error Paths', item: [
      request('11 Missing Pickup', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"drop":{"lat":10.77,"lng":106.70}}', event: basicStatus(400, 422) }),
      request('12 Invalid Lat Type', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":"abc","lng":106.66},"drop":{"lat":10.77,"lng":106.70}}', event: basicStatus(400, 422) }),
      request('13 No Drivers Online Area', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":21.0278,"lng":105.8342},"drop":{"lat":21.0285,"lng":105.8350},"vehicleType":"CAR"}', event: basicStatus(200, 201, 404, 409) }),
      request('14 Invalid Payment Method', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"payment_method":"invalid_card"}', event: basicStatus(400, 422) }),
      request('15 ETA Distance Zero', 'POST', '{{baseUrl}}/v1/eta/estimate', { headers: [bearer('userToken')], body: '{"distance_km":0}', event: basicStatus(200) }),
      request('16 Pricing Demand Zero', 'POST', '{{baseUrl}}/v1/pricing/estimate', { headers: [bearer('userToken')], body: '{"distance_km":5,"demand_index":0,"supply_index":1}', event: basicStatus(200) }),
      request('17 Fraud Missing Fields', 'POST', '{{baseUrl}}/v1/fraud/check', { headers: [bearer('userToken')], body: '{"user_id":"USR123"}', event: basicStatus(400, 422) }),
      request('18 Expired Token Placeholder', 'POST', '{{baseUrl}}/v1/bookings', { headers: [['Authorization', 'Bearer {{expiredToken}}']], body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70}}', event: basicStatus(401) })
    ] },
    { name: 'Cases 19-20 - Idempotency and Payload Size', item: [
      request('19 First Idempotent Booking', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['Idempotency-Key', 'case19-{{uniq}}']], body: '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}', event: tests(["const j=pm.response.json(); pm.collectionVariables.set('case19BookingId1', j?.booking?.booking_id || j?.booking?.bookingId || j?.data?.id || '');", "pm.test('First request accepted', function () { pm.expect([200,201]).to.include(pm.response.code); });"]) }),
      request('19 Replay Same Idempotent Booking', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['Idempotency-Key', 'case19-{{uniq}}']], body: '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}', event: basicStatus(200, 201) }),
      request('20 Payload Too Large Manual', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"huge":"Replace this value with >1MB string for exact script parity"}', event: basicStatus(400, 413, 422) })
    ] }
  ],
  [{ key: 'expiredToken', value: 'replace-with-expired-jwt' }, { key: 'case19BookingId1', value: '' }]
));

write('level3-21-30.postman_collection.json', collection(
  'CAB System - Level 3 Cases 21-30',
  'Postman collection for Level 3 service integration cases.',
  [
    setupFolder({ user: true, admin: true, driver: true }),
    driverInventorySetupFolder(),
    { name: 'Cases 21-25 - Booking Integration Flow', item: [
      request('21 Booking Calls ETA', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: basicStatus(200, 201) }),
      request('22 Booking Calls Pricing', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7702,"lng":106.7002},"vehicleType":"CAR"}', event: basicStatus(200, 201) }),
      request('23 AI Selects Driver', 'POST', '{{baseUrl}}/v1/bookings/ai/select-driver', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.76,"lng":106.66},"vehicleType":"CAR"}', event: basicStatus(200) }),
      request('24 Booking Payment Notification Flow', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7603,"lng":106.6603},"drop":{"lat":10.7703,"lng":106.7003},"vehicleType":"CAR","payment_method":"CASH"}', event: basicStatus(200, 201) }),
      request('25 Publish ride_requested', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR"}', event: tests(["const j=pm.response.json(); pm.collectionVariables.set('level3BookingId', j?.booking?.booking_id || j?.booking?.bookingId || j?.data?.id || '');", "pm.test('Booking accepted', function () { pm.expect([200,201]).to.include(pm.response.code); });"]) })
    ] },
    { name: 'Cases 26-30 - Status, MCP, Gateway, Timeout', item: [
      request('26-27 Accept Booking Status', 'PATCH', '{{baseUrl}}/v1/bookings/{{level3BookingId}}/status', { headers: [bearer('userToken')], body: '{"booking_id":"{{level3BookingId}}","status":"ACCEPTED","driver_id":"driver_fallback"}', event: basicStatus(200, 403) }),
      request('28 MCP Context Fetch', 'GET', '{{baseUrl}}/v1/bookings/{{level3BookingId}}/mcp-context', { headers: [bearer('userToken')], event: basicStatus(200, 404) }),
      request('29 Gateway Routes Booking', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7606,"lng":106.6606},"drop":{"lat":10.7706,"lng":106.7006},"vehicleType":"CAR"}', event: basicStatus(200, 201) }),
      request('30 Pricing Timeout Retry/Fallback', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7605,"lng":106.6605},"drop":{"lat":10.7705,"lng":106.7005},"vehicleType":"CAR","simulate_pricing_timeout":true}', event: basicStatus(200, 201, 504) })
    ] }
  ],
  [{ key: 'level3BookingId', value: '' }, { key: 'driverId', value: '' }, { key: 'driverUserId', value: '' }]
));

write('level4-31-40.postman_collection.json', collection(
  'CAB System - Level 4 Cases 31-40',
  'Postman collection for Level 4 transaction, idempotency, saga, and outbox probes.',
  [
    setupFolder({ user: true, admin: true }),
    { name: 'Cases 31-35 - Transaction and Concurrency Probes', item: [
      request('31 Transaction Create Success', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}', event: basicStatus(201, 200) }),
      request('32 Rollback After Insert Simulation', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7602,"lng":106.6602},"drop":{"lat":10.7702,"lng":106.7002},"vehicleType":"CAR","simulate_tx_failure_after_insert":true}', event: basicStatus(500, 400) }),
      request('33 Payment Failure Compensation', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7603,"lng":106.6603},"drop":{"lat":10.7703,"lng":106.7003},"vehicleType":"CAR","payment_method":"CARD","simulate_payment_failure":true}', event: basicStatus(200, 201, 402, 500) }),
      request('34 First Idempotent Booking', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['Idempotency-Key', 'case34-{{uniq}}']], body: '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR","payment_method":"CASH"}', event: basicStatus(200, 201) }),
      request('34 Replay Idempotent Booking', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['Idempotency-Key', 'case34-{{uniq}}']], body: '{"pickup":{"lat":10.7604,"lng":106.6604},"drop":{"lat":10.7704,"lng":106.7004},"vehicleType":"CAR","payment_method":"CASH"}', event: basicStatus(200, 201) }),
      request('35 Concurrent Booking Manual Runner', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7605,"lng":106.6605},"drop":{"lat":10.7705,"lng":106.7005},"vehicleType":"CAR"}', event: basicStatus(200, 201, 409) })
    ] },
    { name: 'Cases 36-40 - Saga/Outbox/ACID', item: [
      request('36 Saga Success Flow', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7607,"lng":106.6607},"drop":{"lat":10.7707,"lng":106.7007},"vehicleType":"CAR","payment_method":"CASH"}', event: basicStatus(200, 201) }),
      request('37 Saga Failure Compensation', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7607,"lng":106.6607},"drop":{"lat":10.7707,"lng":106.7007},"vehicleType":"CAR","simulate_payment_failure":true}', event: basicStatus(200, 201, 402, 500) }),
      request('38 Outbox Consistency Signal', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7608,"lng":106.6608},"drop":{"lat":10.7708,"lng":106.7008},"vehicleType":"CAR"}', event: basicStatus(200, 201) }),
      request('39 Payment Timeout Partial Failure', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.7609,"lng":106.6609},"drop":{"lat":10.7709,"lng":106.7009},"vehicleType":"CAR","payment_method":"CASH","simulate_payment_timeout":true}', event: basicStatus(200, 201, 504) }),
      request('40 Consistency Invalid Data Rejected', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"distance_km":-1}', event: basicStatus(400, 422) })
    ] }
  ]
));

write('level5-41-50.postman_collection.json', collection(
  'CAB System - Level 5 Cases 41-50',
  'Postman collection for Level 5 AI/ETA/Pricing model API cases.',
  [
    { name: '00 Service Health', item: [
      request('Gateway Health', 'GET', '{{baseUrl}}/health', { event: basicStatus(200) }),
      request('ETA Health', 'GET', '{{etaUrl}}/health', { event: basicStatus(200) }),
      request('AI Health', 'GET', '{{aiUrl}}/health', { event: basicStatus(200) }),
      request('Pricing Health', 'GET', '{{pricingUrl}}/health', { event: basicStatus(200) })
    ] },
    { name: 'Cases 41-50', item: [
      request('41 ETA Range Strict', 'POST', '{{etaUrl}}/v1/eta/estimate', { body: '{"distance_km":5,"traffic_level":0.5}', event: basicStatus(200) }),
      request('42 Surge High Demand', 'POST', '{{pricingUrl}}/v1/pricing/estimate', { headers: [internalKey()], body: '{"distance_km":5,"demand_index":2}', event: basicStatus(200) }),
      request('43 Fraud Score', 'POST', '{{aiUrl}}/v1/ai/fraud-score', { body: '{"user_id":"u1","driver_id":"d1","booking_id":"b1","amount":350000,"route_risk":0.9}', event: basicStatus(200) }),
      request('44 Recommend Drivers Top 3', 'POST', '{{aiUrl}}/v1/ai/recommend-drivers', { body: '{"pickup":{"lat":10.76,"lng":106.66},"vehicle_type":"CAR","candidates":[{"driver_id":"d1","distance_m":500,"rating":4.8,"eta_min":3,"price_score":0.9,"online":true},{"driver_id":"d2","distance_m":1200,"rating":4.6,"eta_min":8,"price_score":0.8,"online":true},{"driver_id":"d3","distance_m":300,"rating":4.7,"eta_min":2,"price_score":0.95,"online":true},{"driver_id":"d4","distance_m":100,"rating":4.9,"eta_min":1,"price_score":0.9,"online":false}]}', event: basicStatus(200) }),
      request('45 Forecast Demand', 'POST', '{{aiUrl}}/v1/ai/forecast-demand', { body: '{"zone_id":"HCM_Q1","horizon_min":30,"timestamp":"{{$isoTimestamp}}"}', event: basicStatus(200) }),
      request('46 Forecast Model v1', 'POST', '{{aiUrl}}/v1/ai/forecast-demand', { body: '{"zone_id":"HCM_Q1","horizon_min":30,"timestamp":"{{$isoTimestamp}}","model_version":"forecast-v1"}', event: basicStatus(200) }),
      request('46 Forecast Model v2', 'POST', '{{aiUrl}}/v1/ai/forecast-demand', { body: '{"zone_id":"HCM_Q1","horizon_min":30,"timestamp":"{{$isoTimestamp}}","model_version":"forecast-v2"}', event: basicStatus(200) }),
      request('47 Forecast Latency Sample', 'POST', '{{aiUrl}}/v1/ai/forecast-demand', { body: '{"zone_id":"HCM_Q1","horizon_min":30,"timestamp":"{{$isoTimestamp}}"}', event: no5xx() }),
      request('48 Drift Check', 'POST', '{{aiUrl}}/v1/ai/drift/check', { body: '{"model":"forecast-v1","features":{"hour":23,"rain":1,"demand_index":3}}', event: basicStatus(200) }),
      request('49 Recommendation Fallback', 'POST', '{{aiUrl}}/v1/ai/recommend-drivers', { body: '{"simulate_model_error":true,"pickup":{"lat":10.76,"lng":106.66},"vehicle_type":"CAR","candidates":[{"driver_id":"d1","distance_m":500,"rating":4.8,"eta_min":3,"price_score":0.9,"online":true}]}', event: basicStatus(200) }),
      request('50 ETA Abnormal Distance', 'POST', '{{etaUrl}}/v1/eta/estimate', { body: '{"distance_km":1000,"traffic_level":0.5}', event: no5xx() }),
      request('50 Pricing Abnormal Distance', 'POST', '{{pricingUrl}}/v1/pricing/estimate', { headers: [internalKey()], body: '{"distance_km":1000,"demand_index":1}', event: no5xx() })
    ] }
  ]
));

const agentPayloads = {
  51: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"nearest","max_eta_min":30,"budget_weight":0.5,"latency_budget_ms":200},"candidates":[{"driver_id":"d51_d1_5km","distance_m":5000,"rating":4.8,"eta_min":12,"price_score":0.7,"online":true},{"driver_id":"d51_d2_2km","distance_m":2000,"rating":4.5,"eta_min":6,"price_score":0.8,"online":true},{"driver_id":"d51_d3_3km","distance_m":3000,"rating":4.7,"eta_min":8,"price_score":0.75,"online":true}]}',
  52: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"highest_rating","max_eta_min":30,"budget_weight":0.5,"latency_budget_ms":200},"candidates":[{"driver_id":"d52_d1_near_rating4","distance_m":2000,"rating":4.0,"eta_min":5,"price_score":0.7,"online":true},{"driver_id":"d52_d2_far_rating49","distance_m":3000,"rating":4.9,"eta_min":8,"price_score":0.75,"online":true}]}',
  53: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"balanced_eta_price","max_eta_min":25,"budget_weight":0.75,"latency_budget_ms":200},"candidates":[{"driver_id":"d53_option_a_eta5_price50k","distance_m":1600,"rating":4.7,"eta_min":5,"price_score":0.2,"online":true},{"driver_id":"d53_option_b_eta8_price40k","distance_m":2300,"rating":4.8,"eta_min":8,"price_score":0.6,"online":true}]}',
  54: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"balanced_eta_price","max_eta_min":15,"budget_weight":0.7,"latency_budget_ms":200},"candidates":[{"driver_id":"d54_1","distance_m":220,"rating":4.5,"online":true},{"driver_id":"d54_2","distance_m":420,"rating":4.9,"online":true}]}',
  55: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"auto","max_eta_min":30,"budget_weight":0.5,"latency_budget_ms":200},"candidates":[{"driver_id":"d55_missing_eta","distance_m":250,"online":true},{"driver_id":"d55_missing_price","rating":4.7,"eta_min":4,"online":true},{"driver_id":"d55_missing_rating","distance_m":280,"eta_min":5,"online":true}]}',
  56: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","simulate_tool_error":true,"context":{"objective":"balanced_eta_price","max_eta_min":20,"budget_weight":0.7,"latency_budget_ms":200},"candidates":[{"driver_id":"d56_1","distance_m":200,"rating":4.5,"online":true},{"driver_id":"d56_2","distance_m":360,"rating":4.8,"online":true}]}',
  57: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"nearest","max_eta_min":30,"budget_weight":0.5,"latency_budget_ms":200},"candidates":[{"driver_id":"d57_online","distance_m":200,"rating":4.5,"eta_min":3,"price_score":0.7,"online":true},{"driver_id":"d57_offline_nearest","distance_m":20,"rating":5.0,"eta_min":1,"price_score":0.9,"online":false}]}',
  60: '{"simulate_model_error":true,"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"auto","max_eta_min":30,"budget_weight":0.5,"latency_budget_ms":200},"candidates":[{"driver_id":"d60_1","distance_m":220,"rating":4.2,"eta_min":3,"price_score":0.7,"online":true},{"driver_id":"d60_2","distance_m":120,"rating":4.0,"eta_min":2,"price_score":0.8,"online":true}]}'
};

write('level6-51-60.postman_collection.json', collection(
  'CAB System - Level 6 Cases 51-60',
  'Postman collection for Level 6 AI agent decision cases.',
  [
    { name: '00 Service Health', item: [request('AI Health', 'GET', '{{aiUrl}}/health', { event: basicStatus(200) })] },
    { name: 'Cases 51-60 - Agent Selection', item: [
      ...[51, 52, 53, 55, 56, 57, 60].map((id) => request(`${id} Agent Case`, 'POST', '{{aiUrl}}/v1/ai/agent/select-driver', { body: agentPayloads[id], event: basicStatus(200) })),
      request('54 ETA Tool Probe', 'POST', '{{aiUrl}}/v1/ai/agent/select-driver', { body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"nearest","budget_weight":0.2,"latency_budget_ms":200},"candidates":[{"driver_id":"d54_eta_1","distance_m":220,"rating":4.5,"price_score":0.82,"estimated_fare":18500,"online":true},{"driver_id":"d54_eta_2","distance_m":420,"rating":4.9,"price_score":0.79,"estimated_fare":19200,"online":true}]}', event: basicStatus(200) }),
      request('54 Pricing Tool Probe', 'POST', '{{aiUrl}}/v1/ai/agent/select-driver', { body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicle_type":"CAR","context":{"objective":"highest_rating","budget_weight":0.7,"latency_budget_ms":200},"candidates":[{"driver_id":"d54_price_1","distance_m":260,"rating":4.8,"eta_min":4,"online":true},{"driver_id":"d54_price_2","distance_m":340,"rating":4.9,"eta_min":5,"online":true}]}', event: basicStatus(200) }),
      request('58 Decision Logging POST', 'POST', '{{aiUrl}}/v1/ai/agent/select-driver', { headers: [['x-trace-id', 'trace58-{{uniq}}']], body: agentPayloads[54], event: basicStatus(200) }),
      request('58 Decision Logging Fetch', 'GET', '{{aiUrl}}/v1/ai/agent/decisions/trace58-{{uniq}}', { event: basicStatus(200) }),
      request('59 Parallel Requests Runner Sample', 'POST', '{{aiUrl}}/v1/ai/agent/select-driver', { body: agentPayloads[54], event: basicStatus(200), description: 'Run with Collection Runner iterations/concurrency for an approximate Postman version. Shell script is authoritative.' })
    ] }
  ]
));

write('level7-61-70.postman_collection.json', collection(
  'CAB System - Level 7 Cases 61-70',
  'Postman probes for Level 7 performance cases. Use Collection Runner for rough checks; original shell script is authoritative for RPS, p95, Kafka lag, Redis stats, and autoscaling.',
  [
    setupFolder({ user: true, admin: false }),
    { name: 'Cases 61-70 - Performance Probes', item: [
      request('61 Booking Load Sample', 'POST', '{{bookingUrl}}/v1/bookings', { headers: [internalKey(), ['x-user-id', 'load61-{{$randomInt}}'], ['x-user-role', 'admin'], ['x-user-roles', 'admin'], ['x-load-test', 'true'], ['x-booking-fast-path', '1']], body: '{"user_id":"load61-{{$randomInt}}","pickup":{"lat":10.7601,"lng":106.6601},"drop":{"lat":10.7701,"lng":106.7001},"vehicleType":"CAR"}', event: no5xx() }),
      request('62 ETA Load Sample', 'POST', '{{etaUrl}}/v1/eta/estimate', { body: '{"distance_km":4.7,"traffic_level":0.6}', event: no5xx() }),
      request('63 Pricing Spike Sample', 'POST', '{{pricingUrl}}/v1/pricing/estimate', { headers: [internalKey()], body: '{"distance_km":5,"demand_index":2}', event: no5xx() }),
      request('64 Kafka Demo Producer Sample', 'POST', '{{bookingUrl}}/demo/ride-created', { body: '{}', event: no5xx() }),
      request('65 DB Pool GET Sample', 'GET', '{{bookingUrl}}/v1/bookings?user_id=pool65-{{$randomInt}}&limit=50', { headers: [internalKey(), ['x-user-id', 'admin'], ['x-user-role', 'admin'], ['x-user-roles', 'admin'], ['x-load-test', 'true']], event: no5xx() }),
      request('66 Create Pricing Quote', 'POST', '{{pricingUrl}}/v1/pricing/quotes', { headers: [internalKey()], body: '{"pickup":{"lat":10.7601,"lng":106.6601},"dropoff":{"lat":10.7701,"lng":106.7001},"serviceType":"STANDARD"}', event: tests(["const j=pm.response.json(); pm.collectionVariables.set('quoteId', j?.data?.id || j?.id || j?.quote_id || '');", "pm.test('Quote created', function () { pm.expect([200,201]).to.include(pm.response.code); });"]) }),
      request('66 Read Pricing Quote', 'GET', '{{pricingUrl}}/v1/pricing/quotes/{{quoteId}}', { headers: [internalKey()], event: no5xx() }),
      request('67 Gateway Rate Limit Login Sample', 'POST', '{{baseUrl}}/v1/auth/login', { body: '{"identifier":"rate-limit-user@test.com","password":"wrong-pass"}', event: no5xx() }),
      request('68 Gateway ETA Latency Sample', 'POST', '{{baseUrl}}/v1/eta/estimate', { headers: [bearer('userToken'), ['x-load-test', 'true']], body: '{"distance_km":5.1,"traffic_level":0.5}', event: no5xx() }),
      request('69 Peak Booking Load Sample', 'POST', '{{bookingUrl}}/v1/bookings', { headers: [internalKey(), ['x-user-id', 'peak69-{{$randomInt}}'], ['x-user-role', 'admin'], ['x-user-roles', 'admin'], ['x-load-test', 'true'], ['x-booking-fast-path', '1']], body: '{"user_id":"peak69-{{$randomInt}}","pickup":{"lat":10.7603,"lng":106.6603},"drop":{"lat":10.7703,"lng":106.7003},"vehicleType":"CAR"}', event: no5xx() }),
      request('70 Autoscale Target Sample', 'POST', '{{case70AutoscaleTargetUrl}}', { body: '{"pickup":{"lat":10.76,"lng":106.66},"drop":{"lat":10.77,"lng":106.70},"vehicleType":"CAR"}', event: no5xx(), description: 'Set case70AutoscaleTargetUrl to the same target URL used by the shell script.' })
    ] }
  ],
  [{ key: 'quoteId', value: '' }, { key: 'case70AutoscaleTargetUrl', value: 'http://localhost:42104/v1/bookings' }]
));

write('level8-71-80.postman_collection.json', collection(
  'CAB System - Level 8 Cases 71-80',
  'Postman probes for Level 8 resilience cases. Docker compose fault injection, pause/unpause, DB restart, and network partition checks remain shell-script responsibilities.',
  [
    setupFolder({ user: true, admin: false }),
    { name: 'Cases 71-80 - Resilience Probes', item: [
      request('71 Booking While Driver Service Fault Injected', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('72 Booking While Pricing Timeout Injected', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('73 Booking While Kafka Down Injected', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('74 Booking After DB Recovery', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('75 Pricing Quote Fail-Fast Probe A', 'GET', '{{baseUrl}}/v1/pricing/quotes/non-existing-quote', { headers: [bearer('userToken')], event: no5xx() }),
      request('75 Pricing Quote Fail-Fast Probe B', 'GET', '{{baseUrl}}/v1/pricing/quotes/non-existing-quote', { headers: [bearer('userToken')], event: no5xx() }),
      request('76 Booking During Partial Failure', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('77 Exponential Backoff Policy Note', 'GET', '{{baseUrl}}/health', { event: basicStatus(200), description: 'Case 77 in script validates computed backoff policy locally; Postman only checks service health.' }),
      request('78 Booking During Mesh Route Fault', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: no5xx() }),
      request('79 Pricing Recovery After Partition', 'POST', '{{pricingUrl}}/v1/pricing/estimate', { headers: [internalKey()], body: '{"distance_km":5,"demand_index":1}', event: no5xx() }),
      request('80 Graceful Degradation Fast Path', 'POST', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['x-booking-fast-path', '1'], ['x-load-test', '1']], body: bookingPayload, event: no5xx() })
    ] }
  ]
));

write('level10-91-100.postman_collection.json', collection(
  'CAB System - Level 10 Cases 91-100',
  'Postman collection for API-runnable Level 10 security cases. Cases 94, 99, and parts of 100 require evidence/TLS/log access outside normal Postman requests.',
  [
    setupFolder({ user: true, admin: true, driver: true }),
    { name: 'Cases 91-100 - Security Probes', item: [
      request('91 Missing Token Bookings', 'GET', '{{baseUrl}}/v1/bookings', { event: basicStatus(401, 403) }),
      request('92 Tampered JWT', 'GET', '{{baseUrl}}/v1/bookings', { headers: [['Authorization', 'Bearer {{userToken}}x']], event: basicStatus(401) }),
      request('93 Expired Token Placeholder', 'GET', '{{baseUrl}}/v1/bookings', { headers: [['Authorization', 'Bearer {{expiredToken}}']], event: basicStatus(401) }),
      request('94 mTLS Evidence Note', 'GET', '{{baseUrl}}/health', { event: basicStatus(200), description: 'Case 94 is evidence-based in the shell script: scripts/evidence/case94-mtls-service-to-service.txt.' }),
      request('95 User Calls Admin API', 'GET', '{{baseUrl}}/v1/admin/drivers?limit=1', { headers: [bearer('userToken')], event: basicStatus(403) }),
      request('95 Admin Baseline', 'GET', '{{baseUrl}}/v1/admin/drivers?limit=1', { headers: [bearer('adminToken')], event: basicStatus(200) }),
      request('96 Driver Gets Other User', 'GET', '{{baseUrl}}/v1/users/{{userId}}', { headers: [bearer('driverToken')], event: basicStatus(401, 403, 404) }),
      request('97 Direct Booking Service No Auth', 'POST', '{{bookingUrl}}/v1/bookings', { body: bookingPayload, event: basicStatus(401, 403, 404) }),
      request('97 Direct Booking Service With User Token', 'POST', '{{bookingUrl}}/v1/bookings', { headers: [bearer('userToken')], body: bookingPayload, event: basicStatus(401, 403, 404) }),
      request('98 Auth Login Rate Limit Sample', 'POST', '{{baseUrl}}/v1/auth/login', { body: '{"identifier":"rate-limit-user@test.com","password":"wrong-pass"}', event: no5xx(), description: 'Run in Collection Runner for a rough 429 check; shell script is authoritative.' }),
      request('99 HTTPS Health Probe', 'GET', '{{httpsBaseUrl}}/health', { event: basicStatus(200), description: 'Set httpsBaseUrl to the TLS endpoint, e.g. https://localhost:42101. Postman cannot prove HTTPS-only redirect policy by itself.' }),
      request('100 Login With Audit Trace', 'POST', '{{baseUrl}}/v1/auth/login', { headers: [['x-trace-id', 'audit-login-{{uniq}}'], ['x-force-audit-log', '1']], body: '{"identifier":"{{userEmail}}","password":"{{userPass}}"}', event: basicStatus(200) }),
      request('100 API With Audit Trace', 'GET', '{{baseUrl}}/v1/bookings', { headers: [bearer('userToken'), ['x-trace-id', 'audit-api-{{uniq}}'], ['x-force-audit-log', '1']], event: basicStatus(200, 204) })
    ] }
  ],
  [{ key: 'expiredToken', value: 'replace-with-expired-jwt' }, { key: 'httpsBaseUrl', value: 'https://localhost:42101' }]
));

console.log('Generated Postman collections in', outDir);
