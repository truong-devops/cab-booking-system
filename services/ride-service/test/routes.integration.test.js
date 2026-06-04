const request = require('supertest');
const jwt = require('jsonwebtoken');

const TEST_SECRET = 'test-secret';
const authHeader = (payload = { sub: '10000003' }) => `Bearer ${jwt.sign(payload, TEST_SECRET)}`;

jest.mock('../src/repository/rideRepository', () => ({
  createRide: jest.fn(),
  addStatusHistory: jest.fn(),
  getRideById: jest.fn(),
  getRideByExternalId: jest.fn(),
  getRideStatusHistory: jest.fn(),
  getActiveRideForDriver: jest.fn(),
  claimRideForDriver: jest.fn(),
  findNextRequestedRide: jest.fn(),
  listRides: jest.fn(),
  updateRideFields: jest.fn(),
  updateRideStatus: jest.fn()
}));

jest.mock('../src/repository/idempotencyRepository', () => ({
  getByKey: jest.fn(),
  createKey: jest.fn(),
  setResponse: jest.fn()
}));

jest.mock('../src/idempotency/store', () => ({
  buildIdempotencyKey: jest.fn(() => 'idempo:key'),
  buildLockKey: jest.fn(() => 'idempo:lock'),
  getCachedResponse: jest.fn(() => Promise.resolve(null)),
  saveCachedResponse: jest.fn(() => Promise.resolve()),
  acquireLock: jest.fn(() => Promise.resolve(true)),
  releaseLock: jest.fn(() => Promise.resolve())
}));

const app = require('../src/app');
const rideRepository = require('../src/repository/rideRepository');
const idempotencyRepository = require('../src/repository/idempotencyRepository');

function buildRideRow(overrides = {}) {
  return {
    id: 'ride-1',
    external_ride_id: 'ext-1',
    booking_id: null,
    rider_id: '10000003',
    driver_id: null,
    quote_fare_amount: null,
    quote_currency: null,
    pickup_lat: 10.1,
    pickup_lng: 20.2,
    dropoff_lat: 10.2,
    dropoff_lng: 20.3,
    status: 'requested',
    status_updated_at: new Date('2024-01-01T00:00:00Z'),
    created_at: new Date('2024-01-01T00:00:00Z'),
    updated_at: new Date('2024-01-01T00:00:00Z'),
    ...overrides
  };
}

describe('ride-service routes integration', () => {
  beforeAll(() => {
    process.env.JWT_SECRET = TEST_SECRET;
  });

  afterAll(() => {
    delete process.env.JWT_SECRET;
  });

  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('creates a ride', async () => {
    rideRepository.createRide.mockResolvedValue(buildRideRow());
    idempotencyRepository.getByKey.mockResolvedValue(null);

    const response = await request(app)
      .post('/v1/rides')
      .set('Authorization', authHeader())
      .set('Idempotency-Key', 'idem-1')
      .send({ pickupLat: 10.1, pickupLng: 20.2, dropoffLat: 10.2, dropoffLng: 20.3 });

    expect(response.status).toBe(201);
    expect(response.body.data.id).toBe('ride-1');
  });

  it('gets a ride by id', async () => {
    rideRepository.getRideById.mockResolvedValue(
      buildRideRow({
        quote_fare_amount: 125000,
        quote_currency: 'VND'
      })
    );

    const response = await request(app).get('/v1/rides/ride-1').set('Authorization', authHeader());

    expect(response.status).toBe(200);
    expect(response.body.data.id).toBe('ride-1');
    expect(response.body.data.quoteFareAmount).toBe(125000);
    expect(response.body.data.quoteCurrency).toBe('VND');
  });

  it('backfills customer quote when external ride already exists', async () => {
    const existing = buildRideRow({
      id: 'ride-internal-bike',
      external_ride_id: 'ride_booking_1',
      booking_id: 'bk_booking_1',
      quote_fare_amount: 90000,
      quote_currency: 'VND'
    });
    const updated = buildRideRow({
      ...existing,
      quote_fare_amount: 49500,
      quote_currency: 'VND'
    });
    rideRepository.getRideByExternalId.mockResolvedValue(existing);
    rideRepository.updateRideFields.mockResolvedValue(updated);
    idempotencyRepository.getByKey.mockResolvedValue(null);

    const response = await request(app)
      .post('/v1/rides')
      .set('Authorization', authHeader())
      .set('Idempotency-Key', 'idem-existing-quote')
      .send({
        externalRideId: 'ride_booking_1',
        bookingId: 'bk_booking_1',
        pickupLat: 10.1,
        pickupLng: 20.2,
        dropoffLat: 10.2,
        dropoffLng: 20.3,
        quoteFareAmount: 49500,
        quoteCurrency: 'VND'
      });

    expect(response.status).toBe(200);
    expect(response.body.data.quoteFareAmount).toBe(49500);
    expect(rideRepository.updateRideFields).toHaveBeenCalledWith('ride-internal-bike', {
      quoteFareAmount: 49500,
      quoteCurrency: 'VND'
    });
  });

  it('lists rides with cursor', async () => {
    const row = buildRideRow({ id: 'ride-9' });
    rideRepository.listRides.mockResolvedValue([row]);

    const response = await request(app).get('/v1/rides?limit=1').set('Authorization', authHeader());

    expect(response.status).toBe(200);
    expect(response.body.nextCursor).toBe(Buffer.from(`${row.created_at.toISOString()}|${row.id}`).toString('base64'));
  });

  it('returns fare summary using payment linked by external ride id', async () => {
    const completedRide = buildRideRow({
      id: 'ride-internal-1',
      external_ride_id: 'ride_external_1',
      status: 'completed',
      created_at: new Date('2024-01-01T00:00:00Z'),
      status_updated_at: new Date('2024-01-01T01:00:00Z')
    });
    rideRepository.getRideById.mockResolvedValue(completedRide);
    rideRepository.getRideStatusHistory.mockResolvedValue([
      { to_status: 'in_progress', occurred_at: new Date('2024-01-01T00:20:00Z') },
      { to_status: 'completed', occurred_at: new Date('2024-01-01T01:00:00Z') }
    ]);

    const originalFetch = global.fetch;
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        data: [
          {
            id: 'pay-1',
            rideId: 'ride_external_1',
            amount: '123000',
            currency: 'VND',
            status: 'PAID',
            createdAt: '2024-01-01T01:00:00Z'
          }
        ]
      })
    });
    global.fetch = fetchMock;
    try {
      const response = await request(app).get('/v1/rides/ride-internal-1/summary').set('Authorization', authHeader());

      expect(response.status).toBe(200);
      expect(response.body.data.fare.amount).toBe(123000);
      expect(response.body.data.fare.source).toBe('payment-service');
      expect(fetchMock).toHaveBeenCalled();
      expect(String(fetchMock.mock.calls[0][0])).toContain('rideId=ride_external_1');
    } finally {
      global.fetch = originalFetch;
    }
  });

  it('falls back to booking quote fare when payment is not found', async () => {
    const completedRide = buildRideRow({
      id: 'ride-internal-2',
      external_ride_id: 'ride_external_2',
      status: 'completed',
      quote_fare_amount: 88000,
      quote_currency: 'VND',
      created_at: new Date('2024-01-01T00:00:00Z'),
      status_updated_at: new Date('2024-01-01T01:00:00Z')
    });
    rideRepository.getRideById.mockResolvedValue(completedRide);
    rideRepository.getRideStatusHistory.mockResolvedValue([
      { to_status: 'in_progress', occurred_at: new Date('2024-01-01T00:20:00Z') },
      { to_status: 'completed', occurred_at: new Date('2024-01-01T01:00:00Z') }
    ]);

    const originalFetch = global.fetch;
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ data: [] })
    });
    global.fetch = fetchMock;
    try {
      const response = await request(app).get('/v1/rides/ride-internal-2/summary').set('Authorization', authHeader());

      expect(response.status).toBe(200);
      expect(response.body.data.fare.amount).toBe(88000);
      expect(response.body.data.fare.currency).toBe('VND');
      expect(response.body.data.fare.source).toBe('booking-quote');
    } finally {
      global.fetch = originalFetch;
    }
  });

  it('ignores zero payment amount and uses booking quote in summary', async () => {
    const completedRide = buildRideRow({
      id: 'ride-internal-3',
      external_ride_id: 'ride_external_3',
      status: 'completed',
      quote_fare_amount: 99000,
      quote_currency: 'VND',
      created_at: new Date('2024-01-01T00:00:00Z'),
      status_updated_at: new Date('2024-01-01T01:00:00Z')
    });
    rideRepository.getRideById.mockResolvedValue(completedRide);
    rideRepository.getRideStatusHistory.mockResolvedValue([
      { to_status: 'in_progress', occurred_at: new Date('2024-01-01T00:20:00Z') },
      { to_status: 'completed', occurred_at: new Date('2024-01-01T01:00:00Z') }
    ]);

    const originalFetch = global.fetch;
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        data: [
          {
            id: 'pay-0',
            rideId: 'ride_external_3',
            amount: '0',
            currency: 'VND',
            status: 'INITIATED',
            createdAt: '2024-01-01T01:00:00Z'
          }
        ]
      })
    });
    global.fetch = fetchMock;
    try {
      const response = await request(app).get('/v1/rides/ride-internal-3/summary').set('Authorization', authHeader());

      expect(response.status).toBe(200);
      expect(response.body.data.fare.amount).toBe(99000);
      expect(response.body.data.fare.source).toBe('booking-quote');
      expect(response.body.data.fare.paymentStatus).toBe('INITIATED');
    } finally {
      global.fetch = originalFetch;
    }
  });

  it('uses booking quote when a non-paid payment amount exists', async () => {
    const completedRide = buildRideRow({
      id: 'ride-internal-4',
      external_ride_id: 'ride_external_4',
      status: 'completed',
      quote_fare_amount: 95000,
      quote_currency: 'VND',
      created_at: new Date('2024-01-01T00:00:00Z'),
      status_updated_at: new Date('2024-01-01T01:00:00Z')
    });
    rideRepository.getRideById.mockResolvedValue(completedRide);
    rideRepository.getRideStatusHistory.mockResolvedValue([
      { to_status: 'in_progress', occurred_at: new Date('2024-01-01T00:20:00Z') },
      { to_status: 'completed', occurred_at: new Date('2024-01-01T01:00:00Z') }
    ]);

    const originalFetch = global.fetch;
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        data: [
          {
            id: 'pay-1',
            rideId: 'ride_external_4',
            amount: '120000',
            currency: 'VND',
            status: 'INITIATED',
            createdAt: '2024-01-01T01:00:00Z'
          }
        ]
      })
    });
    global.fetch = fetchMock;
    try {
      const response = await request(app).get('/v1/rides/ride-internal-4/summary').set('Authorization', authHeader());

      expect(response.status).toBe(200);
      expect(response.body.data.fare.amount).toBe(95000);
      expect(response.body.data.fare.source).toBe('booking-quote');
      expect(response.body.data.fare.paymentStatus).toBe('INITIATED');
    } finally {
      global.fetch = originalFetch;
    }
  });
});
