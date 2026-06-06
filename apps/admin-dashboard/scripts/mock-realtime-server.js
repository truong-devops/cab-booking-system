import { WebSocketServer } from 'ws';
import { mockMonitoring } from '../src/services/mock.data.js';

const PORT = Number(process.env.REALTIME_PORT || 42171);
const TICK_MS = Number(process.env.REALTIME_TICK_MS || 1000);

const BOUNDS = {
  minLat: 10.72,
  maxLat: 10.82,
  minLng: 106.62,
  maxLng: 106.74
};

function randomDelta(scale = 0.00045) {
  return (Math.random() - 0.5) * scale;
}

let positions = initPositions();

function initPositions() {
  return mockMonitoring.map.map((marker) => ({
    ...marker,
    lat: Number(marker.lat),
    lng: Number(marker.lng),
    vx: randomDelta(0.0006),
    vy: randomDelta(0.0006)
  }));
}

function stepPositions() {
  if (!positions.length) {
    positions = initPositions();
  }

  positions = positions.map((marker) => {
    let lat = marker.lat + marker.vx + randomDelta(0.00025);
    let lng = marker.lng + marker.vy + randomDelta(0.00025);
    let vx = marker.vx;
    let vy = marker.vy;

    if (lat < BOUNDS.minLat || lat > BOUNDS.maxLat) {
      vx = -vx;
      lat = Math.min(BOUNDS.maxLat, Math.max(BOUNDS.minLat, lat));
    }

    if (lng < BOUNDS.minLng || lng > BOUNDS.maxLng) {
      vy = -vy;
      lng = Math.min(BOUNDS.maxLng, Math.max(BOUNDS.minLng, lng));
    }

    return { ...marker, lat, lng, vx, vy };
  });

  return positions.map(({ id, type, lat, lng }) => ({ id, type, lat, lng }));
}

function broadcast(payload) {
  const message = JSON.stringify(payload);
  wss.clients.forEach((client) => {
    if (client.readyState === 1) {
      client.send(message);
    }
  });
}

const wss = new WebSocketServer({ port: PORT });

wss.on('connection', (socket) => {
  const snapshot = stepPositions();
  socket.send(
    JSON.stringify({
      type: 'positions',
      payload: snapshot,
      ts: new Date().toISOString()
    })
  );
});

setInterval(() => {
  const snapshot = stepPositions();
  broadcast({ type: 'positions', payload: snapshot, ts: new Date().toISOString() });
}, TICK_MS);

console.log(`[mock-realtime] ws://localhost:${PORT} streaming every ${TICK_MS}ms`);

process.on('SIGINT', () => {
  wss.close(() => process.exit(0));
});
