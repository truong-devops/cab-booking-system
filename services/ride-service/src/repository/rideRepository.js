const crypto = require('crypto');
const { getDb, runWithOptionalTransaction } = require('../db/mongo');

const ASSIGNMENT_EXCLUDED_RIDE_IDS = [
  '99999999-9999-9999-9999-999999999998',
  '99999999-9999-9999-9999-999999999997',
  '99999999-9999-9999-9999-999999999996'
];
const ASSIGNMENT_REQUEST_TTL_MS = Number(process.env.DRIVER_ASSIGNMENT_REQUEST_TTL_MS || 15 * 60 * 1000);

function isEightDigitId(value) {
  return typeof value === 'string' && /^\d{8}$/.test(value.trim());
}

function normalizeIdentityId(value) {
  if (value === undefined || value === null) return null;
  const normalized = String(value).trim();
  if (!normalized) return null;
  return isEightDigitId(normalized) ? normalized : null;
}

function buildRealCustomerRideFilter() {
  return {
    booking_id: { $type: 'string', $regex: /^bk_/ },
    external_ride_id: { $type: 'string', $regex: /^ride_/ },
    rider_id: { $regex: /^\d{8}$/ }
  };
}

function buildAssignableRideFilter() {
  const filter = {
    _id: { $nin: ASSIGNMENT_EXCLUDED_RIDE_IDS },
    ...buildRealCustomerRideFilter(),
    status: 'requested',
    driver_id: null
  };

  if (Number.isFinite(ASSIGNMENT_REQUEST_TTL_MS) && ASSIGNMENT_REQUEST_TTL_MS > 0) {
    filter.created_at = { $gte: new Date(Date.now() - ASSIGNMENT_REQUEST_TTL_MS) };
  }

  return filter;
}

function mapRide(doc) {
  if (!doc) {
    return null;
  }

  return {
    id: doc._id,
    external_ride_id: doc.external_ride_id,
    booking_id: doc.booking_id || null,
    rider_id: doc.rider_id || null,
    driver_id: doc.driver_id || null,
    pickup_lat: doc.pickup_lat,
    pickup_lng: doc.pickup_lng,
    pickup_label: doc.pickup_label || null,
    dropoff_lat: doc.dropoff_lat ?? null,
    dropoff_lng: doc.dropoff_lng ?? null,
    dropoff_label: doc.dropoff_label || null,
    quote_fare_amount: doc.quote_fare_amount ?? null,
    quote_currency: doc.quote_currency || null,
    status: doc.status,
    status_updated_at: doc.status_updated_at,
    created_at: doc.created_at,
    updated_at: doc.updated_at
  };
}

function unwrapFindOneAndUpdateResult(result) {
  if (!result) {
    return null;
  }
  return Object.prototype.hasOwnProperty.call(result, 'value') ? result.value : result;
}

function buildCursorFilter({ cursor, isDesc }) {
  if (!cursor?.createdAt || !cursor?.id) {
    return null;
  }

  const createdAt = new Date(cursor.createdAt);
  if (Number.isNaN(createdAt.valueOf())) {
    return null;
  }

  if (isDesc) {
    return {
      $or: [{ created_at: { $lt: createdAt } }, { created_at: createdAt, _id: { $lt: cursor.id } }]
    };
  }

  return {
    $or: [{ created_at: { $gt: createdAt } }, { created_at: createdAt, _id: { $gt: cursor.id } }]
  };
}

async function createRide({
  externalRideId,
  bookingId = null,
  riderId = null,
  driverId = null,
  pickupLat,
  pickupLng,
  pickupLabel = null,
  dropoffLat = null,
  dropoffLng = null,
  dropoffLabel = null,
  quoteFareAmount = null,
  quoteCurrency = null,
  status,
  traceId = null,
  emitOutbox = true
}) {
  const db = await getDb();
  const now = new Date();
  const rideId = crypto.randomUUID();
  const rideDoc = {
    _id: rideId,
    external_ride_id: externalRideId,
    booking_id: bookingId,
    rider_id: normalizeIdentityId(riderId),
    driver_id: normalizeIdentityId(driverId),
    pickup_lat: pickupLat,
    pickup_lng: pickupLng,
    pickup_label: pickupLabel,
    dropoff_lat: dropoffLat,
    dropoff_lng: dropoffLng,
    dropoff_label: dropoffLabel,
    quote_fare_amount: Number.isFinite(Number(quoteFareAmount)) ? Math.round(Number(quoteFareAmount)) : null,
    quote_currency: typeof quoteCurrency === 'string' && quoteCurrency.trim() ? quoteCurrency.trim().toUpperCase() : null,
    status,
    status_updated_at: now,
    created_at: now,
    updated_at: now
  };

  let outboxDoc = null;
  if (emitOutbox) {
    const eventId = crypto.randomUUID();
    const eventPayload = {
      rideId,
      pickup: { lat: pickupLat, lng: pickupLng },
      timestamp: now
    };
    outboxDoc = {
      _id: crypto.randomUUID(),
      event_id: eventId,
      aggregate_type: 'ride',
      aggregate_id: rideId,
      event_type: 'RideCreated',
      topic: 'ride.created',
      payload: { traceId, payload: eventPayload },
      status: 'pending',
      attempt_count: 0,
      max_attempts: Number(process.env.OUTBOX_MAX_ATTEMPTS || 10),
      next_retry_at: now,
      processing_started_at: null,
      processing_owner: null,
      last_error: null,
      last_error_at: null,
      dlq_topic: null,
      dlq_payload: null,
      occurred_at: now,
      created_at: now,
      updated_at: now
    };
  }

  await runWithOptionalTransaction(async (session) => {
    const options = session ? { session } : {};
    await db.collection('rides').insertOne(rideDoc, options);
    if (outboxDoc) {
      await db.collection('outbox_events').insertOne(outboxDoc, options);
    }
    return rideDoc;
  });

  return mapRide(rideDoc);
}

async function getRideById(id) {
  const db = await getDb();
  const doc = await db.collection('rides').findOne({ _id: id });
  return mapRide(doc);
}

async function getRideByExternalId(externalRideId) {
  const db = await getDb();
  const doc = await db.collection('rides').findOne({ external_ride_id: externalRideId });
  return mapRide(doc);
}

async function getActiveRideForDriver(driverId) {
  const normalizedDriverId = normalizeIdentityId(driverId);
  if (!normalizedDriverId) {
    return null;
  }
  const db = await getDb();
  const doc = await db.collection('rides').findOne(
    {
      _id: { $nin: ASSIGNMENT_EXCLUDED_RIDE_IDS },
      ...buildRealCustomerRideFilter(),
      driver_id: normalizedDriverId,
      status: { $in: ['assigned', 'arriving', 'in_progress'] }
    },
    { sort: { status_updated_at: -1, created_at: -1 } }
  );
  return mapRide(doc);
}

async function updateRideStatus({ id, status, fromStatus = null, reason = null, actorId = null, traceId = null }) {
  const db = await getDb();
  const now = new Date();

  const updatedRide = await runWithOptionalTransaction(async (session) => {
    const updateOptions = { returnDocument: 'after' };
    if (session) {
      updateOptions.session = session;
    }

    const rideResult = await db.collection('rides').findOneAndUpdate(
      { _id: id },
      {
        $set: {
          status,
          status_updated_at: now,
          updated_at: now
        }
      },
      updateOptions
    );

    const rideDoc = unwrapFindOneAndUpdateResult(rideResult);
    if (!rideDoc) {
      return null;
    }

    const historyDoc = {
      _id: crypto.randomUUID(),
      ride_id: id,
      from_status: fromStatus ? String(fromStatus).toLowerCase() : null,
      to_status: String(status).toLowerCase(),
      reason,
      actor_id: normalizeIdentityId(actorId),
      trace_id: traceId,
      occurred_at: now,
      created_at: now,
      updated_at: now
    };

    const insertOptions = session ? { session } : {};
    await db.collection('ride_status_history').insertOne(historyDoc, insertOptions);

    if (status === 'assigned') {
      const eventId = crypto.randomUUID();
      const eventPayload = {
        rideId: rideDoc._id,
        driverId: rideDoc.driver_id,
        assignedAt: rideDoc.status_updated_at
      };

      const outboxDoc = {
        _id: crypto.randomUUID(),
        event_id: eventId,
        aggregate_type: 'ride',
        aggregate_id: rideDoc._id,
        event_type: 'RideAssigned',
        topic: 'ride.assigned',
        payload: { traceId, payload: eventPayload },
        status: 'pending',
        attempt_count: 0,
        max_attempts: Number(process.env.OUTBOX_MAX_ATTEMPTS || 10),
        next_retry_at: now,
        processing_started_at: null,
        processing_owner: null,
        last_error: null,
        last_error_at: null,
        dlq_topic: null,
        dlq_payload: null,
        occurred_at: now,
        created_at: now,
        updated_at: now
      };

      await db.collection('outbox_events').insertOne(outboxDoc, insertOptions);
    }

    return rideDoc;
  });

  const mapped = mapRide(updatedRide);
  if (!mapped) {
    const fallback = await getRideById(id);
    return fallback;
  }
  return mapped;
}

async function updateRideFields(id, fields) {
  const updates = {};

  if (fields.bookingId !== undefined) {
    updates.booking_id = fields.bookingId ? String(fields.bookingId).trim() : null;
  }

  if (fields.riderId !== undefined) {
    updates.rider_id = normalizeIdentityId(fields.riderId);
  }

  if (fields.driverId !== undefined) {
    updates.driver_id = normalizeIdentityId(fields.driverId);
  }

  if (fields.pickupLat !== undefined) {
    updates.pickup_lat = fields.pickupLat;
  }

  if (fields.pickupLng !== undefined) {
    updates.pickup_lng = fields.pickupLng;
  }

  if (fields.pickupLabel !== undefined) {
    updates.pickup_label = typeof fields.pickupLabel === 'string' && fields.pickupLabel.trim() ? fields.pickupLabel.trim() : null;
  }

  if (fields.dropoffLat !== undefined) {
    updates.dropoff_lat = fields.dropoffLat;
  }

  if (fields.dropoffLng !== undefined) {
    updates.dropoff_lng = fields.dropoffLng;
  }

  if (fields.dropoffLabel !== undefined) {
    updates.dropoff_label = typeof fields.dropoffLabel === 'string' && fields.dropoffLabel.trim() ? fields.dropoffLabel.trim() : null;
  }

  if (fields.quoteFareAmount !== undefined) {
    updates.quote_fare_amount = Number.isFinite(Number(fields.quoteFareAmount)) ? Math.round(Number(fields.quoteFareAmount)) : null;
  }

  if (fields.quoteCurrency !== undefined) {
    updates.quote_currency =
      typeof fields.quoteCurrency === 'string' && fields.quoteCurrency.trim() ? fields.quoteCurrency.trim().toUpperCase() : null;
  }

  if (!Object.keys(updates).length) {
    return getRideById(id);
  }

  updates.updated_at = new Date();

  const db = await getDb();
  const result = await db.collection('rides').findOneAndUpdate({ _id: id }, { $set: updates }, { returnDocument: 'after' });

  return mapRide(unwrapFindOneAndUpdateResult(result));
}

async function addStatusHistory({ rideId, fromStatus = null, toStatus, reason = null, actorId = null, traceId = null, occurredAt = null }) {
  const db = await getDb();
  const now = new Date();
  await db.collection('ride_status_history').insertOne({
    _id: crypto.randomUUID(),
    ride_id: rideId,
    from_status: fromStatus ? String(fromStatus).toLowerCase() : null,
    to_status: String(toStatus).toLowerCase(),
    reason,
    actor_id: normalizeIdentityId(actorId),
    trace_id: traceId,
    occurred_at: occurredAt ? new Date(occurredAt) : now,
    created_at: now,
    updated_at: now
  });
}

async function getRideStatusHistory(rideId) {
  const db = await getDb();
  const docs = await db.collection('ride_status_history').find({ ride_id: rideId }).sort({ occurred_at: 1, _id: 1 }).toArray();
  return docs.map((doc) => ({
    id: doc._id,
    ride_id: doc.ride_id,
    from_status: doc.from_status,
    to_status: doc.to_status,
    reason: doc.reason || null,
    actor_id: doc.actor_id || null,
    trace_id: doc.trace_id || null,
    occurred_at: doc.occurred_at,
    created_at: doc.created_at,
    updated_at: doc.updated_at
  }));
}

async function listRides({ limit = 20, cursor = null, status = null, riderId = null, driverId = null, sort = '-created_at' } = {}) {
  const db = await getDb();
  const isDesc = sort === '-created_at' || sort === '-createdAt';
  const normalizedRiderId = normalizeIdentityId(riderId);
  const normalizedDriverId = normalizeIdentityId(driverId);

  const filter = {};
  if (status) {
    filter.status = status;
  }
  if (normalizedRiderId) {
    filter.rider_id = normalizedRiderId;
  }
  if (normalizedDriverId) {
    filter.driver_id = normalizedDriverId;
  }

  const cursorFilter = buildCursorFilter({
    cursor,
    isDesc
  });
  if (cursorFilter) {
    filter.$and = filter.$and || [];
    filter.$and.push(cursorFilter);
  }

  const sortSpec = {
    created_at: isDesc ? -1 : 1,
    _id: isDesc ? -1 : 1
  };

  const docs = await db.collection('rides').find(filter).sort(sortSpec).limit(limit).toArray();

  return docs.map(mapRide);
}

async function claimRideForDriver({ driverId, traceId = null } = {}) {
  const normalizedDriverId = normalizeIdentityId(driverId);
  if (!normalizedDriverId) {
    return null;
  }

  const db = await getDb();
  const now = new Date();

  return runWithOptionalTransaction(async (session) => {
    const updateOptions = {
      sort: { created_at: 1, _id: 1 },
      returnDocument: 'after'
    };
    if (session) {
      updateOptions.session = session;
    }

    const rideResult = await db.collection('rides').findOneAndUpdate(
      buildAssignableRideFilter(),
      {
        $set: {
          driver_id: normalizedDriverId,
          status: 'assigned',
          status_updated_at: now,
          updated_at: now
        }
      },
      updateOptions
    );

    const rideDoc = unwrapFindOneAndUpdateResult(rideResult);
    if (!rideDoc) {
      return null;
    }

    const insertOptions = session ? { session } : {};
    await db.collection('ride_status_history').insertOne(
      {
        _id: crypto.randomUUID(),
        ride_id: rideDoc._id,
        from_status: 'requested',
        to_status: 'assigned',
        reason: 'driver_claimed',
        actor_id: normalizedDriverId,
        trace_id: traceId,
        occurred_at: now,
        created_at: now,
        updated_at: now
      },
      insertOptions
    );

    const eventId = crypto.randomUUID();
    const outboxDoc = {
      _id: crypto.randomUUID(),
      event_id: eventId,
      aggregate_type: 'ride',
      aggregate_id: rideDoc._id,
      event_type: 'RideAssigned',
      topic: 'ride.assigned',
      payload: {
        traceId,
        payload: {
          rideId: rideDoc._id,
          driverId: normalizedDriverId,
          assignedAt: now
        }
      },
      status: 'pending',
      attempt_count: 0,
      max_attempts: Number(process.env.OUTBOX_MAX_ATTEMPTS || 10),
      next_retry_at: now,
      processing_started_at: null,
      processing_owner: null,
      last_error: null,
      last_error_at: null,
      dlq_topic: null,
      dlq_payload: null,
      occurred_at: now,
      created_at: now,
      updated_at: now
    };

    await db.collection('outbox_events').insertOne(outboxDoc, insertOptions);

    return mapRide(rideDoc);
  });
}

async function findNextRequestedRide() {
  const db = await getDb();
  const doc = await db.collection('rides').findOne(
    buildAssignableRideFilter(),
    { sort: { created_at: -1, _id: -1 } } // lấy ride mới nhất còn pending
  );
  return doc ? mapRide(doc) : null;
}

module.exports = {
  createRide,
  getRideById,
  getRideByExternalId,
  getActiveRideForDriver,
  updateRideStatus,
  updateRideFields,
  addStatusHistory,
  getRideStatusHistory,
  listRides,
  claimRideForDriver,
  findNextRequestedRide
};
