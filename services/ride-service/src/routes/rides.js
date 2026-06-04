const express = require('express');
const crypto = require('crypto');
const {
  createRide,
  getRideById,
  getRideByExternalId,
  getActiveRideForDriver,
  listRides,
  claimRideForDriver,
  findNextRequestedRide,
  updateRideFields,
  updateRideStatus,
  addStatusHistory,
  getRideStatusHistory
} = require('../repository/rideRepository');
const { getByKey, createKey, setResponse } = require('../repository/idempotencyRepository');
const { requireAuth } = require('../middleware/auth');
const { ApiError } = require('../utils/errors');
const { asyncHandler } = require('../utils/asyncHandler');
const { encodeCursor, decodeCursor } = require('@libs/http');
const { validateRequest } = require('../middleware/validateRequest');
const { normalizeStatus, isValidTransition } = require('../domain/rideStateMachine');
const { buildIdempotencyKey, buildLockKey, getCachedResponse, saveCachedResponse, acquireLock, releaseLock } = require('../idempotency/store');
const monitoring = require('../monitoring');
const logger = require('../utils/logger');

const router = express.Router();

// Auto-assign every new ride to a default driver so driver app receives it immediately.
// Auto-assign is OFF by default; set AUTO_ASSIGN_DRIVER=true to force assign to DEFAULT_DRIVER_ID.
const AUTO_ASSIGN_DRIVER = String(process.env.AUTO_ASSIGN_DRIVER || 'false').toLowerCase() === 'true';
const DEFAULT_DRIVER_ID = String(process.env.DEFAULT_DRIVER_ID || '').trim();
const PAYMENT_SERVICE_URL = String(process.env.PAYMENT_SERVICE_URL || 'http://localhost:3007').replace(/\/+$/, '');

router.use(requireAuth);

function toRideResponse(row) {
  return {
    id: row.id,
    externalRideId: row.external_ride_id,
    bookingId: row.booking_id,
    riderId: row.rider_id,
    driverId: row.driver_id,
    quoteFareAmount: row.quote_fare_amount,
    quoteCurrency: row.quote_currency,
    pickupLat: row.pickup_lat,
    pickupLng: row.pickup_lng,
    pickupLabel: row.pickup_label,
    dropoffLat: row.dropoff_lat,
    dropoffLng: row.dropoff_lng,
    dropoffLabel: row.dropoff_label,
    status: row.status,
    statusUpdatedAt: row.status_updated_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function isEightDigitId(value) {
  return typeof value === 'string' && /^\d{8}$/.test(value.trim());
}

function haversineDistanceMeters(aLat, aLng, bLat, bLng) {
  const toRad = (value) => (value * Math.PI) / 180;
  const R = 6371000;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const lat1 = toRad(aLat);
  const lat2 = toRad(bLat);
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const h = sinLat * sinLat + Math.cos(lat1) * Math.cos(lat2) * sinLng * sinLng;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function toSafeDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? null : date;
}

function computeDurationSeconds(ride, statusHistory) {
  const createdAt = toSafeDate(ride.created_at);
  const completedAtFromHistory = statusHistory
    .map((entry) => ({ status: normalizeStatus(entry.to_status), at: toSafeDate(entry.occurred_at) }))
    .find((entry) => entry.status === 'COMPLETED' && entry.at)?.at;
  const startedAtFromHistory = statusHistory
    .map((entry) => ({ status: normalizeStatus(entry.to_status), at: toSafeDate(entry.occurred_at) }))
    .find((entry) => entry.status === 'IN_PROGRESS' && entry.at)?.at;

  const completedAt = completedAtFromHistory || toSafeDate(ride.status_updated_at);
  const startedAt = startedAtFromHistory || createdAt;

  if (!startedAt || !completedAt) return null;
  const seconds = Math.round((completedAt.getTime() - startedAt.getTime()) / 1000);
  return seconds > 0 ? seconds : null;
}

function computeBreakdown({ fareAmount, distanceMeters, durationSeconds }) {
  if (Number.isFinite(fareAmount) && fareAmount > 0) {
    const total = Math.round(fareAmount);
    const base = Math.round(total * 0.35);
    const distance = Math.round(total * 0.45);
    const time = Math.max(0, total - base - distance);
    return { base, distance, time, surge: 0, discount: 0, total };
  }

  const distanceKm = Number.isFinite(distanceMeters) ? distanceMeters / 1000 : 0;
  const durationMin = Number.isFinite(durationSeconds) ? durationSeconds / 60 : 0;
  const base = 12000;
  const distance = Math.round(distanceKm * 8500);
  const time = Math.round(durationMin * 1000);
  const total = base + distance + time;
  return { base, distance, time, surge: 0, discount: 0, total };
}

async function fetchPaymentsForRideId({ rideId, authorization, traceId, requestId }) {
  if (!PAYMENT_SERVICE_URL || !rideId) return [];
  const url = new URL('/v1/payments', PAYMENT_SERVICE_URL);
  url.searchParams.set('rideId', rideId);
  url.searchParams.set('limit', '20');
  url.searchParams.set('sort', '-createdAt');

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3500);
  try {
    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        ...(authorization ? { Authorization: authorization } : {}),
        ...(traceId ? { 'x-trace-id': traceId } : {}),
        ...(requestId ? { 'x-request-id': requestId } : {})
      },
      signal: controller.signal
    });
    if (!response.ok) return [];
    const payload = await response.json();
    return Array.isArray(payload?.data) ? payload.data : [];
  } catch (_error) {
    return [];
  } finally {
    clearTimeout(timeout);
  }
}

function toTimestamp(value) {
  if (!value) return 0;
  const parsed = new Date(value).getTime();
  return Number.isFinite(parsed) ? parsed : 0;
}

function toRoundedPositiveAmount(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const rounded = Math.round(parsed);
  return rounded > 0 ? rounded : null;
}

async function fetchPaymentsForRide({ rideIds, authorization, traceId, requestId }) {
  if (!PAYMENT_SERVICE_URL) return [];
  const normalizedRideIds = Array.from(
    new Set(
      (Array.isArray(rideIds) ? rideIds : [rideIds])
        .map((value) => (typeof value === 'string' ? value.trim() : ''))
        .filter((value) => Boolean(value))
    )
  );
  if (!normalizedRideIds.length) return [];

  const paymentLists = await Promise.all(
    normalizedRideIds.map((rideId) =>
      fetchPaymentsForRideId({
        rideId,
        authorization,
        traceId,
        requestId
      })
    )
  );

  const dedup = new Map();
  paymentLists.flat().forEach((payment) => {
    if (!payment || typeof payment !== 'object') return;
    const key = payment.id || `${payment.rideId || 'ride'}:${payment.createdAt || ''}:${payment.amount || ''}`;
    const current = dedup.get(key);
    if (!current || toTimestamp(payment.createdAt) >= toTimestamp(current.createdAt)) {
      dedup.set(key, payment);
    }
  });

  return Array.from(dedup.values()).sort((a, b) => toTimestamp(b?.createdAt) - toTimestamp(a?.createdAt));
}

router.post(
  '/',
  validateRequest({
    bodySchema: {
      required: ['pickupLat', 'pickupLng', 'dropoffLat', 'dropoffLng'],
      properties: {
        externalRideId: { type: 'string' },
        pickupLat: { type: 'number' },
        pickupLng: { type: 'number' },
        dropoffLat: { type: 'number' },
        dropoffLng: { type: 'number' },
        pickupLabel: { type: 'string' },
        dropoffLabel: { type: 'string' },
        bookingId: { type: 'string' },
        quoteFareAmount: { type: 'number' },
        quoteCurrency: { type: 'string' },
        driverId: { type: 'string' },
        status: { type: 'string' }
      }
    },
    custom: (req, errors) => {
      if (!req.header('Idempotency-Key')) {
        errors.push({
          path: 'headers.Idempotency-Key',
          message: 'is required'
        });
      }
      if (req.body?.driverId !== undefined && !isEightDigitId(req.body.driverId)) {
        errors.push({
          path: 'body.driverId',
          message: 'must be an 8-digit ID'
        });
      }
    }
  }),
  asyncHandler(async (req, res) => {
    if (!isEightDigitId(req.userId)) {
      throw new ApiError(401, 'UNAUTHORIZED', 'Invalid authenticated user ID format');
    }
    const idempotencyKey = req.header('Idempotency-Key');

    const routeKey = 'rides:create';
    const requestHash = crypto
      .createHash('sha256')
      .update(JSON.stringify(req.body || {}))
      .digest('hex');
    const cacheKey = buildIdempotencyKey({
      routeKey,
      userId: req.userId,
      idempotencyKey
    });
    const lockKey = buildLockKey({
      routeKey,
      userId: req.userId,
      idempotencyKey
    });

    const cached = await getCachedResponse(cacheKey);
    if (cached) {
      if (cached.requestHash && cached.requestHash !== requestHash) {
        throw new ApiError(409, 'CONFLICT', 'Idempotency key reuse with different request');
      }
      if (cached.headers) {
        Object.entries(cached.headers).forEach(([key, value]) => {
          const headerKey = String(key).toLowerCase();
          if (headerKey === 'x-trace-id' || headerKey === 'x-request-id') {
            return;
          }
          if (value) {
            res.setHeader(key, value);
          }
        });
      }
      return res.status(cached.status).json(cached.body);
    }

    let lockAcquired = false;
    lockAcquired = await acquireLock(lockKey);
    if (!lockAcquired) {
      throw new ApiError(409, 'IDEMPOTENCY_IN_PROGRESS', 'Idempotency key is being processed');
    }

    let responseBody;
    let responseStatus = 201;

    try {
      const existing = await getByKey({
        routeKey,
        userId: req.userId,
        idempotencyKey
      });
      if (existing && existing.request_hash !== requestHash) {
        throw new ApiError(409, 'CONFLICT', 'Idempotency key reuse with different request');
      }
      if (existing && existing.response_status) {
        const responseHeaders = existing.response_headers || {};
        Object.entries(responseHeaders).forEach(([key, value]) => {
          const headerKey = String(key).toLowerCase();
          if (headerKey === 'x-trace-id' || headerKey === 'x-request-id') {
            return;
          }
          if (value) {
            res.setHeader(key, value);
          }
        });

        responseBody = existing.response_body;
        await saveCachedResponse(cacheKey, {
          status: existing.response_status,
          headers: responseHeaders,
          body: responseBody,
          requestHash,
          createdAt: new Date().toISOString()
        });

        return res.status(existing.response_status).json(responseBody);
      }
      if (existing && !existing.response_status) {
        throw new ApiError(409, 'CONFLICT', 'Idempotency key is being processed');
      }

      await createKey({
        routeKey,
        userId: req.userId,
        idempotencyKey,
        requestHash
      });

      const requestedExternalRideId =
        typeof req.body?.externalRideId === 'string' && req.body.externalRideId.trim() ? req.body.externalRideId.trim() : null;
      if (requestedExternalRideId) {
        const existingRide = await getRideByExternalId(requestedExternalRideId);
        if (existingRide) {
          const quoteBackfill = {};
          if (Number.isFinite(Number(req.body.quoteFareAmount)) && Number(req.body.quoteFareAmount) > 0) {
            quoteBackfill.quoteFareAmount = req.body.quoteFareAmount;
          }
          if (typeof req.body.quoteCurrency === 'string' && req.body.quoteCurrency.trim()) {
            quoteBackfill.quoteCurrency = req.body.quoteCurrency;
          }
          if (req.body.bookingId && !existingRide.booking_id) {
            quoteBackfill.bookingId = req.body.bookingId;
          }

          const rideForResponse =
            Object.keys(quoteBackfill).length > 0 ? (await updateRideFields(existingRide.id, quoteBackfill)) || existingRide : existingRide;

          responseStatus = 200;
          responseBody = { data: toRideResponse(rideForResponse) };

          const responseHeaders = {
            'content-type': 'application/json',
            'x-trace-id': req.traceId,
            'x-request-id': req.requestId
          };

          await setResponse({
            routeKey,
            userId: req.userId,
            idempotencyKey,
            responseStatus,
            responseHeaders,
            responseBody
          });

          await saveCachedResponse(cacheKey, {
            status: responseStatus,
            headers: responseHeaders,
            body: responseBody,
            requestHash,
            createdAt: new Date().toISOString()
          });

          return res.status(responseStatus).json(responseBody);
        }
      }
      const shouldAutoAssign = AUTO_ASSIGN_DRIVER && !req.body?.driverId && isEightDigitId(DEFAULT_DRIVER_ID);

      const ride = await createRide({
        externalRideId: requestedExternalRideId || crypto.randomUUID(),
        bookingId: req.body.bookingId,
        riderId: req.userId,
        driverId: shouldAutoAssign ? DEFAULT_DRIVER_ID : req.body.driverId ? String(req.body.driverId).trim() : null,
        pickupLat: req.body.pickupLat,
        pickupLng: req.body.pickupLng,
        pickupLabel: req.body.pickupLabel || null,
        dropoffLat: req.body.dropoffLat,
        dropoffLng: req.body.dropoffLng,
        dropoffLabel: req.body.dropoffLabel || null,
        quoteFareAmount: req.body.quoteFareAmount,
        quoteCurrency: req.body.quoteCurrency,
        status: shouldAutoAssign ? 'assigned' : req.body.status || 'requested',
        traceId: req.traceId
      });

      await addStatusHistory({
        rideId: ride.id,
        fromStatus: null,
        toStatus: ride.status,
        actorId: req.userId,
        traceId: req.traceId
      });
      monitoring.recordRideCreated('success', {
        status: String(ride.status || 'requested').toLowerCase()
      });

      responseBody = { data: toRideResponse(ride) };

      const responseHeaders = {
        'content-type': 'application/json',
        'x-trace-id': req.traceId,
        'x-request-id': req.requestId
      };

      await setResponse({
        routeKey,
        userId: req.userId,
        idempotencyKey,
        responseStatus,
        responseHeaders,
        responseBody
      });

      await saveCachedResponse(cacheKey, {
        status: responseStatus,
        headers: responseHeaders,
        body: responseBody,
        requestHash,
        createdAt: new Date().toISOString()
      });
    } finally {
      if (lockAcquired) {
        await releaseLock(lockKey);
      }
    }

    return res.status(responseStatus).json(responseBody);
  })
);

router.get(
  '/assignments',
  asyncHandler(async (req, res) => {
    const driverId = req.userId;
    if (!driverId || !isEightDigitId(driverId)) {
      throw new ApiError(401, 'UNAUTHORIZED', 'Missing driver identity');
    }

    const active = await getActiveRideForDriver(driverId);
    if (active) {
      return res.json({ data: [toRideResponse(active)] });
    }

    // Chỉ trả về chuyến pending, không tự claim; driver phải gọi PATCH để nhận.
    const pending = await findNextRequestedRide();
    if (!pending) {
      return res.json({ data: [] });
    }
    return res.json({ data: [toRideResponse(pending)] });
  })
);

router.get(
  '/external/:externalRideId',
  validateRequest({
    paramsSchema: {
      required: ['externalRideId'],
      properties: {
        externalRideId: { type: 'string' }
      }
    }
  }),
  asyncHandler(async (req, res) => {
    const ride = await getRideByExternalId(req.params.externalRideId);
    if (!ride) {
      throw new ApiError(404, 'NOT_FOUND', 'Ride not found');
    }

    return res.json({ data: toRideResponse(ride) });
  })
);

router.get(
  '/:id',
  validateRequest({
    paramsSchema: {
      required: ['id'],
      properties: {
        id: { type: 'string' }
      }
    }
  }),
  asyncHandler(async (req, res) => {
    const ride = await getRideById(req.params.id);
    if (!ride) {
      throw new ApiError(404, 'NOT_FOUND', 'Ride not found');
    }

    return res.json({ data: toRideResponse(ride) });
  })
);

router.get(
  '/:id/summary',
  validateRequest({
    paramsSchema: {
      required: ['id'],
      properties: {
        id: { type: 'string' }
      }
    }
  }),
  asyncHandler(async (req, res) => {
    const ride = await getRideById(req.params.id);
    if (!ride) {
      throw new ApiError(404, 'NOT_FOUND', 'Ride not found');
    }

    const currentStatus = normalizeStatus(ride.status);
    if (currentStatus !== 'COMPLETED') {
      throw new ApiError(409, 'INVALID_STATE_TRANSITION', 'Ride must be COMPLETED to get summary');
    }

    const statusHistory = await getRideStatusHistory(ride.id);
    const distanceMeters =
      Number.isFinite(ride.pickup_lat) && Number.isFinite(ride.pickup_lng) && Number.isFinite(ride.dropoff_lat) && Number.isFinite(ride.dropoff_lng)
        ? Math.round(haversineDistanceMeters(ride.pickup_lat, ride.pickup_lng, ride.dropoff_lat, ride.dropoff_lng))
        : null;
    const durationSeconds = computeDurationSeconds(ride, statusHistory);

    const payments = await fetchPaymentsForRide({
      rideIds: [ride.external_ride_id, ride.id, ride.booking_id],
      authorization: req.get('authorization') || '',
      traceId: req.traceId || null,
      requestId: req.requestId || null
    });
    const latestPayment = payments[0] || null;
    const paidAmountPayment =
      payments.find((item) => normalizeStatus(item.status) === 'PAID' && toRoundedPositiveAmount(item.amount) !== null) ||
      null;
    const firstValidPayment = payments.find((item) => toRoundedPositiveAmount(item.amount) !== null) || null;
    const paymentFareAmount = toRoundedPositiveAmount(paidAmountPayment?.amount);
    const quotedFareAmount = toRoundedPositiveAmount(ride.quote_fare_amount);
    const amountSourcePayment = paidAmountPayment || (quotedFareAmount === null ? firstValidPayment : null);
    const fallbackFareAmount = toRoundedPositiveAmount(amountSourcePayment?.amount);
    const effectiveFareAmount =
      paymentFareAmount !== null
        ? paymentFareAmount
        : quotedFareAmount !== null
        ? quotedFareAmount
        : fallbackFareAmount;
    const breakdown = computeBreakdown({ fareAmount: effectiveFareAmount, distanceMeters, durationSeconds });
    const fareSource =
      paymentFareAmount !== null
        ? 'payment-service'
        : quotedFareAmount !== null
        ? 'booking-quote'
        : fallbackFareAmount !== null
        ? 'payment-service'
        : 'estimated';

    return res.json({
      data: {
        rideId: ride.id,
        status: currentStatus,
        distanceMeters,
        durationSeconds,
        fare: {
          amount: effectiveFareAmount !== null ? effectiveFareAmount : breakdown.total,
          currency: amountSourcePayment?.currency || ride.quote_currency || latestPayment?.currency || 'VND',
          paymentStatus: amountSourcePayment?.status || latestPayment?.status || null,
          paymentId: amountSourcePayment?.id || latestPayment?.id || null,
          method: amountSourcePayment?.method || latestPayment?.method || null,
          source: fareSource
        },
        breakdown
      },
      requestId: req.requestId
    });
  })
);

router.get(
  '/',
  validateRequest({
    querySchema: {
      properties: {
        status: { type: 'string' },
        riderId: { type: 'string' },
        driverId: { type: 'string' },
        limit: { type: 'string' },
        cursor: { type: 'string' },
        sort: { type: 'string' }
      }
    },
    custom: (req, errors) => {
      const sort = req.query.sort || '-createdAt';
      if (!['-createdAt', 'createdAt'].includes(sort)) {
        errors.push({
          path: 'query.sort',
          message: 'must be createdAt or -createdAt'
        });
      }

      let cursor = null;
      if (req.query.cursor) {
        cursor = decodeCursor(req.query.cursor);
        if (!cursor) {
          errors.push({
            path: 'query.cursor',
            message: 'is invalid'
          });
        }
      }
      if (req.query.riderId && !isEightDigitId(req.query.riderId)) {
        errors.push({
          path: 'query.riderId',
          message: 'must be an 8-digit ID'
        });
      }
      if (req.query.driverId && !isEightDigitId(req.query.driverId)) {
        errors.push({
          path: 'query.driverId',
          message: 'must be an 8-digit ID'
        });
      }

      const hasLimit = req.query.limit !== undefined;
      const limitRaw = Number(req.query.limit || 20);
      const limit = Number.isFinite(limitRaw) ? limitRaw : 20;
      if (hasLimit && !Number.isFinite(limitRaw)) {
        errors.push({
          path: 'query.limit',
          message: 'must be a number'
        });
      }
      if (limit < 1 || limit > 100) {
        errors.push({
          path: 'query.limit',
          message: 'must be between 1 and 100'
        });
      }

      req.pagination = {
        limit: Math.min(Math.max(limit, 1), 100),
        cursor,
        sort
      };
    }
  }),
  asyncHandler(async (req, res) => {
    const { limit, cursor, sort } = req.pagination;
    const roles = req.user?.roles || [];
    const canListAll = roles.includes('admin') || roles.includes('ops') || roles.includes('driver');
    const requestedRiderId = req.query.riderId || null;
    const requestedDriverId = req.query.driverId || null;
    const riderId = requestedRiderId ? (canListAll ? requestedRiderId : req.userId) : canListAll ? null : req.userId;
    const driverId = requestedDriverId ? (canListAll ? requestedDriverId : req.userId) : null;

    const rows = await listRides({
      limit,
      cursor,
      status: req.query.status ? String(req.query.status).toLowerCase() : null,
      riderId,
      driverId,
      sort: sort === '-createdAt' ? '-created_at' : 'created_at'
    });

    const data = rows.map(toRideResponse);
    const last = rows[rows.length - 1];
    const nextCursor =
      rows.length === limit && last
        ? encodeCursor({
            createdAt: last.created_at,
            id: last.id
          })
        : null;

    return res.json({ data, nextCursor });
  })
);

router.patch(
  '/:id',
  validateRequest({
    paramsSchema: {
      required: ['id'],
      properties: {
        id: { type: 'string' }
      }
    },
    bodySchema: {
      properties: {
        driverId: { type: 'string' },
        pickupLat: { type: 'number' },
        pickupLng: { type: 'number' },
        pickupLabel: { type: 'string' },
        dropoffLat: { type: 'number' },
        dropoffLng: { type: 'number' },
        dropoffLabel: { type: 'string' },
        status: { type: 'string' },
        statusReason: { type: 'string' }
      }
    },
    custom: (req, errors) => {
      const hasUpdatableFields = ['driverId', 'pickupLat', 'pickupLng', 'dropoffLat', 'dropoffLng', 'status'].some(
        (field) => req.body?.[field] !== undefined
      );
      if (!hasUpdatableFields) {
        errors.push({
          path: 'body',
          message: 'at least one field is required'
        });
      }
      if (req.body?.driverId !== undefined && !isEightDigitId(req.body.driverId)) {
        errors.push({
          path: 'body.driverId',
          message: 'must be an 8-digit ID'
        });
      }
    }
  }),
  asyncHandler(async (req, res) => {
    let ride = await getRideById(req.params.id);
    if (!ride) {
      throw new ApiError(404, 'NOT_FOUND', 'Ride not found');
    }

    let fromStatus = null;
    let toStatus = null;
    if (req.body.status) {
      fromStatus = normalizeStatus(ride.status);
      toStatus = normalizeStatus(req.body.status);
      const reason = req.body.statusReason || null;
      const actor = req.userId;
      if (!isValidTransition(fromStatus, toStatus)) {
        monitoring.recordRideStatus(toStatus, 'error', {
          reason: 'invalid_transition',
          from_status: String(fromStatus || 'unknown').toLowerCase()
        });
        logger.withTrace(req).warn(
          {
            rideId: ride.id,
            fromStatus,
            toStatus,
            actor,
            reason
          },
          'ride transition rejected'
        );
        throw new ApiError(409, 'INVALID_STATE_TRANSITION', `Invalid transition from ${fromStatus} to ${toStatus}`);
      }
      logger.withTrace(req).info(
        {
          rideId: ride.id,
          fromStatus,
          toStatus,
          actor,
          reason
        },
        'ride transition'
      );
    }

    if (
      req.body.driverId !== undefined ||
      req.body.pickupLat !== undefined ||
      req.body.pickupLng !== undefined ||
      req.body.pickupLabel !== undefined ||
      req.body.dropoffLat !== undefined ||
      req.body.dropoffLng !== undefined ||
      req.body.dropoffLabel !== undefined
    ) {
      ride = await updateRideFields(req.params.id, {
        driverId: req.body.driverId,
        pickupLat: req.body.pickupLat,
        pickupLng: req.body.pickupLng,
        pickupLabel: req.body.pickupLabel,
        dropoffLat: req.body.dropoffLat,
        dropoffLng: req.body.dropoffLng,
        dropoffLabel: req.body.dropoffLabel
      });
    }

    if (req.body.status) {
      ride = await updateRideStatus({
        id: req.params.id,
        status: String(req.body.status).toLowerCase(),
        fromStatus,
        reason: req.body.statusReason || null,
        actorId: req.userId,
        traceId: req.traceId
      });
      monitoring.recordRideStatus(ride.status, 'success', {
        from_status: String(fromStatus || 'unknown').toLowerCase()
      });
    }

    return res.json({ data: toRideResponse(ride) });
  })
);

router.delete(
  '/:id',
  validateRequest({
    paramsSchema: {
      required: ['id'],
      properties: {
        id: { type: 'string' }
      }
    }
  }),
  asyncHandler(async (req, res) => {
    const ride = await getRideById(req.params.id);

    if (!ride) {
      throw new ApiError(404, 'NOT_FOUND', 'Ride not found');
    }

    const fromStatus = normalizeStatus(ride.status);
    const toStatus = 'CANCELLED';
    if (!isValidTransition(fromStatus, toStatus)) {
      monitoring.recordRideStatus(toStatus, 'error', {
        reason: 'invalid_transition',
        from_status: String(fromStatus || 'unknown').toLowerCase()
      });
      throw new ApiError(409, 'INVALID_STATE_TRANSITION', `Invalid transition from ${fromStatus} to ${toStatus}`);
    }

    logger.withTrace(req).info(
      {
        rideId: ride.id,
        fromStatus,
        toStatus
      },
      'ride transition'
    );

    const updated = await updateRideStatus({
      id: req.params.id,
      status: 'cancelled',
      fromStatus,
      reason: req.body?.reason || null,
      actorId: req.userId,
      traceId: req.traceId
    });
    monitoring.recordRideStatus(updated.status, 'success', {
      from_status: String(fromStatus || 'unknown').toLowerCase()
    });

    return res.json({ data: toRideResponse(updated) });
  })
);

module.exports = router;
