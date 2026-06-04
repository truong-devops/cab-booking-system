import { apiRequest } from '../lib/api';
import { endpoints } from '../lib/endpoints';
import { createIdempotencyKey } from '../utils/idempotency';

export type Ride = {
  id: string;
  externalRideId?: string | null;
  bookingId?: string | null;
  riderId?: string | null;
  driverId?: string | null;
  pickupLat?: number | null;
  pickupLng?: number | null;
  pickupLabel?: string | null;
  dropoffLat?: number | null;
  dropoffLng?: number | null;
  dropoffLabel?: string | null;
  quoteFareAmount?: number | null;
  quoteCurrency?: string | null;
  status: string;
  statusUpdatedAt?: string;
  createdAt?: string;
  updatedAt?: string;
};

export type RideListResponse = {
  data: Ride[];
  nextCursor?: string | null;
};

type CreateRidePayload = {
  externalRideId?: string;
  bookingId?: string;
  pickupLat: number;
  pickupLng: number;
  pickupLabel?: string;
  dropoffLat?: number;
  dropoffLng?: number;
  dropoffLabel?: string;
  quoteFareAmount?: number;
  quoteCurrency?: string;
  status?: string;
};

export type RideSummary = {
  rideId: string;
  status: string;
  distanceMeters?: number | null;
  durationSeconds?: number | null;
  fare?: {
    amount?: number | null;
    currency?: string | null;
    paymentStatus?: string | null;
    paymentId?: string | null;
    method?: string | null;
    source?: string | null;
  };
  breakdown?: {
    baseFare?: number;
    distanceFee?: number;
    timeFee?: number;
    surgeFee?: number;
    discount?: number;
    subtotal?: number;
    total?: number;
    currency?: string;
  };
};

export async function createRide(payload: CreateRidePayload) {
  return apiRequest<{ data: Ride }>({
    method: 'POST',
    path: endpoints.ride.list,
    headers: {
      'Idempotency-Key': createIdempotencyKey('ride')
    },
    body: payload
  });
}

type RideListParams = {
  limit?: number;
  cursor?: string;
  status?: string;
  riderId?: string | null;
};

export async function listRides({ limit = 20, cursor, status, riderId }: RideListParams = {}) {
  return apiRequest<RideListResponse>({
    method: 'GET',
    path: endpoints.ride.list,
    params: {
      limit,
      cursor,
      status: status ? status.toLowerCase() : undefined,
      riderId: riderId ?? undefined
    }
  });
}

export async function getRide(id: string) {
  return apiRequest<{ data: Ride }>({
    method: 'GET',
    path: endpoints.ride.detail(id)
  });
}

export async function getRideSummary(id: string) {
  return apiRequest<{ data: RideSummary }>({
    method: 'GET',
    path: endpoints.ride.summary(id)
  });
}

export async function updateRideStatus(id: string, status: string) {
  return apiRequest<{ data: Ride }>({
    method: 'PATCH',
    path: endpoints.ride.update(id),
    body: { status }
  });
}

export async function cancelRide(id: string, reason?: string) {
  return apiRequest<{ data: Ride }>({
    method: 'DELETE',
    path: endpoints.ride.detail(id),
    body: reason ? { reason } : undefined
  });
}
