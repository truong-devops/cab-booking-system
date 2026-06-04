import type { ApiError } from '../lib/api';
import type { DriverInfo, LocationPoint, RideHistoryItem, RideOption, RidePriceBreakdown } from '../mock/data';
import { destinationPoints, pickupPoint } from '../mock/data';
import * as authApi from './authApi';
import * as bookingApi from './bookingApi';
import { getDriverProfileById } from './driverApi';
import * as etaApi from './etaApi';
import * as paymentApi from './paymentApi';
import * as pricingApi from './pricingApi';
import * as reviewApi from './reviewApi';
import * as rideApi from './rideApi';

type StartRidePayload = {
  pickupLabel: string;
  destinationLabel: string;
  vehicleOptionId?: string;
  quoteFareAmount?: number;
  quoteCurrency?: string;
};

type LivePickup = {
  latitude: number;
  longitude: number;
};

let livePickupCoordinate: LivePickup | null = null;

function isApiError(error: unknown): error is ApiError {
  return Boolean(error && typeof error === 'object' && 'status' in error);
}

function normalizeIdentifier(identifier: string) {
  return identifier.trim().toLowerCase();
}

function normalizePrice(value: number) {
  return Math.max(Math.round(value), 12000);
}

function toFiniteNumber(value: unknown, fallback = 0) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return parsed;
}

function normalizeEta(value: unknown, fallback: number) {
  const parsed = Math.round(toFiniteNumber(value, fallback));
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return Math.max(fallback, 2);
  }
  return Math.max(parsed, 2);
}

function buildPriceBreakdown(quote: pricingApi.QuoteData, total: number): RidePriceBreakdown {
  const distanceKm = Math.max(toFiniteNumber(quote.distanceKm, 0), 0);
  const durationMin = Math.max(toFiniteNumber(quote.durationMin, 0), 0);
  const baseFare = Math.max(Math.round(toFiniteNumber(quote.breakdown?.base, 0)), 0);
  const perKm = Math.max(toFiniteNumber(quote.breakdown?.perKm, 0), 0);
  const perMin = Math.max(toFiniteNumber(quote.breakdown?.perMin, 0), 0);
  const distanceFee = Math.max(Math.round(perKm * distanceKm), 0);
  const timeFee = Math.max(Math.round(perMin * durationMin), 0);
  const surgeFee = Math.max(Math.round(toFiniteNumber(quote.breakdown?.surge, 0)), 0);
  const discount = Math.max(Math.round(toFiniteNumber(quote.breakdown?.discount, 0)), 0);
  const subtotal = Math.max(Math.round(baseFare + distanceFee + timeFee), 0);

  return {
    baseFare,
    distanceFee,
    timeFee,
    surgeFee,
    discount,
    subtotal,
    total,
    distanceKm: Number(distanceKm.toFixed(2)),
    durationMin: Math.max(Math.round(durationMin), 0),
    currency: quote.currency || 'VND'
  };
}

function scaleBreakdown(source: RidePriceBreakdown, factor: number, total: number): RidePriceBreakdown {
  const safeFactor = Number.isFinite(factor) && factor > 0 ? factor : 1;

  return {
    ...source,
    baseFare: Math.max(Math.round(source.baseFare * safeFactor), 0),
    distanceFee: Math.max(Math.round(source.distanceFee * safeFactor), 0),
    timeFee: Math.max(Math.round(source.timeFee * safeFactor), 0),
    surgeFee: Math.max(Math.round(source.surgeFee * safeFactor), 0),
    discount: Math.max(Math.round(source.discount * safeFactor), 0),
    subtotal: Math.max(Math.round(source.subtotal * safeFactor), 0),
    total
  };
}

function getSurgeMeta(price: number, breakdown: RidePriceBreakdown) {
  if (!breakdown.surgeFee) {
    return { surgeLabel: undefined, surgeMultiplier: undefined };
  }

  const baseFare = Math.max(price - breakdown.surgeFee, 1);
  const multiplier = Number((price / baseFare).toFixed(2));
  if (!Number.isFinite(multiplier) || multiplier <= 1) {
    return { surgeLabel: undefined, surgeMultiplier: undefined };
  }

  return {
    surgeLabel: `Cao điểm x${multiplier.toFixed(2)}`,
    surgeMultiplier: multiplier
  };
}

function toMethodCode(method: string): 'CASH' | 'WALLET' | 'VIETQR' {
  const normalized = method.trim().toUpperCase();

  // Keep backend stable: CARD is routed via WALLET flow in Payment Service.
  if (normalized === 'CARD' || normalized === 'WALLET' || normalized === 'VI') return 'WALLET';
  if (normalized === 'VIETQR' || normalized === 'QR') return 'VIETQR';
  if (normalized === 'CASH') return 'CASH';

  // Backward compatibility for old UI labels.
  const legacy = method.trim().toLowerCase();
  if (legacy.includes('wallet') || legacy.includes('the')) return 'WALLET';
  if (legacy.includes('vietqr') || legacy.includes('qr')) return 'VIETQR';
  return 'CASH';
}

function isEightDigitId(value: string | undefined) {
  if (!value) return false;
  return /^\d{8}$/.test(value);
}

function isNonEmptyString(value: string | undefined) {
  return typeof value === 'string' && value.trim().length > 0;
}

function buildUserName(identifier: string, user: authApi.AuthUser) {
  if (user.username && user.username.trim()) return user.username.trim();
  if (user.email && user.email.trim()) return user.email.trim();
  return identifier;
}

function buildPhone(identifier: string) {
  const normalized = identifier.trim();
  return normalized.includes('@') ? 'Không có' : normalized;
}

function getDestinationPointOrThrow(label: string): LocationPoint {
  const point = destinationPoints.find((item) => item.label === label);
  if (!point) {
    throw new Error(`Không tìm thấy tọa độ điểm đến: ${label}`);
  }
  return point;
}

function getPickupPointOrThrow(label: string): LocationPoint {
  if (label === pickupPoint.label) {
    if (!livePickupCoordinate) {
      throw new Error('Không lấy được tọa độ điểm đón. Vui lòng bật GPS và thử lại.');
    }
    return {
      label,
      lat: livePickupCoordinate.latitude,
      lng: livePickupCoordinate.longitude
    };
  }

  const point = destinationPoints.find((item) => item.label === label);
  if (!point) {
    throw new Error(`Không tìm thấy tọa độ điểm đón: ${label}`);
  }
  return point;
}

function formatLocation(lat?: number | null, lng?: number | null) {
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return '-';
  }
  return `${Number(lat).toFixed(4)}, ${Number(lng).toFixed(4)}`;
}

function ensureNumberCoordinate(value: number | null | undefined, field: string) {
  if (!Number.isFinite(value)) {
    throw new Error(`Dữ liệu ${field} không hợp lệ từ backend`);
  }
  return Number(value);
}

function mapVehicleTypeFromOption(optionId?: string): bookingApi.BookingVehicleType {
  const normalized = String(optionId || '').trim().toLowerCase();
  if (normalized === 'bike') return 'BIKE';
  if (normalized === 'car7') return 'SUV';
  return 'CAR';
}

function resolveBookingId(payload: bookingApi.CreateBookingResponse) {
  const booking = payload?.booking;
  if (!booking) return null;
  const bookingId = booking.bookingId || booking.booking_id || null;
  return typeof bookingId === 'string' && bookingId.trim() ? bookingId.trim() : null;
}

function resolveBookingRideId(payload: bookingApi.CreateBookingResponse) {
  const booking = payload?.booking;
  if (!booking) return null;
  const rideId = booking.rideId || booking.ride_id || null;
  return typeof rideId === 'string' && rideId.trim() ? rideId.trim() : null;
}

function parseTimestamp(value: string | null | undefined) {
  if (!value) return 0;
  const ts = Date.parse(value);
  return Number.isFinite(ts) ? ts : 0;
}

function getRidePaymentKeys(ride: rideApi.Ride) {
  return Array.from(
    new Set([ride.id, ride.externalRideId, ride.bookingId].map((value) => (typeof value === 'string' ? value.trim() : '')).filter(Boolean))
  );
}

function getRoundedPositiveAmount(value: unknown) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const rounded = Math.round(parsed);
  return rounded > 0 ? rounded : null;
}

function getSummaryFareAmount(summary: rideApi.RideSummary | null | undefined) {
  return getRoundedPositiveAmount(summary?.fare?.amount) ?? getRoundedPositiveAmount(summary?.breakdown?.total);
}

function getPaymentsForRide(ride: rideApi.Ride, paymentsByRideId: Record<string, paymentApi.Payment[]>) {
  const seen = new Set<string>();
  return getRidePaymentKeys(ride)
    .flatMap((key) => paymentsByRideId[key] || [])
    .filter((payment) => {
      const dedupKey = payment.id || `${payment.rideId}:${payment.createdAt}:${payment.amount}`;
      if (seen.has(dedupKey)) return false;
      seen.add(dedupKey);
      return true;
    });
}

async function moveRideToStatus(rideId: string, status: string) {
  try {
    return await rideApi.updateRideStatus(rideId, status);
  } catch (error) {
    if (isApiError(error) && error.status === 409) {
      return null;
    }
    throw error;
  }
}

export const customerApi = {
  setLivePickupLocation(latitude: number, longitude: number) {
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return;
    livePickupCoordinate = { latitude, longitude };
  },

  getLivePickupLocation() {
    return livePickupCoordinate;
  },

  async requestOtp(identifier: string) {
    await authApi.healthCheck();
    return { ok: Boolean(identifier.trim()) };
  },

  async verifyOtp(identifier: string, otp: string) {
    const normalizedIdentifier = normalizeIdentifier(identifier);
    const password = otp.trim();
    if (!normalizedIdentifier) {
      throw new Error('Thiếu số điện thoại/email');
    }
    if (!password) {
      throw new Error('Thiếu OTP/mật khẩu');
    }

    let authResult: authApi.AuthResponse;
    try {
      authResult = await authApi.login(normalizedIdentifier, password);
    } catch (error) {
      if (isApiError(error) && error.status === 401) {
        authResult = await authApi.register(normalizedIdentifier, password);
      } else {
        throw error;
      }
    }

    return {
      accessToken: authResult.tokens.accessToken,
      refreshToken: authResult.tokens.refreshToken,
      user: {
        id: authResult.data.id,
        name: buildUserName(normalizedIdentifier, authResult.data),
        phone: buildPhone(normalizedIdentifier)
      }
    };
  },

  async getRideOptions(pickupLabel: string, destinationLabel: string): Promise<RideOption[]> {
    const pickup = getPickupPointOrThrow(pickupLabel);
    const destination = getDestinationPointOrThrow(destinationLabel);

    const [standardQuote, premiumQuote, etaEstimate] = await Promise.all([
      pricingApi.createQuote(pickup, destination, 'STANDARD'),
      pricingApi.createQuote(pickup, destination, 'PREMIUM'),
      etaApi.estimateEta(pickup, destination).catch(() => null)
    ]);

    const standardFare = Number(standardQuote.data.estimatedFare || 0);
    const premiumFare = Number(premiumQuote.data.estimatedFare || 0);
    const etaServiceMinutes = Math.round(toFiniteNumber(etaEstimate?.data?.eta_minutes, 0));
    const standardEta = etaServiceMinutes > 0 ? Math.max(etaServiceMinutes, 2) : normalizeEta(standardQuote.data.durationMin, 6);
    const premiumEta = Math.max(normalizeEta(premiumQuote.data.durationMin, 8), standardEta + 1);

    const bikePrice = normalizePrice(standardFare * 0.55);
    const car4Price = normalizePrice(standardFare);
    const car7Price = normalizePrice(premiumFare);

    const car4Breakdown = buildPriceBreakdown(standardQuote.data, car4Price);
    const car7Breakdown = buildPriceBreakdown(premiumQuote.data, car7Price);
    const bikeBreakdown = scaleBreakdown(car4Breakdown, bikePrice / Math.max(car4Price, 1), bikePrice);

    const bikeSurge = getSurgeMeta(bikePrice, bikeBreakdown);
    const car4Surge = getSurgeMeta(car4Price, car4Breakdown);
    const car7Surge = getSurgeMeta(car7Price, car7Breakdown);

    return [
      {
        id: 'bike',
        name: 'Xe máy',
        etaMinutes: Math.max(standardEta - 2, 2),
        price: bikePrice,
        capacity: 1,
        vehicleIcon: 'motorbike.fill',
        surgeLabel: bikeSurge.surgeLabel,
        surgeMultiplier: bikeSurge.surgeMultiplier,
        priceBreakdown: bikeBreakdown,
        quoteId: standardQuote.data.quoteId,
        serviceType: 'STANDARD'
      },
      {
        id: 'car4',
        name: 'Xe 4 chỗ',
        etaMinutes: standardEta,
        price: car4Price,
        capacity: 4,
        vehicleIcon: 'car.fill',
        surgeLabel: car4Surge.surgeLabel,
        surgeMultiplier: car4Surge.surgeMultiplier,
        priceBreakdown: car4Breakdown,
        quoteId: standardQuote.data.quoteId,
        serviceType: 'STANDARD'
      },
      {
        id: 'car7',
        name: 'Xe 7 chỗ',
        etaMinutes: premiumEta,
        price: car7Price,
        capacity: 7,
        vehicleIcon: 'car.fill',
        surgeLabel: car7Surge.surgeLabel,
        surgeMultiplier: car7Surge.surgeMultiplier,
        priceBreakdown: car7Breakdown,
        quoteId: premiumQuote.data.quoteId,
        serviceType: 'PREMIUM'
      }
    ];
  },

  async startRide({ pickupLabel, destinationLabel, vehicleOptionId, quoteFareAmount, quoteCurrency }: StartRidePayload) {
    const pickup = getPickupPointOrThrow(pickupLabel);
    const destination = getDestinationPointOrThrow(destinationLabel);
    const bookingPayload = {
      pickup: { lat: pickup.lat, lng: pickup.lng, address: pickupLabel },
      dropoff: { lat: destination.lat, lng: destination.lng, address: destinationLabel },
      vehicleType: mapVehicleTypeFromOption(vehicleOptionId)
    };

    let bookingId: string | null = null;
    let bookingRideId: string | null = null;
    try {
      let booking = await bookingApi.createBooking(bookingPayload);
      if (!resolveBookingId(booking)) {
        throw new Error('Dịch vụ booking không trả về mã booking');
      }
      bookingId = resolveBookingId(booking);
      bookingRideId = resolveBookingRideId(booking);
      if (!bookingId) {
        throw new Error('Dịch vụ booking không trả về mã booking');
      }
    } catch (error) {
      if (isApiError(error) && error.code === 'ACTIVE_BOOKING_RELEASED_RETRY') {
        try {
          const booking = await bookingApi.createBooking(bookingPayload);
          bookingId = resolveBookingId(booking);
          bookingRideId = resolveBookingRideId(booking);
        } catch (retryError) {
          if (isApiError(retryError) && retryError.code === 'ACTIVE_BOOKING_EXISTS') {
            throw new Error('Bạn đang có booking đang hoạt động. Vui lòng hoàn tất hoặc hủy chuyến trước.');
          }
          throw retryError;
        }
        if (!bookingId) {
          throw new Error('Dịch vụ booking không trả về mã booking');
        }
      }
      if (isApiError(error) && error.code === 'ACTIVE_BOOKING_EXISTS') {
        throw new Error('Bạn đang có booking đang hoạt động. Vui lòng hoàn tất hoặc hủy chuyến trước.');
      }
      if (!bookingId) {
        throw error;
      }
    }

    const created = await rideApi.createRide({
      externalRideId: bookingRideId || undefined,
      bookingId,
      pickupLat: pickup.lat,
      pickupLng: pickup.lng,
      pickupLabel,
      dropoffLat: destination.lat,
      dropoffLng: destination.lng,
      dropoffLabel: destinationLabel,
      quoteFareAmount,
      quoteCurrency,
      status: 'requested'
    });

    const ride = created.data;
    const ridePickupLat = ensureNumberCoordinate(ride.pickupLat, 'pickupLat');
    const ridePickupLng = ensureNumberCoordinate(ride.pickupLng, 'pickupLng');
    const rideDropoffLat = ensureNumberCoordinate(ride.dropoffLat, 'dropoffLat');
    const rideDropoffLng = ensureNumberCoordinate(ride.dropoffLng, 'dropoffLng');

    const driver: DriverInfo | null = null;

    return {
      ride,
      driver,
      pickup: {
        label: ride.pickupLabel || pickupLabel,
        lat: ridePickupLat,
        lng: ridePickupLng
      },
      destination: {
        label: ride.dropoffLabel || destinationLabel,
        lat: rideDropoffLat,
        lng: rideDropoffLng
      }
    };
  },

  async cancelRide(rideId: string, bookingId?: string | null) {
    const normalizedRideId = String(rideId || '').trim();
    const normalizedBookingId = String(bookingId || '').trim();
    if (!normalizedRideId) {
      throw new Error('Mã chuyến đi không hợp lệ để hủy chuyến');
    }

    let bookingCancelled = false;
    let rideCancelled = false;
    let lastError: unknown = null;

    if (normalizedBookingId) {
      try {
        await bookingApi.cancelBooking(normalizedBookingId);
        bookingCancelled = true;
      } catch (error) {
        lastError = error;
      }
    }

    try {
      await rideApi.cancelRide(normalizedRideId, 'CANCELLED_BY_CUSTOMER');
      rideCancelled = true;
    } catch (error) {
      const maybeApiError = error as ApiError;
      // Accept already-ended cases to keep UX stable.
      if (isApiError(maybeApiError) && (maybeApiError.status === 404 || maybeApiError.status === 409)) {
        rideCancelled = true;
      } else {
        lastError = error;
      }
    }

    if (!bookingCancelled && !rideCancelled) {
      throw (lastError as Error) || new Error('Không thể hủy chuyến đi lúc này');
    }

    return { bookingCancelled, rideCancelled };
  },

  async createPayment(rideId: string, method: string, amount: number) {
    await moveRideToStatus(rideId, 'ARRIVING');
    await moveRideToStatus(rideId, 'IN_PROGRESS');
    await moveRideToStatus(rideId, 'COMPLETED');

    return paymentApi.createPayment({
      rideId,
      amount: normalizePrice(amount).toFixed(2),
      currency: 'VND',
      method: toMethodCode(method)
    });
  },

  async submitRating(rideId: string, driverId: string | undefined, stars: number, comment: string, tipAmount?: number | null) {
    const normalizedRideId = String(rideId || '').trim();
    if (!isNonEmptyString(normalizedRideId)) {
      throw new Error('Mã chuyến đi không hợp lệ');
    }
    const normalizedDriverId = typeof driverId === 'string' ? driverId.trim() : '';
    if (!isEightDigitId(normalizedDriverId)) {
      throw new Error('Mã tài xế không hợp lệ');
    }
    return reviewApi.createReview({
      rideId: normalizedRideId,
      driverId: normalizedDriverId,
      rating: stars,
      comment: comment.trim() || undefined,
      tipAmount: typeof tipAmount === 'number' && Number.isFinite(tipAmount) ? Math.max(Math.round(tipAmount), 0) : undefined
    });
  },

  async getHistory(riderId?: string | null): Promise<RideHistoryItem[]> {
    if (!riderId) return [];
    const [ridesResult, paymentsResult, reviewsResult] = await Promise.all([
      rideApi.listRides({ limit: 50, riderId }),
      paymentApi.listPayments(100),
      reviewApi.listReviews(100).catch(() => ({ data: [] as reviewApi.Review[] }))
    ]);

    const paymentsByRideId = (paymentsResult.data || []).reduce<Record<string, paymentApi.Payment[]>>((acc, payment) => {
      const key = String(payment.rideId || '').trim();
      if (!key) {
        return acc;
      }
      if (!acc[key]) {
        acc[key] = [];
      }
      acc[key].push(payment);
      return acc;
    }, {});
    const reviewsByRideId = (reviewsResult.data || []).reduce<Record<string, reviewApi.Review>>((acc, review) => {
      if (!review?.rideId) return acc;
      const current = acc[review.rideId];
      if (!current || parseTimestamp(review.createdAt) >= parseTimestamp(current.createdAt)) {
        acc[review.rideId] = review;
      }
      return acc;
    }, {});

    const rows = ridesResult.data || [];
    const filtered = rows.filter((ride) => {
      const status = String(ride.status || '').toLowerCase();
      return status === 'completed' || status === 'cancelled';
    });

    const summaryEntries = await Promise.all(
      filtered.map(async (ride) => {
        if (String(ride.status || '').toLowerCase() !== 'completed') {
          return [ride.id, null] as const;
        }
        try {
          const summary = await rideApi.getRideSummary(ride.id);
          return [ride.id, summary.data] as const;
        } catch {
          return [ride.id, null] as const;
        }
      })
    );
    const summaryByRideId = summaryEntries.reduce<Record<string, rideApi.RideSummary | null>>((acc, [rideId, summary]) => {
      acc[rideId] = summary;
      return acc;
    }, {});

    const uniqueDriverIds = Array.from(new Set(filtered.map((ride) => String(ride.driverId || '').trim()).filter(Boolean)));
    const driverProfiles = await Promise.all(
      uniqueDriverIds.map(async (driverId) => {
        try {
          const profile = await getDriverProfileById(driverId);
          return [
            driverId,
            {
              name: profile.data.driver?.fullName || null,
              phone: profile.data.driver?.phone || null,
              vehicleType: profile.data.vehicle?.vehicleType || null,
              plateNumber: profile.data.vehicle?.plateNumber || null
            }
          ] as const;
        } catch {
          return [driverId, null] as const;
        }
      })
    );
    const driverProfileById = Object.fromEntries(driverProfiles);

    return filtered.map((ride) => {
      const ridePayments = getPaymentsForRide(ride, paymentsByRideId);
      const rideReview = reviewsByRideId[ride.id] || null;
      const paymentTotal = Math.round(
        ridePayments.reduce((sum, payment) => {
          const value = Number(payment.amount || 0);
          return sum + (Number.isFinite(value) ? value : 0);
        }, 0)
      );
      const summary = summaryByRideId[ride.id] || null;
      const summaryAmount = getSummaryFareAmount(summary);
      const quoteAmount = getRoundedPositiveAmount(ride.quoteFareAmount);
      const amount = summaryAmount ?? (paymentTotal || quoteAmount || 0);

      const latestPayment = [...ridePayments].sort((a, b) => parseTimestamp(b.createdAt) - parseTimestamp(a.createdAt))[0] || null;
      const normalizedDriverId = String(ride.driverId || '').trim() || null;
      const profile = normalizedDriverId ? (driverProfileById[normalizedDriverId] as any) : null;

      return {
        id: ride.id,
        externalRideId: ride.externalRideId || null,
        bookingId: ride.bookingId || null,
        riderId: ride.riderId || null,
        date: (ride.createdAt || new Date().toISOString()).slice(0, 16).replace('T', ' '),
        pickup: ride.pickupLabel || formatLocation(ride.pickupLat, ride.pickupLng),
        destination: ride.dropoffLabel || formatLocation(ride.dropoffLat, ride.dropoffLng),
        amount,
        status: String(ride.status || '').toLowerCase() === 'cancelled' ? 'cancelled' : 'completed',
        rideStatusRaw: ride.status || null,
        rideStatusUpdatedAt: ride.statusUpdatedAt || null,
        rideCreatedAt: ride.createdAt || null,
        rideUpdatedAt: ride.updatedAt || null,
        pickupLat: ride.pickupLat ?? null,
        pickupLng: ride.pickupLng ?? null,
        dropoffLat: ride.dropoffLat ?? null,
        dropoffLng: ride.dropoffLng ?? null,
        paymentId: latestPayment?.id || null,
        paymentMethod: latestPayment?.method || null,
        paymentStatus: summary?.fare?.paymentStatus || latestPayment?.status || null,
        paymentCurrency: summary?.fare?.currency || latestPayment?.currency || ride.quoteCurrency || null,
        paymentAmount: latestPayment ? Number(latestPayment.amount || 0) : null,
        paymentCreatedAt: latestPayment?.createdAt || null,
        paymentUpdatedAt: latestPayment?.updatedAt || null,
        driverId: normalizedDriverId,
        driverName: profile?.name || null,
        driverPhone: profile?.phone || null,
        vehicleType: profile?.vehicleType || null,
        plateNumber: profile?.plateNumber || null,
        reviewId: rideReview?.id || null,
        reviewRating: Number.isFinite(Number(rideReview?.rating)) ? Number(rideReview?.rating) : null,
        reviewComment: rideReview?.comment || null,
        reviewTipAmount: Number.isFinite(Number(rideReview?.tipAmount)) ? Number(rideReview?.tipAmount) : null,
        reviewStatus: rideReview?.status || null,
        reviewCreatedAt: rideReview?.createdAt || null,
        reviewUpdatedAt: rideReview?.updatedAt || null
      };
    });
  }
};


