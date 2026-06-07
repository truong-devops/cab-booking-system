process.env.JWT_ACCESS_SECRET = 'test_secret';
process.env.INTERNAL_API_KEY = 'dev-internal-key';

const request = require('supertest');
const jwt = require('jsonwebtoken');

jest.mock('../../src/services/paymentService', () => ({
  createPayment: jest.fn(),
  fetchPayment: jest.fn(),
  fetchPayments: jest.fn(),
  changePaymentStatus: jest.fn(),
  fetchVietQr: jest.fn()
}));

jest.mock('../../src/services/idempotencyService', () => ({
  withIdempotency: jest.fn(),
  pickIdempotencyHeaders: jest.fn(() => ({}))
}));

const app = require('../../src/app');
const paymentService = require('../../src/services/paymentService');
const idempotencyService = require('../../src/services/idempotencyService');

describe('payment routes', () => {
  const authHeader = `Bearer ${jwt.sign({ sub: '10000003', roles: ['user'], scopes: ['payments:write'] }, process.env.JWT_ACCESS_SECRET)}`;
  const adminAuthHeader = `Bearer ${jwt.sign({ sub: '10000001', roles: ['admin'], scopes: ['payments:write'] }, process.env.JWT_ACCESS_SECRET)}`;

  afterEach(() => {
    jest.resetAllMocks();
  });

  beforeEach(() => {
    idempotencyService.pickIdempotencyHeaders.mockReturnValue({});
    idempotencyService.withIdempotency.mockImplementation(async ({ execute, responseHeaders }) => {
      const result = await execute();
      return {
        status: result.responseCode,
        headers: responseHeaders || {},
        body: result.responseBody,
        cached: false
      };
    });
  });

  test('rejects create payment without idempotency key', async () => {
    const response = await request(app).post('/v1/payments').set('Authorization', authHeader).send({ rideId: 'ride_1', amount: 10, currency: 'VND' });

    expect(response.status).toBe(400);
    expect(response.headers['x-trace-id']).toBeTruthy();
    expect(response.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
  });

  test('rejects internal init without x-idempotency-key', async () => {
    const response = await request(app)
      .post('/v1/payments/internal/init')
      .set('x-internal-api-key', 'dev-internal-key')
      .send({ rideId: 'ride_1', amount: 10, currency: 'VND', method: 'CARD', userId: '10000003' });

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('IDEMPOTENCY_KEY_REQUIRED');
  });

  test('creates internal payment with x-idempotency-key', async () => {
    paymentService.createPayment.mockResolvedValueOnce({
      responseCode: 201,
      responseBody: { data: { id: 'pay_internal_1' } }
    });

    const response = await request(app)
      .post('/v1/payments/internal/init')
      .set('x-internal-api-key', 'dev-internal-key')
      .set('x-idempotency-key', 'internal_idem_1')
      .send({ rideId: 'ride_1', amount: 10, currency: 'VND', method: 'CARD', userId: '10000003' });

    expect(response.status).toBe(201);
    expect(response.body.data.id).toBe('pay_internal_1');
    expect(idempotencyService.withIdempotency).toHaveBeenCalledWith(
      expect.objectContaining({
        routeKey: 'payments:internal:init',
        idemKey: 'internal_idem_1'
      })
    );
  });

  test('creates payment with idempotency key', async () => {
    paymentService.createPayment.mockResolvedValueOnce({
      responseCode: 201,
      responseBody: { data: { id: 'pay_1' } }
    });

    const response = await request(app)
      .post('/v1/payments')
      .set('Authorization', authHeader)
      .set('Idempotency-Key', 'idem_1')
      .send({ rideId: 'ride_1', amount: 10, currency: 'VND', method: 'CARD' });

    expect(response.status).toBe(201);
    expect(response.body.data.id).toBe('pay_1');
  });

  test('returns cached response for idempotency key', async () => {
    idempotencyService.withIdempotency.mockResolvedValueOnce({
      status: 201,
      headers: { 'x-trace-id': 'trace_1' },
      body: { data: { id: 'pay_cached' } },
      cached: true
    });

    const response = await request(app)
      .post('/v1/payments')
      .set('Authorization', authHeader)
      .set('Idempotency-Key', 'idem_2')
      .send({ rideId: 'ride_1', amount: 10, currency: 'VND' });

    expect(response.status).toBe(201);
    expect(response.body.data.id).toBe('pay_cached');
    expect(paymentService.createPayment).not.toHaveBeenCalled();
  });

  test('lists payments', async () => {
    paymentService.fetchPayments.mockResolvedValueOnce({ data: [] });
    const response = await request(app).get('/v1/payments').set('Authorization', authHeader);
    expect(response.status).toBe(200);
    expect(Array.isArray(response.body.data)).toBe(true);
  });

  test('rejects update payment status for non-admin', async () => {
    const response = await request(app).patch('/v1/payments/pay_1').set('Authorization', authHeader).send({ status: 'PAID' });

    expect(response.status).toBe(403);
    expect(response.body.error.code).toBe('FORBIDDEN');
  });

  test('updates payment status for admin', async () => {
    paymentService.changePaymentStatus.mockResolvedValueOnce({
      id: 'pay_1',
      status: 'PAID'
    });

    const response = await request(app).patch('/v1/payments/pay_1').set('Authorization', adminAuthHeader).send({ status: 'PAID' });

    expect(response.status).toBe(200);
    expect(response.body.data.id).toBe('pay_1');
  });

  test('gets vietqr codes', async () => {
    paymentService.fetchVietQr.mockResolvedValueOnce({
      paymentId: 'pay_1',
      rideId: 'ride_1',
      amount: '100.00',
      currency: 'VND',
      vietqr: {
        payload: 'payload',
        qrUrl: 'https://example.com/qr',
        reference: 'ref_1',
        expiresAt: new Date().toISOString()
      }
    });

    const response = await request(app).get('/v1/payments/pay_1/vietqr-codes').set('Authorization', authHeader);

    expect(response.status).toBe(200);
    expect(response.body.data.paymentId).toBe('pay_1');
  });
});
