# Admin Dashboard

Admin console for ride-hailing operations (Auth, Users, Drivers, Rides, Monitoring, Pricing, Logs).

## Routes

- `/admin/login`
- `/admin/dashboard`
- `/admin/users`
- `/admin/drivers`
- `/admin/rides`
- `/admin/monitoring`
- `/admin/pricing`
- `/admin/logs`

## Environment

- `VITE_API_BASE_URL` (defaults to same-origin; local `.env` uses `http://localhost:42100`)
- `VITE_MOCK=true` to run without backend
- `VITE_REALTIME_WS_URL` (example: `ws://localhost:42171`) to stream live map markers
- `VITE_KIBANA_URL` (default: `http://localhost:42193`)
- `VITE_GRAFANA_URL` (default: `http://localhost:42190`)
- `VITE_KIBANA_LOGS_PATH` (default: `/app/discover`)
- `VITE_KIBANA_AUDIT_PATH` (default: `/app/dashboards`)
- `VITE_GRAFANA_DASHBOARD_PATH` (default: `/d/service-overview/service-overview`)
- `VITE_GRAFANA_TRACE_PATH` (default: `/explore`)

## Scripts

```bash
npm install
npm run dev
```

Mock realtime stream (optional):

```bash
npm run mock:realtime
```

## Fix common issues

```bash
# clean install
rm -rf node_modules package-lock.json
npm install

# lint + fix
npm run lint -- --fix

# format
npm run format

# build
npm run build

# typecheck
# (JS project, no TypeScript typecheck configured)

# dev
npm run dev
```

## Notes

- All API calls go through the API Gateway.
- Mock mode uses local sample data for UI demo.
- Logs/Audit page is integrated with Kibana/Grafana links and embed views.
