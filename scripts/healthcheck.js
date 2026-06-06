const http = require('http');

const services = [{ name: 'api-gateway', port: 42100 }];

function check({ name, port }) {
  return new Promise((resolve) => {
    const req = http.get(`http://localhost:${port}/health`, (res) => {
      resolve({ name, ok: res.statusCode === 200, status: res.statusCode });
    });
    req.on('error', (e) => resolve({ name, ok: false, error: e.message }));
    req.setTimeout(1500, () => {
      req.destroy();
      resolve({ name, ok: false, error: 'timeout' });
    });
  });
}

(async () => {
  const results = await Promise.all(services.map(check));
  for (const r of results) console.log(r);
})();
