const topics = require('./topics');
const { publishToDlq } = require('./producer');
const logger = require('../utils/logger');
const { claimPendingEvents, countInboxBacklog, markProcessed, markFailed } = require('../repository/inboxEventsRepository');
const { getRideById, getRideByExternalId, createRide, addStatusHistory, updateRideFields, updateRideStatus } = require('../repository/rideRepository');
const { normalizeStatus, isValidTransition } = require('../domain/rideStateMachine');
const monitoring = require('../monitoring');

const DEFAULT_INTERVAL_MS = 3000;
const DEFAULT_BATCH_SIZE = 50;
const WORKER_ID = process.env.INBOX_WORKER_ID || `${process.env.HOSTNAME || 'ride-service'}-${process.pid}`;

async function handleRideCreated(row) {
  const payload = row.payload || {};
  const externalRideId = payload.rideId;
  const pickup = payload.pickup || {};

  if (!externalRideId || pickup.lat == null || pickup.lng == null) {
    throw new Error('ride.created missing rideId or pickup');
  }

  const existing = await getRideByExternalId(externalRideId);
  if (existing) {
    const backfill = {};
    if (payload.bookingId != null) {
      backfill.bookingId = payload.bookingId;
    }
    if (payload.riderId != null) {
      backfill.riderId = payload.riderId;
    }
    if (typeof payload.pickup?.address === 'string') {
      backfill.pickupLabel = payload.pickup.address;
    }
    if (payload.dropoff?.lat !== undefined) {
      backfill.dropoffLat = payload.dropoff.lat;
    }
    if (payload.dropoff?.lng !== undefined) {
      backfill.dropoffLng = payload.dropoff.lng;
    }
    if (typeof payload.dropoff?.address === 'string') {
      backfill.dropoffLabel = payload.dropoff.address;
    }
    if (existing.quote_fare_amount == null && Number.isFinite(Number(payload.pricing?.estimatedFare))) {
      backfill.quoteFareAmount = Math.round(Number(payload.pricing.estimatedFare));
    }
    if (!existing.quote_currency && typeof payload.pricing?.currency === 'string' && payload.pricing.currency.trim()) {
      backfill.quoteCurrency = payload.pricing.currency;
    }

    if (Object.keys(backfill).length > 0) {
      await updateRideFields(existing.id, backfill);
    }

    return { skipped: true, rideId: existing.id, backfilled: Object.keys(backfill).length > 0 };
  }

  const ride = await createRide({
    externalRideId,
    bookingId: payload.bookingId || null,
    riderId: payload.riderId || null,
    driverId: null,
    pickupLat: pickup.lat,
    pickupLng: pickup.lng,
    pickupLabel: typeof payload.pickup?.address === 'string' ? payload.pickup.address : null,
    dropoffLat: payload.dropoff?.lat ?? null,
    dropoffLng: payload.dropoff?.lng ?? null,
    dropoffLabel: typeof payload.dropoff?.address === 'string' ? payload.dropoff.address : null,
    quoteFareAmount: Number.isFinite(Number(payload.pricing?.estimatedFare)) ? Math.round(Number(payload.pricing.estimatedFare)) : null,
    quoteCurrency: typeof payload.pricing?.currency === 'string' ? payload.pricing.currency : null,
    status: 'requested',
    traceId: row.trace_id || null,
    emitOutbox: false
  });

  await addStatusHistory({
    rideId: ride.id,
    fromStatus: null,
    toStatus: ride.status,
    actorId: payload.riderId || null,
    traceId: row.trace_id || null,
    occurredAt: payload.timestamp || null
  });

  return { rideId: ride.id };
}

async function resolveRideByPaymentRideId(rideId) {
  if (!rideId) {
    return null;
  }
  const byId = await getRideById(rideId);
  if (byId) {
    return byId;
  }
  return getRideByExternalId(rideId);
}

async function applyPaymentStatusToRide({ row, payload, targetStatus, reason }) {
  const ride = await resolveRideByPaymentRideId(payload.rideId);
  if (!ride) {
    // Keep the event retriable for out-of-order delivery (payment before ride.created).
    throw new Error(`ride_not_found:${payload.rideId}`);
  }

  const fromStatus = normalizeStatus(ride.status);
  const toStatus = normalizeStatus(targetStatus);
  if (fromStatus === toStatus) {
    return {
      skipped: true,
      reason: 'already_in_target_state',
      rideId: ride.id,
      status: ride.status
    };
  }

  if (!isValidTransition(fromStatus, toStatus)) {
    return {
      skipped: true,
      reason: 'invalid_state_transition',
      rideId: ride.id,
      fromStatus,
      toStatus
    };
  }

  const updated = await updateRideStatus({
    id: ride.id,
    status: String(targetStatus).toLowerCase(),
    fromStatus,
    reason: reason || null,
    actorId: payload.paymentId || 'payment-service',
    traceId: row.trace_id || null
  });

  return {
    rideId: updated.id,
    fromStatus: ride.status,
    toStatus: updated.status
  };
}

async function handlePaymentCompleted(row) {
  const payload = row.payload || {};
  if (!payload.paymentId || !payload.rideId) {
    throw new Error('payment.completed missing paymentId or rideId');
  }
  return applyPaymentStatusToRide({
    row,
    payload,
    targetStatus: 'completed',
    reason: 'payment_completed'
  });
}

async function handlePaymentFailed(row) {
  const payload = row.payload || {};
  if (!payload.paymentId || !payload.rideId) {
    throw new Error('payment.failed missing paymentId or rideId');
  }
  return applyPaymentStatusToRide({
    row,
    payload,
    targetStatus: 'cancelled',
    reason: payload.failureReason || 'payment_failed'
  });
}

async function handleRideCancelled(row) {
  const payload = row.payload || {};
  if (!payload.rideId) {
    throw new Error('ride.cancelled missing rideId');
  }

  const ride = await resolveRideByPaymentRideId(payload.rideId);
  if (!ride) {
    return { skipped: true, reason: 'ride_not_found', rideId: payload.rideId };
  }

  const fromStatus = normalizeStatus(ride.status);
  const toStatus = 'CANCELLED';
  if (fromStatus === toStatus) {
    return {
      skipped: true,
      reason: 'already_in_target_state',
      rideId: ride.id,
      status: ride.status
    };
  }

  if (!isValidTransition(fromStatus, toStatus)) {
    return {
      skipped: true,
      reason: 'invalid_state_transition',
      rideId: ride.id,
      fromStatus,
      toStatus
    };
  }

  const updated = await updateRideStatus({
    id: ride.id,
    status: 'cancelled',
    fromStatus,
    reason: payload.reason || 'cancelled_by_customer',
    actorId: 'booking-service',
    traceId: row.trace_id || null
  });

  return {
    rideId: updated.id,
    fromStatus: ride.status,
    toStatus: updated.status
  };
}

async function processRow(row) {
  switch (row.topic) {
    case topics.RideCreated:
      return handleRideCreated(row);
    case topics.RideCancelled:
      return handleRideCancelled(row);
    case topics.PaymentCompleted:
      return handlePaymentCompleted(row);
    case topics.PaymentFailed:
      return handlePaymentFailed(row);
    default:
      return { skipped: true };
  }
}

async function tick() {
  const backlogBefore = await countInboxBacklog();
  monitoring.setQueueBacklog('inbox.ride', backlogBefore);

  const rows = await claimPendingEvents(DEFAULT_BATCH_SIZE, WORKER_ID);
  if (!rows.length) {
    monitoring.setQueueBacklog('inbox.ride', backlogBefore);
    return;
  }

  for (const row of rows) {
    const rowStartedAt = Date.now();
    try {
      const result = await processRow(row);
      await markProcessed(row._id);
      monitoring.recordKafkaProcessingLatency({
        pipeline: 'inbox_process',
        topic: row.topic,
        outcome: 'success',
        durationMs: Date.now() - rowStartedAt
      });
      logger.withTrace(row.trace_id).info({ topic: row.topic, eventId: row.event_id, result }, '[ride-service] inbox processed');
    } catch (error) {
      logger.withTrace(row.trace_id).error({ err: error, eventId: row.event_id, topic: row.topic }, '[ride-service] inbox process failed');
      const retry = await markFailed(row._id, error?.message || 'failed');
      monitoring.recordKafkaRetry({
        scope: 'inbox',
        topic: row.topic,
        status: String(retry?.status || 'unknown').toLowerCase(),
        reason: error?.message || 'failed'
      });
      monitoring.recordKafkaProcessingLatency({
        pipeline: 'inbox_process',
        topic: row.topic,
        outcome: 'error',
        durationMs: Date.now() - rowStartedAt
      });
      if (retry?.status === 'dead') {
        await publishToDlq({
          topic: row.topic,
          envelope: {
            eventId: row.event_id,
            traceId: row.trace_id || null,
            occurredAt: new Date().toISOString(),
            type: row.event_type || 'UnknownEvent',
            version: 1,
            payload: row.payload
          },
          errorMessage: error?.message || 'failed',
          metadata: {
            source: 'ride-service.inbox-processor',
            attemptCount: retry.attemptCount,
            maxAttempts: retry.maxAttempts
          }
        });
      }
    }
  }

  const backlogAfter = await countInboxBacklog();
  monitoring.setQueueBacklog('inbox.ride', backlogAfter);
}

function startInboxProcessor(intervalMs = DEFAULT_INTERVAL_MS) {
  const timer = setInterval(() => {
    tick().catch((error) => {
      logger.error({ err: error }, '[ride-service] inbox tick error');
    });
  }, intervalMs);

  timer.unref();
  return () => clearInterval(timer);
}

module.exports = { startInboxProcessor, processRow };
