import { useMemo, useState } from 'react';

import PageHeader from '../../components/common/PageHeader.jsx';
import Button from '../../components/common/Button.jsx';

function trimBaseUrl(value, fallback) {
  const raw = String(value || fallback || '').trim();
  if (!raw) return '';
  return raw.replace(/\/+$/, '');
}

function joinUrl(baseUrl, path) {
  if (!baseUrl) return '';
  if (!path) return baseUrl;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  return `${baseUrl}${path.startsWith('/') ? path : `/${path}`}`;
}

function LogsAudit() {
  const [tab, setTab] = useState('logs');

  const kibanaBase = trimBaseUrl(import.meta.env.VITE_KIBANA_URL, 'http://localhost:42193');
  const grafanaBase = trimBaseUrl(import.meta.env.VITE_GRAFANA_URL, 'http://localhost:42190');

  const kibanaLogsPath = import.meta.env.VITE_KIBANA_LOGS_PATH || '/app/discover';
  const kibanaAuditPath = import.meta.env.VITE_KIBANA_AUDIT_PATH || '/app/dashboards';
  const grafanaDashboardPath = import.meta.env.VITE_GRAFANA_DASHBOARD_PATH || '/d/service-overview/service-overview';
  const grafanaTracePath = import.meta.env.VITE_GRAFANA_TRACE_PATH || '/explore';

  const links = useMemo(
    () => ({
      logs: joinUrl(kibanaBase, kibanaLogsPath),
      audit: joinUrl(kibanaBase, kibanaAuditPath),
      metrics: joinUrl(grafanaBase, grafanaDashboardPath),
      traces: joinUrl(grafanaBase, grafanaTracePath)
    }),
    [kibanaBase, grafanaBase, kibanaLogsPath, kibanaAuditPath, grafanaDashboardPath, grafanaTracePath]
  );

  const iframeSrc = tab === 'logs' ? links.logs : links.metrics;

  return (
    <div>
      <PageHeader
        title="Nhật ký & Kiểm toán"
        subtitle="Tích hợp trực tiếp Kibana cho logs/audit và Grafana cho metric/trace."
      />

      <div className="tabs" style={{ marginBottom: 12 }}>
        <div className={`tab ${tab === 'logs' ? 'active' : ''}`} onClick={() => setTab('logs')}>
          Nhật ký (Kibana)
        </div>
        <div className={`tab ${tab === 'monitoring' ? 'active' : ''}`} onClick={() => setTab('monitoring')}>
          Giám sát (Grafana)
        </div>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-header">
          <h3 className="card-title">Liên kết nhanh</h3>
        </div>

        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <a href={links.logs} target="_blank" rel="noreferrer">
            <Button variant="outline">Mở Kibana Logs</Button>
          </a>

          <a href={links.audit} target="_blank" rel="noreferrer">
            <Button variant="outline">Mở Kibana Audit</Button>
          </a>

          <a href={links.metrics} target="_blank" rel="noreferrer">
            <Button variant="outline">Mở Grafana Dashboard</Button>
          </a>

          <a href={links.traces} target="_blank" rel="noreferrer">
            <Button variant="outline">Mở Grafana Explore</Button>
          </a>
        </div>
      </div>

      <div className="card">
        <div className="card-header">
          <h3 className="card-title">{tab === 'logs' ? 'Khung xem Kibana Logs' : 'Khung xem Grafana Monitoring'}</h3>
        </div>

        <iframe
          title={tab === 'logs' ? 'Kibana logs' : 'Grafana monitoring'}
          src={iframeSrc}
          style={{ width: '100%', minHeight: 680, border: '1px solid var(--border)', borderRadius: 12, background: '#fff' }}
        />

        <div className="input-helper">Nếu iframe bị chặn (X-Frame-Options), dùng các nút mở để xem ở tab mới.</div>
      </div>
    </div>
  );
}

export default LogsAudit;
