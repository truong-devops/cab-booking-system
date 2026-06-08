const express = require('express');
const crypto = require('crypto');
const { CreateBookingSchema } = require('../schemas/bookingSchemas');
const bookingRepo = require('../repositories/bookingRepo');
const outboxRepo = require('../repositories/outboxRepo');
const { getIdempotencyKey, reserveIdempotencyKey, completeIdempotencyKey } = require('../repositories/idempotencyRepo');
const { withTransaction } = require('../db/pool');
const config = require('../config');
const { getQuote, PricingServiceError } = require('../clients/pricingClient');
const { estimateEta, EtaServiceError } = require('../clients/etaClient');
const { getDriverAvailability, listAvailableDrivers, selectBestDriver } = require('../clients/driverClient');
const { getRideStatusByExternalRideId } = require('../clients/rideClient');
const { recommendDrivers, agentSelectDriver, forecastDemand, logAiFallback } = require('../clients/aiClient');
const { createPayment } = require('../clients/paymentClient');
const { sendNotification } = require('../clients/notificationClient');
const { hashRequest } = require('../utils/idempotency');
const { isEightDigitId, toUser8 } = require('../utils/identity');

const topics = require('../messaging/topics');
const monitoring = require('../monitoring');
const logger = require('../utils/logger');

const router = express.Router();
const PRIVILEGED_ROLES = new Set(['admin', 'service', 'ops']);
const ACTIVE_BOOKING_STATUSES = new Set(['PENDING', 'REQUESTED', 'ACCEPTED', 'CONFIRMED']);
const TERMINAL_RIDE_STATUSES = new Set(['COMPLETED', 'CANCELLED']);
const TRANSIENT_DB_ERROR_CODES = new Set([
  'ETIMEDOUT',
  'ECONNRESET',
  'ECONNREFUSED',
  'EPIPE',
  '57P01',
  '57P02',
  '57P03',
  '53300'
]);

function normalizeUserId(value, { allowCoerce = false } = {}) {
  if (value === undefined || value === null) {
    return null;
  }
  const normalized = String(value).trim();
  if (!normalized) {
    return null;
  }
  if (isEightDigitId(normalized)) {
    return normalized;
  }
  if (allowCoerce) {
    return toUser8(normalized);
  }
  return null;
}

function normalizeEightDigitId(value) {
  return normalizeUserId(value, { allowCoerce: false });
}

function canCoercePrivilegedUserId(req) {
  return Boolean(req.gatewayTrusted) && hasPrivilegedRole(req);
}

function normalizeRoles(req) {
  const roles = Array.isArray(req.user?.roles) ? req.user.roles : [];
  const role = req.user?.role ? [req.user.role] : [];
  return [...roles, ...role].map((r) => String(r || '').toLowerCase()).filter(Boolean);
}

function hasPrivilegedRole(req) {
  return normalizeRoles(req).some((role) => PRIVILEGED_ROLES.has(role));
}

function hasAnyRole(req, allowedRoles) {
  const allowed = new Set((allowedRoles || []).map((r) => String(r || '').toLowerCase()));
  return normalizeRoles(req).some((role) => allowed.has(role));
}

function normalizeStatus(value) {
  return String(value || '').toUpperCase();
}

function isTransientDbOrInfraError(error) {
  const code = String(error?.code || '').toUpperCase();
  if (code && TRANSIENT_DB_ERROR_CODES.has(code)) {
    return true;
  }
  const message = String(error?.message || '').toLowerCase();
  if (!message) {
    return false;
  }
  return (
    message.includes('connection terminated due to connection timeout') ||
    message.includes('connection timeout') ||
    message.includes('timeout acquiring') ||
    message.includes('sorry, too many clients already') ||
    message.includes('terminating connection due to administrator command')
  );
}

function isActiveBookingStatus(value) {
  return ACTIVE_BOOKING_STATUSES.has(normalizeStatus(value));
}

async function releaseStaleActiveBooking({ activeBooking, authorization, traceId, req }) {
  if (!activeBooking || !isActiveBookingStatus(activeBooking.status) || !activeBooking.rideId) {
    return { released: false, activeBooking: activeBooking || null, rideStatus: null };
  }

  const rideStatus = await getRideStatusByExternalRideId({
    externalRideId: activeBooking.rideId,
    authorization,
    traceId
  });

  if (!TERMINAL_RIDE_STATUSES.has(normalizeStatus(rideStatus))) {
    return { released: false, activeBooking, rideStatus };
  }

  const cancelled = await withTransaction(async (client) => {
    const current = await bookingRepo.getByIdForUpdate(client, activeBooking.bookingId);
    if (!current || !isActiveBookingStatus(current.status)) {
      return null;
    }
    return bookingRepo.cancel(client, current.bookingId);
  });

  if (cancelled) {
    logger.withTrace(req).info(
      {
        bookingId: cancelled.bookingId,
        rideExternalId: cancelled.rideId,
        rideStatus
      },
      'released stale active booking after terminal ride status'
    );
  }

  return {
    released: Boolean(cancelled),
    activeBooking: cancelled || activeBooking,
    rideStatus
  };
}

function buildEnvelope({ eventId, type, traceId, payload }) {
  return {
    eventId,
    traceId: traceId || null,
    occurredAt: new Date().toISOString(),
    type,
    version: 1,
    payload
  };
}

function buildOutboxRecord({ eventId, topic, eventType, aggregateId, partitionKey, envelope }) {
  return {
    eventId,
    aggregateType: 'booking',
    aggregateId,
    eventType,
    topic,
    partitionKey,
    payload: envelope,
    occurredAt: envelope.occurredAt,
    maxAttempts: config.outbox.maxAttempts
  };
}

function resolveUserId(req, payload) {
  const allowCoerce = canCoercePrivilegedUserId(req);
  const privilegedRequestedUserIdRaw =
    hasPrivilegedRole(req) && (payload?.user_id || req.header('x-user-id'))
      ? String(payload?.user_id || req.header('x-user-id')).trim()
      : '';
  const privilegedRequestedUserId = normalizeUserId(privilegedRequestedUserIdRaw, { allowCoerce });

  if (privilegedRequestedUserId) {
    return privilegedRequestedUserId;
  }
  const actorUserId = normalizeUserId(req.userId, { allowCoerce });
  if (actorUserId) {
    return actorUserId;
  }
  return null;
}

function hasLatLngTypeIssue(issues) {
  return (issues || []).some((issue) => {
    if (issue?.code !== 'invalid_type') {
      return false;
    }
    const path = (issue.path || []).join('.');
    return (
      path.includes('pickup.lat') ||
      path.includes('pickup.lng') ||
      path.includes('drop.lat') ||
      path.includes('drop.lng') ||
      path.includes('dropoff.lat') ||
      path.includes('dropoff.lng')
    );
  });
}

function normalizeDrop(body) {
  return body.drop || body.dropoff || null;
}

function mapBookingCompat(booking) {
  if (!booking || typeof booking !== 'object') {
    return booking;
  }
  return {
    ...booking,
    booking_id: booking.bookingId || booking.booking_id || null,
    ride_id: booking.rideId || booking.ride_id || null,
    user_id: booking.userId || booking.user_id || null,
    vehicle_type: booking.vehicleType || booking.vehicle_type || null,
    distance_km: booking.distanceKm != null ? booking.distanceKm : booking.distance_km != null ? booking.distance_km : null,
    eta_minutes: booking.etaMinutes != null ? booking.etaMinutes : booking.eta_minutes != null ? booking.eta_minutes : null,
    created_at: booking.createdAt || booking.created_at || null,
    canceled_at: booking.canceledAt || booking.canceled_at || null
  };
}

function mapBookingListCompat(items) {
  return (items || []).map(mapBookingCompat);
}

function mapCreateResponseCompat(body) {
  if (!body || typeof body !== 'object') {
    return body;
  }
  return {
    ...body,
    booking: mapBookingCompat(body.booking)
  };
}

function shouldUseMinimalLoadResponse(req) {
  if (!readBookingLoadFlag('BOOKING_LOAD_MINIMAL_RESPONSE')) {
    return false;
  }
  const hint = String(req.header('x-load-test') || '').toLowerCase();
  return hint === '1' || hint === 'true' || hint === 'yes';
}

function toMinimalBookingResponse(booking) {
  return {
    bookingId: booking.bookingId || booking.booking_id || null,
    rideId: booking.rideId || booking.ride_id || null,
    status: booking.status || null,
    createdAt: booking.createdAt || booking.created_at || new Date().toISOString()
  };
}

function isLoadTestRequest(req) {
  const hint = String(req.header('x-load-test') || '').toLowerCase();
  return hint === '1' || hint === 'true' || hint === 'yes';
}

function readBookingLoadFlag(name) {
  const value = process.env[name];
  const fallback = process.env.NODE_ENV === 'production' ? 'false' : 'true';
  return String(value == null || value === '' ? fallback : value).toLowerCase() === 'true';
}

function isLoadSkipPersistEnabled() {
  return readBookingLoadFlag('BOOKING_LOAD_SKIP_PERSIST');
}

function isLoadSkipListDbEnabled() {
  return readBookingLoadFlag('BOOKING_LOAD_SKIP_LIST_DB');
}

function isLoadSkipActiveCheckEnabled() {
  return readBookingLoadFlag('BOOKING_LOAD_SKIP_ACTIVE_CHECK');
}

function isLoadUltraFastPathEnabled() {
  return readBookingLoadFlag('BOOKING_LOAD_ULTRA_FAST_PATH');
}

function normalizeLatLngPoint(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }

  const lat = Number(value.lat);
  const lng = Number(value.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    return null;
  }

  const normalized = { lat, lng };
  if (typeof value.address === 'string' && value.address.trim()) {
    normalized.address = value.address.trim();
  }
  return normalized;
}

function compactPriceSnapshotForLoad(quote) {
  return {
    quoteId: quote?.quoteId || `quote_load_${Date.now()}`,
    estimatedFare: Number.isFinite(Number(quote?.estimatedFare)) ? Number(quote.estimatedFare) : 0,
    surge: Number.isFinite(Number(quote?.surge)) ? Number(quote.surge) : 1,
    currency: quote?.currency || 'VND'
  };
}

function buildNoDriversPriceSnapshot() {
  return {
    quoteId: null,
    estimatedFare: 0,
    surge: 1,
    currency: 'VND',
    distanceKm: null,
    durationMin: null,
    reason: 'No drivers available'
  };
}

function normalizePaymentMethod(paymentMethod) {
  const method = String(paymentMethod || 'CASH').toUpperCase();
  if (['CASH', 'VIETQR', 'PAYOS'].includes(method)) {
    return method;
  }
  return 'CASH';
}

function shouldDeferCashPaymentInit(paymentMethod, { simulatePaymentTimeout = false } = {}) {
  if (normalizePaymentMethod(paymentMethod) !== 'CASH') {
    return false;
  }
  // Explicit timeout simulation must always exercise real payment init path.
  if (simulatePaymentTimeout) {
    return false;
  }

  const mode = String(process.env.BOOKING_CASH_PAYMENT_INIT_MODE || 'strict')
    .trim()
    .toLowerCase();
  return mode === 'deferred';
}

function resolveAmountFromQuote(quote) {
  const amount = Number(quote?.estimatedFare);
  if (!Number.isFinite(amount) || amount <= 0) {
    return 10000;
  }
  return Math.max(1, Math.round(amount));
}

function toNumberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function haversineKm(from, to) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const lat1 = toNumberOrNull(from?.lat);
  const lng1 = toNumberOrNull(from?.lng);
  const lat2 = toNumberOrNull(to?.lat);
  const lng2 = toNumberOrNull(to?.lng);
  if (lat1 === null || lng1 === null || lat2 === null || lng2 === null) {
    return null;
  }

  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return 6371 * c;
}

function estimateLocalEta({ pickup, dropoff, distanceKm, trafficLevel }) {
  const normalizedDistance =
    Number.isFinite(distanceKm) && Number(distanceKm) >= 0 ? Number(distanceKm) : haversineKm(pickup, dropoff) || 0;
  const normalizedTraffic = Number.isFinite(Number(trafficLevel)) ? Math.max(0, Math.min(1, Number(trafficLevel))) : 0.4;
  const speedKmh = Math.max(8, 30 - normalizedTraffic * 16);
  const etaMinutes = normalizedDistance <= 0 ? 0 : Math.max(1, Math.round((normalizedDistance / speedKmh) * 60));
  return {
    etaMinutes,
    distanceKm: Number(normalizedDistance.toFixed(3))
  };
}

function estimateLocalQuote({ pickup, dropoff, vehicleType, distanceKm, etaMinutes }) {
  const resolvedDistance =
    Number.isFinite(distanceKm) && Number(distanceKm) >= 0 ? Number(distanceKm) : haversineKm(pickup, dropoff) || 0;
  const resolvedEta = Number.isFinite(Number(etaMinutes)) && Number(etaMinutes) >= 0 ? Number(etaMinutes) : 0;
  const baseFare = vehicleType === 'SUV' ? 22000 : 12000;
  const perKmRate = vehicleType === 'SUV' ? 5200 : vehicleType === 'BIKE' ? 2400 : 3800;
  const perMinRate = vehicleType === 'SUV' ? 850 : vehicleType === 'BIKE' ? 350 : 550;
  const surge = 1;
  const subtotal = baseFare + perKmRate * resolvedDistance + perMinRate * resolvedEta;
  const estimatedFare = Math.max(0, Math.round(subtotal * surge));
  return {
    quoteId: `quote_local_${Date.now()}`,
    estimatedFare,
    surge,
    currency: 'VND',
    distanceKm: Number(resolvedDistance.toFixed(3)),
    durationMin: Math.max(0, Math.round(resolvedEta)),
    breakdown: {
      base: baseFare,
      perKm: Number((perKmRate * resolvedDistance).toFixed(2)),
      perMin: Number((perMinRate * resolvedEta).toFixed(2)),
      discount: 0,
      surge: Number(((subtotal * surge) - subtotal).toFixed(2))
    },
    expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString()
  };
}

function shouldUseLocalEstimatePath({ authorization, fastPathHint }) {
  if (String(process.env.BOOKING_FORCE_REMOTE_ESTIMATES || 'false') === 'true') {
    return false;
  }
  if (String(process.env.BOOKING_FORCE_LOCAL_ESTIMATES || 'false') === 'true') {
    return true;
  }
  const hint = String(fastPathHint || '').toLowerCase();
  if (hint === '1' || hint === 'true' || hint === 'yes' || hint === 'load') {
    return true;
  }
  return false;
}

async function resolveQuoteAndEta({
  pickup,
  dropoff,
  vehicleType,
  distanceKm,
  trafficLevel,
  simulatePricingTimeout,
  authorization,
  fastPathHint
}) {
  if (shouldUseLocalEstimatePath({ authorization, fastPathHint })) {
    const eta = estimateLocalEta({
      pickup,
      dropoff,
      distanceKm,
      trafficLevel
    });
    const quote = estimateLocalQuote({
      pickup,
      dropoff,
      vehicleType,
      distanceKm: eta.distanceKm,
      etaMinutes: eta.etaMinutes
    });
    return { quote, eta };
  }

  const [quote, eta] = await Promise.all([
    getQuote({
      pickup,
      dropoff,
      vehicleType,
      simulateTimeout: simulatePricingTimeout
    }),
    estimateEta({
      pickup,
      drop: dropoff,
      distanceKm,
      trafficLevel
    })
  ]);

  return { quote, eta };
}

async function buildAiDriverDecision({ pickup, vehicleType, authorization, traceId, allowVehicleTypeFallback = true }) {
  let drivers = await listAvailableDrivers({
    pickup,
    vehicleType,
    authorization,
    traceId,
    limit: Number(process.env.AI_DRIVER_CANDIDATE_LIMIT || 5)
  });

  // Fallback for partially onboarded drivers that are ONLINE but missing vehicle metadata.
  if (!drivers.length && vehicleType && allowVehicleTypeFallback) {
    drivers = await listAvailableDrivers({
      pickup,
      vehicleType: null,
      authorization,
      traceId,
      limit: Number(process.env.AI_DRIVER_CANDIDATE_LIMIT || 5)
    });
  }

  const normalizedDrivers = (drivers || []).filter((driver) => normalizeEightDigitId(driver.driverId || driver.driver_id));
  const selected = selectBestDriver(normalizedDrivers);
  return {
    availableDrivers: normalizedDrivers,
    selectedDriver: selected
  };
}

function mapDriversToAiCandidates(drivers) {
  return (drivers || []).map((driver) => ({
    driver_id: normalizeEightDigitId(driver.driverId || driver.driver_id),
    distance_m: Number(driver.distanceMeters ?? driver.distance_m ?? Number.MAX_SAFE_INTEGER),
    rating: Number(driver.rating ?? 4.5),
    eta_min: Number(driver.etaMinutes ?? driver.eta_min ?? 8),
    price_score: Number(driver.priceScore ?? driver.price_score ?? 0.5),
    online: true,
    vehicle_type: driver.vehicle?.type || driver.vehicle_type || null
  }));
}

function mapAiDriverToLegacy(driver) {
  if (!driver || typeof driver !== 'object') {
    return driver;
  }
  return {
    ...driver,
    driverId: normalizeEightDigitId(driver.driverId || driver.driver_id),
    distanceMeters: driver.distanceMeters != null ? driver.distanceMeters : driver.distance_m != null ? Number(driver.distance_m) : null
  };
}

function mapAiDriversToLegacy(drivers) {
  return (drivers || []).map(mapAiDriverToLegacy);
}

async function runBookingIntegrationFlow({ booking, quote, paymentMethod, authorization, traceId, simulatePaymentTimeout = false }) {
  const integrations = {
    payment: null,
    notification: null,
    flow: 'skipped'
  };
  const normalizedPaymentMethod = normalizePaymentMethod(paymentMethod);
  const deferCashPaymentInit = shouldDeferCashPaymentInit(normalizedPaymentMethod, {
    simulatePaymentTimeout
  });

  const paymentResult = deferCashPaymentInit
    ? {
      ok: true,
      statusCode: 202,
      data: {
        status: 'DEFERRED',
        method: normalizedPaymentMethod,
        deferred: true,
        reason: 'CASH_COLLECT_ON_RIDE_COMPLETION'
      }
    }
    : await createPayment({
      rideId: booking.rideId,
      amount: resolveAmountFromQuote(quote),
      currency: quote?.currency || 'VND',
      method: normalizedPaymentMethod,
      userId: booking.userId,
      authorization,
      traceId,
      idempotencyKey: `booking-payment-${booking.bookingId}`,
      simulateTimeout: simulatePaymentTimeout
    });
  integrations.payment = paymentResult;

  const notificationMessage = paymentResult.ok && paymentResult?.data?.deferred
    ? `Booking ${booking.bookingId} created. Cash payment is deferred until ride completion`
    : paymentResult.ok
      ? `Booking ${booking.bookingId} created. Payment initialized`
    : `Booking ${booking.bookingId} created. Payment initialization pending`;

  const notificationResult = await sendNotification({
    userId: booking.userId,
    title: 'Booking Created',
    message: notificationMessage,
    sourceService: 'booking-service',
    sourceAction: 'BOOKING_PAYMENT_INIT',
    authorization,
    traceId
  });
  integrations.notification = notificationResult;

  integrations.flow = paymentResult.ok && notificationResult.ok ? 'success' : 'partial';

  return integrations;
}

async function compensateBookingAfterPaymentFailure({ bookingId, traceId, reason }) {
  return withTransaction(async (client) => {
    const existing = await bookingRepo.getByIdForUpdate(client, bookingId);
    if (!existing) {
      return null;
    }

    const currentStatus = String(existing.status || '').toUpperCase();
    if (currentStatus === 'CANCELLED') {
      return {
        booking: existing,
        publishedEvent: null,
        alreadyCancelled: true
      };
    }

    const cancelled = await bookingRepo.cancel(client, bookingId);
    const eventId = crypto.randomUUID();
    const envelope = buildEnvelope({
      eventId,
      traceId,
      type: 'RideCancelled',
      payload: {
        rideId: cancelled.rideId,
        reason: reason || 'PAYMENT_INITIALIZATION_FAILED',
        timestamp: new Date().toISOString()
      }
    });

    await outboxRepo.insertOutboxEvent(
      client,
      buildOutboxRecord({
        eventId,
        topic: topics.RideCancelled,
        eventType: 'RideCancelled',
        aggregateId: cancelled.bookingId,
        partitionKey: cancelled.rideId,
        envelope
      })
    );

    return {
      booking: cancelled,
      alreadyCancelled: false,
      publishedEvent: {
        topic: topics.RideCancelled,
        eventId,
        queued: true
      }
    };
  });
}

router.get('/', async (req, res, next) => {
  try {
    const allowCoerce = canCoercePrivilegedUserId(req);
    const actorUserId = normalizeUserId(req.userId, { allowCoerce });
    const rawRequestedUserId = req.query.user_id ? String(req.query.user_id).trim() : null;
    const requestedUserId = normalizeUserId(rawRequestedUserId, { allowCoerce });
    if (rawRequestedUserId && !requestedUserId) {
      return res.status(400).json({ error: 'user_id must be an 8-digit ID' });
    }
    const scopedRequestedUserId = requestedUserId || actorUserId || null;
    const loadTestRequest = isLoadTestRequest(req);

    if (loadTestRequest && hasPrivilegedRole(req) && scopedRequestedUserId && isLoadSkipListDbEnabled()) {
      return res.json({ data: [] });
    }

    if (scopedRequestedUserId && actorUserId && scopedRequestedUserId !== actorUserId && !hasPrivilegedRole(req)) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const effectiveUserId = hasPrivilegedRole(req) ? scopedRequestedUserId : actorUserId;
    const requestedLimit = Number(req.query.limit);
    const listOptions = effectiveUserId
      ? {
        userId: String(effectiveUserId),
        limit: Number.isFinite(requestedLimit) && requestedLimit > 0 ? Math.min(200, Math.floor(requestedLimit)) : 50
      }
      : {};
    const items = await bookingRepo.list(listOptions);
    return res.json({ data: mapBookingListCompat(items) });
  } catch (error) {
    return next(error);
  }
});

router.get('/:id', async (req, res, next) => {
  try {
    const booking = await bookingRepo.getById(req.params.id);
    if (!booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }
    if (!hasPrivilegedRole(req) && booking.userId && req.userId && booking.userId !== req.userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    return res.json({ data: mapBookingCompat(booking) });
  } catch (error) {
    return next(error);
  }
});

router.post('/', async (req, res) => {
  let currentUserId = null;
  try {
    const allowCoerce = canCoercePrivilegedUserId(req);
    const loadTestRequest = isLoadTestRequest(req);
    const normalizedBody = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? { ...req.body } : {};
    if (allowCoerce && normalizedBody.user_id) {
      normalizedBody.user_id = normalizeUserId(normalizedBody.user_id, { allowCoerce: true }) || normalizedBody.user_id;
    }
    const authorization = req.header('authorization') || '';
    const bookingFastPathHint = req.header('x-booking-fast-path') || req.header('x-load-test') || '';
    const bookingFastPathEnabled = shouldUseLocalEstimatePath({ authorization, fastPathHint: bookingFastPathHint });
    const ultraFastLoadPath =
      loadTestRequest &&
      hasPrivilegedRole(req) &&
      bookingFastPathEnabled &&
      isLoadUltraFastPathEnabled() &&
      !req.header('idempotency-key');

    if (ultraFastLoadPath) {
      const pickup = normalizeLatLngPoint(normalizedBody.pickup);
      if (!pickup) {
        return res.status(400).json({ error: 'pickup is required' });
      }
      const drop = normalizeLatLngPoint(normalizeDrop(normalizedBody));
      if (!drop) {
        return res.status(400).json({ error: 'drop is required' });
      }

      const userId = resolveUserId(req, { user_id: normalizedBody.user_id });
      if (!userId) {
        return res.status(401).json({ error: 'Unauthorized' });
      }
      currentUserId = userId;

      const rawVehicleType = String(normalizedBody.vehicleType || normalizedBody.vehicle_type || 'CAR').toUpperCase();
      const vehicleType = ['BIKE', 'CAR', 'SUV'].includes(rawVehicleType) ? rawVehicleType : 'CAR';
      const resolvedDistanceKm = Number.isFinite(Number(normalizedBody.distance_km)) ? Number(normalizedBody.distance_km) : null;

      const bookingId = `bk_${crypto.randomUUID()}`;
      const rideId = `ride_${crypto.randomUUID()}`;
      const createdAt = new Date().toISOString();
      const fastBooking = {
        bookingId,
        rideId,
        userId,
        pickup,
        dropoff: drop,
        vehicleType,
        distanceKm: resolvedDistanceKm,
        etaMinutes: null,
        priceSnapshot: null,
        status: 'REQUESTED',
        createdAt
      };

      const skipPersistInLoadMode = isLoadSkipPersistEnabled();
      if (!skipPersistInLoadMode) {
        await bookingRepo.createFast(null, fastBooking);
      }

      return res.status(201).json({
        booking: shouldUseMinimalLoadResponse(req) ? toMinimalBookingResponse(fastBooking) : mapBookingCompat(fastBooking),
        publishedEvent: {
          topic: topics.RideCreated,
          eventId: null,
          queued: false
        },
        additionalEvents: []
      });
    }

    if (!normalizedBody?.pickup) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'pickup_required'
      });
      return res.status(400).json({
        error: 'pickup is required'
      });
    }

    const drop = normalizeDrop(normalizedBody);
    if (!drop) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'drop_required'
      });
      return res.status(400).json({
        error: 'drop is required'
      });
    }
    if (normalizedBody?.payment_method && !['CASH', 'VIETQR', 'PAYOS'].includes(String(normalizedBody.payment_method).toUpperCase())) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'invalid_payment_method'
      });
      return res.status(400).json({
        error: 'Invalid payment method'
      });
    }

    const parsed = CreateBookingSchema.safeParse({
      ...normalizedBody,
      drop
    });
    if (!parsed.success) {
      const schemaIssues = parsed.error.issues || [];
      const statusCode = hasLatLngTypeIssue(schemaIssues) ? 422 : 400;
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'validation_error'
      });
      return res.status(statusCode).json({
        error: statusCode === 422 ? 'Validation error from schema' : 'Invalid payload',
        details: parsed.error.flatten()
      });
    }

    const { pickup, vehicleType, distance_km, traffic_level } = parsed.data;
    if (parsed.data.user_id && req.userId && parsed.data.user_id !== req.userId && !hasPrivilegedRole(req)) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'forbidden_user_scope'
      });
      return res.status(403).json({ error: 'Forbidden' });
    }
    const normalizedDrop = parsed.data.drop || parsed.data.dropoff;
    const userId = resolveUserId(req, parsed.data);
    if (!userId) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    currentUserId = userId;
    const idempotencyKey = req.header('idempotency-key') || null;
    const routeKey = '/v1/bookings';
    const requestPayload = {
      pickup,
      drop: normalizedDrop,
      vehicleType,
      distance_km,
      traffic_level
    };
    const requestHash = idempotencyKey ? hashRequest(req.method, routeKey, requestPayload) : null;
    const traceId = req.traceId || req.header('x-trace-id');
    const skipActiveBookingCheckInLoad =
      loadTestRequest && hasPrivilegedRole(req) && bookingFastPathEnabled && isLoadSkipActiveCheckEnabled();

    if (idempotencyKey && typeof getIdempotencyKey === 'function') {
      const existingIdempotency = await getIdempotencyKey(null, {
        routeKey,
        userId,
        idemKey: idempotencyKey
      });

      if (existingIdempotency) {
        if (existingIdempotency.requestHash !== requestHash) {
          return res.status(409).json({
            error: 'Idempotency-Key payload mismatch',
            code: 'IDEMPOTENCY_KEY_CONFLICT'
          });
        }

        if (existingIdempotency.responseBody) {
          const replayBody = mapCreateResponseCompat(existingIdempotency.responseBody);
          if (replayBody?.booking?.priceSnapshot) {
            const surge = Number(replayBody.booking.priceSnapshot.surge);
            replayBody.booking.priceSnapshot.surge = Number.isFinite(surge) && surge >= 1 ? surge : 1;
          }
          return res.status(existingIdempotency.responseCode || 200).json(replayBody);
        }

        return res.status(409).json({
          error: 'Idempotency-Key is being processed',
          code: 'IDEMPOTENCY_IN_PROGRESS'
        });
      }
    }

    if (!skipActiveBookingCheckInLoad) {
      const activeBooking = await bookingRepo.findActiveByUser(userId);
      if (activeBooking) {
        const released = await releaseStaleActiveBooking({
          activeBooking,
          authorization,
          traceId,
          req
        });
        if (!released.released) {
          return res.status(409).json({
            error: 'An active booking already exists for this user',
            code: 'ACTIVE_BOOKING_EXISTS',
            booking: mapBookingCompat(released.activeBooking)
          });
        }
      }
    }

    const minimalLoadResponse = shouldUseMinimalLoadResponse(req);
    const simulatePricingTimeout = normalizedBody?.simulate_pricing_timeout === true || normalizedBody?.simulatePricingTimeout === true;
    const simulatePaymentTimeout = normalizedBody?.simulate_payment_timeout === true || normalizedBody?.simulatePaymentTimeout === true;
    const simulateTxFailureAfterInsert =
      normalizedBody?.simulate_tx_failure_after_insert === true || normalizedBody?.simulateTransactionFailureAfterInsert === true;

    let noDriversAvailable = false;
    let noDriversReason = null;
    let precomputedAiDecision = null;
    if (!bookingFastPathEnabled) {
      const availability = await getDriverAvailability({
        pickup,
        vehicleType,
        authorization,
        traceId
      });
      noDriversAvailable = availability.checked && !availability.available;
    }

    const { quote, eta } = await resolveQuoteAndEta({
      pickup,
      dropoff: normalizedDrop,
      vehicleType,
      distanceKm: distance_km,
      trafficLevel: traffic_level,
      simulatePricingTimeout,
      authorization,
      fastPathHint: bookingFastPathHint
    });
    if (!bookingFastPathEnabled) {
      precomputedAiDecision = await buildAiDriverDecision({
        pickup,
        vehicleType,
        authorization,
        traceId,
        allowVehicleTypeFallback: false
      });
    }
    const hasAiSelectedDriver = Boolean(precomputedAiDecision?.selectedDriver);
    const hasAiAvailableDrivers =
      Array.isArray(precomputedAiDecision?.availableDrivers) && precomputedAiDecision.availableDrivers.length > 0;
    const noMatchedDrivers = !hasAiSelectedDriver && !hasAiAvailableDrivers;
    const noDriversResolved = !bookingFastPathEnabled && (noDriversAvailable || noMatchedDrivers);
    if (!bookingFastPathEnabled && noDriversResolved) {
      if (noDriversAvailable) {
        noDriversReason = 'NO_MATCHING_DRIVER_FOR_VEHICLE_TYPE';
      } else {
        noDriversReason = 'NO_AVAILABLE_DRIVER';
      }
    }
    const initialBookingStatus = noDriversResolved ? 'PENDING' : 'REQUESTED';

    const resolvedDistanceKm = Number.isFinite(distance_km)
      ? distance_km
      : Number.isFinite(eta.distanceKm)
        ? eta.distanceKm
        : Number.isFinite(Number(quote.distanceKm))
          ? Number(quote.distanceKm)
          : null;
    const persistedQuote = loadTestRequest ? compactPriceSnapshotForLoad(quote) : quote;
    let result = null;
    if (bookingFastPathEnabled && !idempotencyKey && !simulateTxFailureAfterInsert) {
      const bookingId = `bk_${crypto.randomUUID()}`;
      const rideId = `ride_${crypto.randomUUID()}`;
      const createdAt = new Date().toISOString();
      const fastBooking = {
        bookingId,
        rideId,
        userId,
        pickup,
        dropoff: normalizedDrop,
        vehicleType,
        distanceKm: resolvedDistanceKm,
        etaMinutes: eta.etaMinutes,
        priceSnapshot: persistedQuote,
        status: initialBookingStatus,
        createdAt
      };
      const skipPersistInLoadMode = loadTestRequest && hasPrivilegedRole(req) && isLoadSkipPersistEnabled();
      if (!skipPersistInLoadMode) {
        await bookingRepo.createFast(null, fastBooking);
      }
      result = {
        replay: false,
        responseCode: 201,
        responseBody: {
          booking: minimalLoadResponse ? toMinimalBookingResponse(fastBooking) : mapBookingCompat(fastBooking),
          publishedEvent: {
            topic: topics.RideCreated,
            eventId: null,
            queued: false
          },
          additionalEvents: []
        }
      };
    } else {
      result = await withTransaction(async (client) => {
        if (idempotencyKey) {
          const reservation = await reserveIdempotencyKey(client, {
            routeKey,
            userId,
            idemKey: idempotencyKey,
            requestHash
          });

          if (reservation.state === 'conflict') {
            const error = new Error('Idempotency-Key payload mismatch');
            error.statusCode = 409;
            error.code = 'IDEMPOTENCY_KEY_CONFLICT';
            throw error;
          }
          if (reservation.state === 'in_progress') {
            const error = new Error('Idempotency-Key is being processed');
            error.statusCode = 409;
            error.code = 'IDEMPOTENCY_IN_PROGRESS';
            throw error;
          }
          if (reservation.state === 'replay' && reservation.record) {
            return {
              replay: true,
              responseCode: reservation.record.responseCode || 200,
              responseBody: reservation.record.responseBody
            };
          }
        }

        const bookingId = `bk_${crypto.randomUUID()}`;
        const rideId = `ride_${crypto.randomUUID()}`;
        const createdAt = new Date().toISOString();

        const created = await bookingRepo.create(client, {
          bookingId,
          rideId,
          userId,
          pickup,
          dropoff: normalizedDrop,
          vehicleType,
          distanceKm: resolvedDistanceKm,
          etaMinutes: eta.etaMinutes,
          priceSnapshot: persistedQuote,
          status: initialBookingStatus,
          createdAt
        });

        if (simulateTxFailureAfterInsert) {
          const error = new Error('Simulated transaction failure after booking insert');
          error.code = 'SIMULATED_TX_FAILURE';
          throw error;
        }

        let responseBody = null;
        if (bookingFastPathEnabled) {
          responseBody = {
            booking: minimalLoadResponse ? toMinimalBookingResponse(created) : mapBookingCompat(created),
            publishedEvent: {
              topic: topics.RideCreated,
              eventId: null,
              queued: false
            },
            additionalEvents: []
          };
        } else {
          const rideCreatedEventId = crypto.randomUUID();
          const rideRequestedEventId = crypto.randomUUID();

	          const rideCreatedEnvelope = buildEnvelope({
	            eventId: rideCreatedEventId,
	            traceId,
	            type: 'RideCreated',
	            payload: {
	              rideId,
	              bookingId,
	              riderId: userId,
	              pickup: {
	                lat: pickup.lat,
	                lng: pickup.lng,
	                address: typeof pickup.address === 'string' ? pickup.address : undefined
	              },
	              dropoff: {
	                lat: normalizedDrop.lat,
	                lng: normalizedDrop.lng,
	                address: typeof normalizedDrop.address === 'string' ? normalizedDrop.address : undefined
	              },
	              pricing: Number.isFinite(Number(persistedQuote?.estimatedFare))
	                ? {
	                    estimatedFare: Math.round(Number(persistedQuote.estimatedFare)),
	                    currency: String(persistedQuote?.currency || 'VND').toUpperCase()
	                  }
	                : undefined,
	              vehicleType,
	              timestamp: createdAt
	            }
	          });

          await outboxRepo.insertOutboxEvent(
            client,
            buildOutboxRecord({
              eventId: rideCreatedEventId,
              topic: topics.RideCreated,
              eventType: 'RideCreated',
              aggregateId: bookingId,
              partitionKey: rideId,
              envelope: rideCreatedEnvelope
            })
          );

          const rideRequestedEnvelope = buildEnvelope({
            eventId: rideRequestedEventId,
            traceId,
            type: 'RideRequested',
            payload: {
              event_type: 'ride_requested',
              ride_id: rideId,
              booking_id: bookingId,
              user_id: userId,
              pickup: { lat: pickup.lat, lng: pickup.lng },
              drop: {
                lat: normalizedDrop.lat,
                lng: normalizedDrop.lng
              },
              distance_km: resolvedDistanceKm,
              eta_minutes: eta.etaMinutes,
              timestamp: createdAt
            }
          });

          await outboxRepo.insertOutboxEvent(
            client,
            buildOutboxRecord({
              eventId: rideRequestedEventId,
              topic: topics.RideEvents,
              eventType: 'RideRequested',
              aggregateId: bookingId,
              partitionKey: rideId,
              envelope: rideRequestedEnvelope
            })
          );

          responseBody = {
            booking: mapBookingCompat(created),
            publishedEvent: {
              topic: topics.RideCreated,
              eventId: rideCreatedEventId,
              queued: true
            },
            additionalEvents: [
              {
                topic: topics.RideEvents,
                eventId: rideRequestedEventId,
                eventType: 'ride_requested',
                queued: true
              }
            ]
          };
        }

        if (idempotencyKey) {
          await completeIdempotencyKey(client, {
            routeKey,
            userId,
            idemKey: idempotencyKey,
            responseCode: 201,
            responseBody
          });
        }

        return {
          replay: false,
          responseCode: 201,
          responseBody
        };
      });
    }

    if (!loadTestRequest) {
      monitoring.recordBookingStatus('created', 'success', {
        vehicle_type: vehicleType
      });
    }

    const responsePayload = mapCreateResponseCompat(result.responseBody);
    if (responsePayload?.booking?.priceSnapshot) {
      const surge = Number(responsePayload.booking.priceSnapshot.surge);
      responsePayload.booking.priceSnapshot.surge = Number.isFinite(surge) && surge >= 1 ? surge : 1;
    }

    if (!result.replay && responsePayload?.booking && !bookingFastPathEnabled) {
      const aiDecision = precomputedAiDecision || (await buildAiDriverDecision({
        pickup,
        vehicleType,
        authorization,
        traceId,
        allowVehicleTypeFallback: false
      }));
      responsePayload.ai_driver_decision = {
        available_drivers: aiDecision.availableDrivers,
        selected_driver: aiDecision.selectedDriver
      };

      const hasSelectedDriver = Boolean(aiDecision?.selectedDriver);
      const hasAvailableDrivers = Array.isArray(aiDecision?.availableDrivers) && aiDecision.availableDrivers.length > 0;
      if (noDriversResolved && !hasSelectedDriver && !hasAvailableDrivers) {
        responsePayload.message = 'No drivers available';
      }
      if (noDriversResolved && noDriversReason) {
        responsePayload.no_drivers_reason = noDriversReason;
      }

      if (parsed.data.payment_method) {
        responsePayload.integration_flow = await runBookingIntegrationFlow({
          booking: responsePayload.booking,
          quote,
          paymentMethod: parsed.data.payment_method,
          authorization,
          traceId,
          simulatePaymentTimeout
        });

        if (responsePayload.integration_flow?.payment?.ok === false) {
          const compensation = await compensateBookingAfterPaymentFailure({
            bookingId: responsePayload.booking.bookingId,
            traceId,
            reason: 'PAYMENT_INITIALIZATION_FAILED'
          });
          if (compensation?.booking) {
            responsePayload.booking = mapBookingCompat(compensation.booking);
          }
          responsePayload.integration_flow.compensation = {
            applied: Boolean(compensation?.booking),
            booking_status: compensation?.booking?.status || null,
            published_event: compensation?.publishedEvent || null
          };
        }
      }
    }

    return res.status(result.responseCode).json(responsePayload);
  } catch (e) {
    if (e instanceof PricingServiceError) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'pricing_unavailable'
      });
      logger.withTrace(req).error(
        {
          err: {
            message: e.message,
            code: e.code,
            cause: e.cause?.message || null
          }
        },
        'failed to create booking due to pricing dependency'
      );
      return res.status(e.statusCode).json({
        error: e.message,
        code: e.code
      });
    }
    if (e instanceof EtaServiceError) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'eta_unavailable'
      });
      logger.withTrace(req).error(
        {
          err: {
            message: e.message,
            code: e.code,
            cause: e.cause?.message || null
          }
        },
        'failed to create booking due to eta dependency'
      );
      return res.status(e.statusCode).json({
        error: e.message,
        code: e.code
      });
    }
    if (e?.code === '23505') {
      const constraint = String(e?.constraint || '');
      if (constraint === 'bookings_one_active_per_user_idx') {
        let activeBooking = null;
        let releasedStaleBooking = false;
        const traceId = req.traceId || req.header('x-trace-id');
        const authorization = req.header('authorization') || '';
        if (currentUserId) {
          try {
            activeBooking = await bookingRepo.findActiveByUser(currentUserId);
            if (activeBooking) {
              const released = await releaseStaleActiveBooking({
                activeBooking,
                authorization,
                traceId,
                req
              });
              if (released.released) {
                activeBooking = null;
                releasedStaleBooking = true;
              }
            }
          } catch (lookupErr) {
            logger.withTrace(req).warn(
              {
                err: {
                  message: lookupErr?.message || 'failed to lookup active booking',
                  code: lookupErr?.code || 'UNKNOWN'
                }
              },
              'failed to lookup active booking after unique-constraint conflict'
            );
          }
        }
        if (releasedStaleBooking) {
          return res.status(409).json({
            error: 'A stale active booking was released. Please retry booking creation.',
            code: 'ACTIVE_BOOKING_RELEASED_RETRY',
            booking: null
          });
        }
        return res.status(409).json({
          error: 'An active booking already exists for this user',
          code: 'ACTIVE_BOOKING_EXISTS',
          booking: activeBooking ? mapBookingCompat(activeBooking) : null
        });
      }
      return res.status(409).json({
        error: 'Duplicate booking conflict',
        code: 'BOOKING_CONFLICT'
      });
    }
    if (e?.statusCode && e?.code) {
      return res.status(e.statusCode).json({
        error: e.message,
        code: e.code
      });
    }
    if (isTransientDbOrInfraError(e)) {
      monitoring.recordBookingStatus('created', 'error', {
        reason: 'service_busy'
      });
      logger.withTrace(req).warn(
        {
          err: {
            message: e.message,
            code: e.code || 'UNKNOWN'
          }
        },
        'booking create hit transient infra/db error; returning service busy'
      );
      return res.status(429).json({
        error: 'Service busy, please retry',
        code: 'SERVICE_BUSY'
      });
    }

    monitoring.recordBookingStatus('created', 'error');
    logger.withTrace(req).error(
      {
        err: {
          message: e.message,
          code: e.code || 'UNKNOWN'
        }
      },
      'failed to create booking'
    );
    return res.status(500).json({ error: e.message });
  }
});

router.post('/ai/select-driver', async (req, res) => {
  try {
    const pickup = req.body?.pickup || null;
    const vehicleType = req.body?.vehicleType || req.body?.vehicle_type || 'CAR';
    if (!pickup || !Number.isFinite(Number(pickup.lat)) || !Number.isFinite(Number(pickup.lng))) {
      return res.status(400).json({
        error: 'pickup.lat and pickup.lng are required'
      });
    }

    const traceId = req.traceId || req.header('x-trace-id');
    const authorization = req.header('authorization') || '';
    const localDecision = await buildAiDriverDecision({
      pickup,
      vehicleType,
      authorization,
      traceId
    });
    const aiCandidates = mapDriversToAiCandidates(localDecision.availableDrivers);
    let agentDecision = null;
    try {
      agentDecision = await agentSelectDriver({
        pickup,
        drop: req.body?.drop || null,
        vehicleType,
        candidates: aiCandidates,
        context: req.body?.context || {
          objective: req.body?.objective || 'auto'
        },
        simulateToolError: req.body?.simulate_tool_error === true,
        simulateModelError: req.body?.simulate_model_error === true,
        authorization,
        traceId
      });
    } catch (error) {
      logAiFallback(req, error?.cause?.code || error?.code || error?.message);
    }

    let aiDecision = null;
    if (!agentDecision) {
      try {
        aiDecision = await recommendDrivers({
          pickup,
          vehicleType,
          candidates: aiCandidates,
          authorization,
          traceId
        });
      } catch (error) {
        logAiFallback(req, error?.cause?.code || error?.code || error?.message);
      }
    }

    const selectedDriver = agentDecision?.selected_driver
      ? mapAiDriverToLegacy(agentDecision.selected_driver)
      : aiDecision?.selected_driver
        ? mapAiDriverToLegacy(aiDecision.selected_driver)
        : localDecision.selectedDriver;
    const availableDrivers = agentDecision?.top_3?.length
      ? mapAiDriversToLegacy(agentDecision.top_3)
      : aiDecision?.top_3?.length
        ? mapAiDriversToLegacy(aiDecision.top_3)
        : localDecision.availableDrivers;
    const decisionLog = agentDecision?.decision_log || aiDecision?.decision_log || null;

    return res.json({
      data: {
        pickup,
        vehicle_type: vehicleType,
        available_drivers: availableDrivers,
        selected_driver: selectedDriver,
        decision_valid: Boolean(selectedDriver),
        decision_log: decisionLog,
        strategy: agentDecision?.strategy || null,
        tool_calls: agentDecision?.tool_calls || [],
        retry_count: Number(agentDecision?.retry_count || 0),
        model_version: agentDecision?.model_version || aiDecision?.model_version || 'local-rule',
        latency_ms: Number(agentDecision?.latency_ms || aiDecision?.latency_ms || 0),
        fallback_used: Boolean(agentDecision?.fallback_used ?? aiDecision?.fallback_used ?? true)
      }
    });
  } catch (error) {
    logger.withTrace(req).error({ err: { message: error.message, code: error.code || 'UNKNOWN' } }, 'failed to select driver with ai decision');
    return res.status(500).json({ error: error.message });
  }
});

router.get('/:id/mcp-context', async (req, res) => {
  try {
    const booking = await bookingRepo.getById(req.params.id);
    if (!booking) {
      return res.status(404).json({ error: 'Booking not found' });
    }
    if (!hasPrivilegedRole(req) && booking.userId && req.userId && booking.userId !== req.userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const traceId = req.traceId || req.header('x-trace-id');
    const authorization = req.header('authorization') || '';
    const trafficLevel = Number.isFinite(Number(req.query.traffic_level)) ? Math.max(0, Math.min(1, Number(req.query.traffic_level))) : 0.7;
    const demandIndex = Number.isFinite(Number(req.query.demand_index)) ? Math.max(0, Number(req.query.demand_index)) : 1.5;
    const supplyIndex = Number.isFinite(Number(req.query.supply_index)) ? Math.max(0, Number(req.query.supply_index)) : 0.8;

    const [eta, quote, driverDecision] = await Promise.all([
      estimateEta({
        pickup: booking.pickup,
        drop: booking.dropoff,
        distanceKm: booking.distanceKm,
        trafficLevel
      }),
      getQuote({
        pickup: booking.pickup,
        dropoff: booking.dropoff,
        vehicleType: booking.vehicleType
      }),
      buildAiDriverDecision({
        pickup: booking.pickup,
        vehicleType: booking.vehicleType,
        authorization,
        traceId
      })
    ]);

    const aiCandidates = mapDriversToAiCandidates(driverDecision.availableDrivers);
    let agentDecision = null;
    let aiRecommendation = null;
    let aiForecast = null;
    try {
      [agentDecision, aiForecast] = await Promise.all([
        agentSelectDriver({
          pickup: booking.pickup,
          drop: booking.dropoff,
          vehicleType: booking.vehicleType,
          candidates: aiCandidates,
          context: {
            objective: 'auto',
            max_eta_min: Number(req.query.max_eta_min || 30),
            budget_weight: Number(req.query.budget_weight || 0.5),
            latency_budget_ms: Number(req.query.latency_budget_ms || 200),
            demand_index: demandIndex,
            traffic_level: trafficLevel
          },
          authorization,
          traceId
        }),
        forecastDemand({
          zoneId: String(req.query.zone_id || 'HCM_DEFAULT'),
          horizonMin: Number(req.query.horizon_min || 30),
          timestamp: req.query.timestamp || new Date().toISOString(),
          authorization,
          traceId
        })
      ]);
    } catch (error) {
      logAiFallback(req, error?.cause?.code || error?.code || error?.message);
    }
    if (!agentDecision) {
      try {
        aiRecommendation = await recommendDrivers({
          pickup: booking.pickup,
          vehicleType: booking.vehicleType,
          candidates: aiCandidates,
          authorization,
          traceId
        });
      } catch (error) {
        logAiFallback(req, error?.cause?.code || error?.code || error?.message);
      }
    }

    return res.json({
      data: {
        ride_id: booking.rideId,
        pickup: booking.pickup,
        drop: booking.dropoff,
        available_drivers: agentDecision?.top_3?.length
          ? mapAiDriversToLegacy(agentDecision.top_3)
          : aiRecommendation?.top_3?.length
            ? mapAiDriversToLegacy(aiRecommendation.top_3)
            : driverDecision.availableDrivers,
        selected_driver: agentDecision?.selected_driver
          ? mapAiDriverToLegacy(agentDecision.selected_driver)
          : aiRecommendation?.selected_driver
            ? mapAiDriverToLegacy(aiRecommendation.selected_driver)
            : driverDecision.selectedDriver,
        agent_strategy: agentDecision?.strategy || null,
        agent_tool_calls: agentDecision?.tool_calls || [],
        agent_decision_log: agentDecision?.decision_log || null,
        traffic_level: trafficLevel,
        demand_index: demandIndex,
        supply_index: supplyIndex,
        eta_minutes: eta.etaMinutes,
        pricing: {
          price: Number(quote.estimatedFare || 0),
          surge: Number(quote.surge || 1),
          currency: quote.currency || 'VND'
        },
        forecast: aiForecast
          ? {
              zone_id: aiForecast.zone_id,
              horizon_min: aiForecast.horizon_min,
              predicted_demand_index: aiForecast.predicted_demand_index,
              predicted_supply_index: aiForecast.predicted_supply_index,
              confidence: aiForecast.confidence,
              model_version: aiForecast.model_version,
              fallback_used: Boolean(aiForecast.fallback_used),
              latency_ms: Number(aiForecast.latency_ms || 0)
            }
          : null,
        permission_ok: true
      }
    });
  } catch (error) {
    logger.withTrace(req).error({ err: { message: error.message, code: error.code || 'UNKNOWN' } }, 'failed to build mcp context');
    return res.status(500).json({ error: error.message });
  }
});

router.patch('/:id/status', async (req, res) => {
  try {
    if (!hasAnyRole(req, ['driver', 'admin', 'service'])) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    const bookingId = req.params.id;
    const requestedStatus = String(req.body?.status || '').toUpperCase();
    if (!requestedStatus) {
      return res.status(400).json({ error: 'status is required' });
    }
    if (requestedStatus !== 'ACCEPTED') {
      return res.status(400).json({
        error: 'Only ACCEPTED is supported in this endpoint'
      });
    }

    const driverId = String(req.body?.driver_id || req.body?.driverId || '').trim();
    if (!driverId) {
      return res.status(400).json({
        error: 'driver_id is required for ACCEPTED status'
      });
    }
    if (!isEightDigitId(driverId)) {
      return res.status(400).json({
        error: 'driver_id must be an 8-digit ID'
      });
    }
    if (hasAnyRole(req, ['driver']) && req.userId && driverId !== req.userId) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const traceId = req.traceId || req.header('x-trace-id');
    const authorization = req.header('authorization') || '';

    const eventId = crypto.randomUUID();
    const outcome = await withTransaction(async (client) => {
      const existing = await bookingRepo.getByIdForUpdate(client, bookingId);
      if (!existing) {
        return null;
      }

      const fromStatus = String(existing.status || '').toUpperCase();
      if (fromStatus !== 'REQUESTED' && fromStatus !== 'ACCEPTED' && fromStatus !== 'CONFIRMED') {
        const err = new Error(`Invalid transition from ${fromStatus} to ACCEPTED`);
        err.statusCode = 409;
        err.code = 'INVALID_STATE_TRANSITION';
        throw err;
      }

      const updated = fromStatus === 'ACCEPTED' ? existing : await bookingRepo.updateStatus(client, bookingId, 'ACCEPTED');

      if (fromStatus !== 'ACCEPTED') {
        const envelope = buildEnvelope({
          eventId,
          traceId,
          type: 'RideAccepted',
          payload: {
            event_type: 'ride_accepted',
            booking_id: updated.bookingId,
            ride_id: updated.rideId,
            driver_id: driverId,
            status: 'ACCEPTED',
            timestamp: new Date().toISOString()
          }
        });

        await outboxRepo.insertOutboxEvent(
          client,
          buildOutboxRecord({
            eventId,
            topic: topics.RideAccepted,
            eventType: 'RideAccepted',
            aggregateId: updated.bookingId,
            partitionKey: updated.rideId,
            envelope
          })
        );
      }

      return {
        booking: updated,
        eventQueued: fromStatus !== 'ACCEPTED'
      };
    });

    if (!outcome) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    const notification = await sendNotification({
      userId: driverId,
      title: 'Ride Assigned',
      message: `Booking ${bookingId} has been accepted`,
      sourceService: 'booking-service',
      sourceAction: 'BOOKING_ACCEPTED',
      authorization,
      traceId
    });

    return res.json({
      booking: mapBookingCompat(outcome.booking),
      publishedEvent: outcome.eventQueued
        ? {
            topic: topics.RideAccepted,
            eventId,
            eventType: 'ride_accepted',
            queued: true
          }
        : null,
      notification
    });
  } catch (error) {
    if (error?.statusCode && error?.code) {
      return res.status(error.statusCode).json({
        error: error.message,
        code: error.code
      });
    }
    logger.withTrace(req).error({ err: { message: error.message, code: error.code || 'UNKNOWN' } }, 'failed to update booking status');
    return res.status(500).json({ error: error.message });
  }
});

router.post('/internal/payment-failed-compensation', async (req, res) => {
  try {
    if (!hasAnyRole(req, ['service', 'admin', 'ops'])) {
      return res.status(403).json({ error: 'Forbidden' });
    }

    const traceId = req.traceId || req.header('x-trace-id');
    const rideId = String(req.body?.rideId || req.body?.ride_id || '').trim();
    const failureReason = String(req.body?.reason || 'PAYMENT_FAILED').trim().slice(0, 255) || 'PAYMENT_FAILED';
    if (!rideId) {
      return res.status(400).json({ error: 'rideId is required' });
    }

    const result = await withTransaction(async (client) => {
      const existing = await bookingRepo.getByRideIdForUpdate(client, rideId);
      if (!existing) {
        return {
          status: 'NOT_FOUND',
          booking: null,
          publishedEvent: null
        };
      }

      const currentStatus = String(existing.status || '').toUpperCase();
      if (currentStatus === 'CANCELLED') {
        return {
          status: 'ALREADY_CANCELLED',
          booking: existing,
          publishedEvent: null
        };
      }
      if (!isActiveBookingStatus(currentStatus)) {
        return {
          status: 'TERMINAL_STATUS',
          booking: existing,
          publishedEvent: null
        };
      }

      const cancelled = await bookingRepo.cancel(client, existing.bookingId);
      const eventId = crypto.randomUUID();
      const envelope = buildEnvelope({
        eventId,
        traceId,
        type: 'RideCancelled',
        payload: {
          rideId: cancelled.rideId,
          reason: failureReason,
          timestamp: new Date().toISOString()
        }
      });

      await outboxRepo.insertOutboxEvent(
        client,
        buildOutboxRecord({
          eventId,
          topic: topics.RideCancelled,
          eventType: 'RideCancelled',
          aggregateId: cancelled.bookingId,
          partitionKey: cancelled.rideId,
          envelope
        })
      );

      return {
        status: 'CANCELLED',
        booking: cancelled,
        publishedEvent: {
          topic: topics.RideCancelled,
          eventId,
          queued: true
        }
      };
    });

    if (result.status === 'NOT_FOUND') {
      return res.status(404).json({
        applied: false,
        code: 'BOOKING_NOT_FOUND',
        ride_id: rideId
      });
    }

    return res.status(200).json({
      applied: result.status === 'CANCELLED',
      code: result.status,
      booking: result.booking ? mapBookingCompat(result.booking) : null,
      publishedEvent: result.publishedEvent
    });
  } catch (error) {
    logger.withTrace(req).error(
      {
        err: {
          message: error.message,
          code: error.code || 'UNKNOWN'
        }
      },
      'failed internal payment-failed compensation'
    );
    return res.status(500).json({
      error: error.message,
      code: 'INTERNAL_COMPENSATION_FAILED'
    });
  }
});

router.post('/:id/cancel', async (req, res) => {
  try {
    const bookingId = req.params.id;
    const traceId = req.traceId || req.header('x-trace-id');
    const eventId = crypto.randomUUID();

    const canceled = await withTransaction(async (client) => {
      const existing = await bookingRepo.getByIdForUpdate(client, bookingId);
      if (!existing) {
        return null;
      }
      if (!hasPrivilegedRole(req) && existing.userId && req.userId && existing.userId !== req.userId) {
        const err = new Error('Forbidden');
        err.statusCode = 403;
        throw err;
      }

      const updated = existing.status === 'CANCELLED' ? existing : await bookingRepo.cancel(client, bookingId);

      const envelope = buildEnvelope({
        eventId,
        traceId,
        type: 'RideCancelled',
        payload: {
          rideId: updated.rideId,
          reason: 'CANCELLED_BY_CUSTOMER',
          timestamp: new Date().toISOString()
        }
      });

      await outboxRepo.insertOutboxEvent(
        client,
        buildOutboxRecord({
          eventId,
          topic: topics.RideCancelled,
          eventType: 'RideCancelled',
          aggregateId: bookingId,
          partitionKey: updated.rideId,
          envelope
        })
      );

      return updated;
    });

    if (!canceled) {
      monitoring.recordBookingStatus('cancelled', 'error', {
        reason: 'not_found'
      });
      return res.status(404).json({ error: 'Booking not found' });
    }

    monitoring.recordBookingStatus('cancelled', 'success');

    return res.status(200).json({
      booking: mapBookingCompat(canceled),
      publishedEvent: {
        topic: topics.RideCancelled,
        eventId,
        queued: true
      }
    });
  } catch (e) {
    if (e?.statusCode) {
      return res.status(e.statusCode).json({ error: e.message || 'Request failed' });
    }
    monitoring.recordBookingStatus('cancelled', 'error');
    logger.withTrace(req).error(
      {
        err: {
          message: e.message,
          code: e.code || 'UNKNOWN'
        }
      },
      'failed to cancel booking'
    );
    return res.status(500).json({ error: e.message });
  }
});

module.exports = router;
