import http from 'k6/http';

function extractAccessToken(res) {
  try {
    const body = res.json();
    return body?.tokens?.accessToken || '';
  } catch (_e) {
    return '';
  }
}

function rand() {
  return Math.floor(Math.random() * 1000000);
}

function pad(num, size = 4) {
  const s = String(num);
  if (s.length >= size) return s;
  return `${'0'.repeat(size - s.length)}${s}`;
}

function buildIdentity(caseTag = 'k6', seq = 0) {
  const pass = __ENV.USER_PASS || __ENV.PASS || '123456';
  const useFixedPool = (__ENV.AUTO_AUTH_FIXED_POOL || 'true').toLowerCase() !== 'false';

  if (useFixedPool) {
    const prefix = __ENV.AUTO_AUTH_USER_PREFIX || `${caseTag}_load_user`;
    const id = `${prefix}_${pad(seq || 1)}`;
    return {
      email: `${id}@test.com`,
      username: id,
      pass
    };
  }

  const ts = Date.now();
  return {
    email: __ENV.USER_EMAIL || `${caseTag}-k6-${ts}-${seq}-${rand()}@test.com`,
    username: __ENV.USERNAME || `${caseTag}_${ts}_${seq}_${rand()}`,
    pass
  };
}

function createOneUserToken(baseUrl, caseTag = 'k6', seq = 0) {
  const { email, username, pass } = buildIdentity(caseTag, seq);

  const registerPayload = JSON.stringify({
    email,
    username,
    password: pass,
    name: `${caseTag} K6 User`,
    role: 'user'
  });

  const registerRes = http.post(`${baseUrl}/v1/auth/register`, registerPayload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: __ENV.AUTH_TIMEOUT || '5s',
    tags: { auth: 'register' }
  });

  let token = extractAccessToken(registerRes);
  if (token) return token;

  const loginPayload = JSON.stringify({
    identifier: email,
    password: pass
  });
  const loginRes = http.post(`${baseUrl}/v1/auth/login`, loginPayload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: __ENV.AUTH_TIMEOUT || '5s',
    tags: { auth: 'login' }
  });

  token = extractAccessToken(loginRes);
  return token || '';
}

export function ensureUserToken(baseUrl, caseTag = 'k6') {
  if (__ENV.USER_TOKEN) return String(__ENV.USER_TOKEN);
  if (__ENV.AUTO_AUTH_DISABLE === 'true') return '';
  return createOneUserToken(baseUrl, caseTag, 0);
}

export function ensureUserTokens(baseUrl, caseTag = 'k6', count = 1) {
  if (__ENV.USER_TOKEN) return [String(__ENV.USER_TOKEN)];
  if (__ENV.AUTO_AUTH_DISABLE === 'true') return [];

  const n = Math.max(1, Number(count) || 1);
  const out = [];
  for (let i = 0; i < n; i += 1) {
    const token = createOneUserToken(baseUrl, caseTag, i + 1);
    if (token) out.push(token);
  }
  return out;
}
