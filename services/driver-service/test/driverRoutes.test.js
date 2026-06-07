const request = require('supertest');
const jwt = require('jsonwebtoken');

jest.mock('../src/services/driverService', () => ({
  setOnline: jest.fn(async () => ({ driver: { id: '10000004' } })),
  updateDriverLocation: jest.fn(async () => ({ updated: true })),
  listAvailableDrivers: jest.fn(async () => [
    {
      driverId: '10000004',
      distanceMeters: 120,
      location: { lat: 10.1, lng: 20.2, recordedAt: new Date().toISOString() },
      vehicle: { type: 'CAR', plate: 'ABC-123' }
    }
  ]),
  getDriverMe: jest.fn(async () => ({ driver: { id: '10000004' } })),
  getDriverProfileForCustomer: jest.fn(async () => ({
    driver: {
      id: '10000004',
      fullName: 'Driver One',
      phone: '0900000001',
      status: 'APPROVED',
      onlineStatus: 'ONLINE'
    },
    vehicle: {
      id: 'veh-1',
      driverId: '10000004',
      vehicleType: 'CAR',
      plateNumber: 'ABC-123',
      brand: 'Toyota',
      model: 'Vios',
      color: 'White',
      isActive: true
    },
    location: { lat: 10.1, lng: 20.2, recordedAt: new Date().toISOString() }
  })),
  getAdminDashboardSummary: jest.fn(async () => ({
    generatedAt: new Date().toISOString(),
    drivers: {
      total: 3,
      status: { approved: 2, pending: 1, suspended: 0 },
      availability: { online: 1, offline: 2, busy: 0 }
    },
    kyc: { total: 2, pending: 1, approved: 1, rejected: 0 }
  }))
}));

const app = require('../src/app');
const redis = require('../src/cache/redis');
const pool = require('../src/db/pool');
const driverService = require('../src/services/driverService');

function signToken(payload) {
  const secret = process.env.AUTH_JWT_SECRET;
  return jwt.sign(payload, secret, { expiresIn: '15m' });
}

describe('driver-service routes (smoke)', () => {
  beforeAll(() => {
    process.env.AUTH_JWT_SECRET = 'test-secret';
  });

  afterAll(async () => {
    redis.disconnect();
    await pool.end();
  });

  test('driver online + location', async () => {
    const token = signToken({ sub: '10000004', roles: ['driver'] });

    const onlineRes = await request(app).post('/v1/driver/me/online').set('Authorization', `Bearer ${token}`).send({ deviceId: 'd1' });

    expect(onlineRes.status).toBe(200);
    expect(driverService.setOnline).toHaveBeenCalled();

    const locRes = await request(app).post('/v1/driver/me/location').set('Authorization', `Bearer ${token}`).send({ lat: 10.1, lng: 20.2 });

    expect(locRes.status).toBe(202);
    expect(driverService.updateDriverLocation).toHaveBeenCalled();
  });

  test('internal available query', async () => {
    const token = signToken({ sub: '10000001', roles: ['service'] });

    const res = await request(app).get('/v1/internal/drivers/available?lat=10.1&lng=20.2').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(1);
  });

  test('customer can fetch driver profile by driverId', async () => {
    const token = signToken({ sub: '10000003', roles: ['user'] });

    const res = await request(app).get('/v1/drivers/10000004/profile').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.data.driver.id).toBe('10000004');
    expect(res.body.data.vehicle.plateNumber).toBe('ABC-123');
    expect(driverService.getDriverProfileForCustomer).toHaveBeenCalledWith('10000004');
  });

  test('admin dashboard enforces RBAC and returns summary for admin', async () => {
    const userToken = signToken({ sub: '10000003', roles: ['user'] });
    const adminToken = signToken({ sub: '10000001', roles: ['admin'] });

    const denyRes = await request(app).get('/v1/admin/dashboard').set('Authorization', `Bearer ${userToken}`);
    expect(denyRes.status).toBe(403);
    expect(denyRes.body.error?.message).toMatch(/Access denied/i);

    const okRes = await request(app).get('/v1/admin/dashboard').set('Authorization', `Bearer ${adminToken}`);
    expect(okRes.status).toBe(200);
    expect(okRes.body.data).toHaveProperty('drivers.total');
    expect(okRes.body.data).toHaveProperty('kyc.pending');
    expect(driverService.getAdminDashboardSummary).toHaveBeenCalled();
  });
});
