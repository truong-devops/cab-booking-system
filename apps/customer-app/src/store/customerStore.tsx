import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import type { DriverInfo, RideHistoryItem, RideOption } from '../mock/data';
import { setOnAuthFailure } from '../lib/api';
import { clearTokens, getRefreshToken, hydrateTokens, setTokens } from '../lib/token-store';
import * as authApi from '../services/authApi';
import { customerApi } from '../services/customerApi';
import { getDriverProfileById } from '../services/driverApi';
import * as rideApi from '../services/rideApi';
import * as userApi from '../services/userApi';

type User = {
  id: string;
  name: string;
  phone: string;
  email?: string | null;
};

type ActiveRide = {
  id: string;
  bookingId?: string | null;
  status?: string | null;
  pickup: string;
  destination: string;
  pickupLat: number;
  pickupLng: number;
  dropoffLat: number;
  dropoffLng: number;
  option: RideOption;
  driver: DriverInfo | null;
  etaMinutes: number;
  driverId?: string | null;
};

const MIN_REFRESH_GAP_MS = 4000;
const RATE_LIMIT_BACKOFF_MS = 30000;

function normalizeIdentifier(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  return normalized || null;
}

function isEightDigitId(value: string | null | undefined): boolean {
  const normalized = normalizeIdentifier(value);
  if (!normalized) return false;
  return /^\d{8}$/.test(normalized);
}

function resolvePreferredDriverId(...values: Array<string | null | undefined>): string | null {
  const normalizedValues = values.map((value) => normalizeIdentifier(value)).filter((value): value is string => Boolean(value));
  if (!normalizedValues.length) return null;

  const eightDigitValue = normalizedValues.find((value) => isEightDigitId(value));
  return eightDigitValue || normalizedValues[0];
}

function toFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function isRateLimitError(error: unknown): boolean {
  return Boolean(error && typeof error === 'object' && 'status' in error && Number((error as { status?: unknown }).status) === 429);
}

type CustomerContextValue = {
  bootstrapped: boolean;
  authenticated: boolean;
  user: User | null;
  destination: string;
  selectedOption: RideOption | null;
  activeRide: ActiveRide | null;
  history: RideHistoryItem[];
  walletBalance: number;
  setDestination: (destination: string) => void;
  login: (identifier: string, otp: string) => Promise<void>;
  logout: () => Promise<void>;
  loadHistory: () => Promise<void>;
  updateProfile: (data: Partial<Pick<User, 'name' | 'email' | 'phone'>>) => Promise<void>;
  chooseOption: (option: RideOption) => void;
  startRide: (pickup: string, destination: string) => Promise<void>;
  cancelActiveRide: () => Promise<void>;
  assignDriverToActiveRide: (driverId: string) => void;
  refreshActiveRide: () => Promise<ActiveRide | null>;
  decreaseEta: () => void;
  completeRidePayment: (method: string, amount?: number) => Promise<void>;
  submitRating: (stars: number, comment: string, tipAmount?: number | null) => Promise<void>;
};

const CustomerContext = createContext<CustomerContextValue | undefined>(undefined);

export const CustomerProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [bootstrapped, setBootstrapped] = useState(false);
  const [authenticated, setAuthenticated] = useState(false);
  const [user, setUser] = useState<User | null>(null);
  const [destination, setDestination] = useState('');
  const [selectedOption, setSelectedOption] = useState<RideOption | null>(null);
  const [activeRide, setActiveRide] = useState<ActiveRide | null>(null);
  const activeRideRef = useRef<ActiveRide | null>(null);
  const [history, setHistory] = useState<RideHistoryItem[]>([]);
  const [walletBalance] = useState(450000);
  const refreshInFlightRef = useRef(false);
  const refreshBlockedUntilRef = useRef(0);
  const lastRefreshAtRef = useRef(0);

  const resetState = useCallback(() => {
    setAuthenticated(false);
    setUser(null);
    setDestination('');
    setSelectedOption(null);
    setActiveRide(null);
    setHistory([]);
    refreshInFlightRef.current = false;
    refreshBlockedUntilRef.current = 0;
    lastRefreshAtRef.current = 0;
  }, []);

  const logout = useCallback(async () => {
    const refreshToken = getRefreshToken();
    if (refreshToken) {
      try {
        await authApi.logout(refreshToken);
      } catch {
        // ignore logout failures during client cleanup
      }
    }

    await clearTokens();
    resetState();
  }, [resetState]);

  const syncUserFromProfile = useCallback(async (identifier: string, userId: string) => {
    try {
      const profile = await userApi.getUserById(userId);
      setAuthenticated(true);
      setUser({
        id: profile.data.id,
        name: profile.data.fullName || identifier,
        phone: profile.data.phone || (identifier.includes('@') ? 'Không có' : identifier),
        email: profile.data.email
      });
    } catch {
      setAuthenticated(true);
      setUser({
        id: userId,
        name: identifier,
        phone: identifier.includes('@') ? 'Không có' : identifier
      });
    }
  }, []);

  const login = useCallback(
    async (identifier: string, otp: string) => {
      const normalizedIdentifier = typeof identifier === 'string' ? identifier.trim() : '';
      const normalizedCredential = typeof otp === 'string' ? otp.trim() : '';
      if (!normalizedIdentifier) {
        throw new Error('Thiếu số điện thoại/email.');
      }
      if (!normalizedCredential) {
        throw new Error('Thiếu OTP/mật khẩu.');
      }

      const result = await customerApi.verifyOtp(normalizedIdentifier, normalizedCredential);
      await setTokens(result.accessToken, result.refreshToken);

      try {
        const verified = await authApi.verify();
        await syncUserFromProfile(result.user.name, verified.data.userId);
      } catch {
        setAuthenticated(true);
        setUser(result.user);
      }
    },
    [syncUserFromProfile]
  );

  useEffect(() => {
    setOnAuthFailure(() => {
      void logout();
    });
    return () => setOnAuthFailure(null);
  }, [logout]);

  useEffect(() => {
    activeRideRef.current = activeRide;
  }, [activeRide]);

  useEffect(() => {
    let mounted = true;

    hydrateTokens()
      .then(async ({ accessToken }) => {
        if (!mounted || !accessToken) return;

        try {
          const verified = await authApi.verify();
          if (!mounted) return;
          await syncUserFromProfile('Khách hàng', verified.data.userId);
        } catch {
          await clearTokens();
          if (mounted) {
            resetState();
          }
        }
      })
      .finally(() => {
        if (mounted) {
          setBootstrapped(true);
        }
      });

    return () => {
      mounted = false;
    };
  }, [resetState, syncUserFromProfile]);

  const loadHistory = useCallback(async () => {
    if (!user?.id) {
      setHistory([]);
      return;
    }
    const items = await customerApi.getHistory(user.id);
    setHistory(items);
  }, [user?.id]);

  const chooseOption = useCallback((option: RideOption) => {
    setSelectedOption(option);
  }, []);

  const updateProfile = useCallback(
    async (data: Partial<Pick<User, 'name' | 'email' | 'phone'>>) => {
      if (!user?.id) throw new Error('Không tìm thấy người dùng');
      const updated = await userApi.updateUser(user.id, {
        fullName: data.name ?? user.name,
        email: data.email ?? user.email ?? undefined,
        phone: data.phone ?? user.phone
      });
      setUser({
        id: updated.data.id,
        name: updated.data.fullName || user.name,
        phone: updated.data.phone || user.phone,
        email: updated.data.email || user.email
      });
    },
    [user]
  );

  const hydrateDriverProfile = useCallback(async (lookupDriverId: string) => {
    const normalizedLookupId = normalizeIdentifier(lookupDriverId);
    if (!normalizedLookupId) return;

    const applyDriverSnapshot = (input: {
      canonicalDriverId?: string | null;
      fullName?: string | null;
      vehicleType?: string | null;
      plate?: string | null;
      phone?: string | null;
    }) => {
      const canonicalDriverId = normalizeIdentifier(input.canonicalDriverId);
      setActiveRide((prev) => {
        if (!prev) return prev;

        const prevDriverId = normalizeIdentifier(prev.driverId);
        const prevDriverSnapshotId = normalizeIdentifier(prev.driver?.id);
        const isCurrentDriverMatched =
          !prevDriverId ||
          prevDriverId === normalizedLookupId ||
          (canonicalDriverId ? prevDriverId === canonicalDriverId : false) ||
          prevDriverSnapshotId === normalizedLookupId ||
          (canonicalDriverId ? prevDriverSnapshotId === canonicalDriverId : false);

        if (!isCurrentDriverMatched) return prev;

        const resolvedDriverId = resolvePreferredDriverId(canonicalDriverId, prevDriverSnapshotId, prevDriverId, normalizedLookupId);
        if (!resolvedDriverId) return prev;

        const resolvedName = input.fullName?.trim() || prev.driver?.name || 'Tài xế';
        const resolvedPhone = input.phone?.trim() || prev.driver?.phone || undefined;
        return {
          ...prev,
          driverId: resolvedDriverId,
          driver: {
            id: resolvedDriverId,
            name: resolvedName,
            rating: prev.driver?.rating,
            vehicle: input.vehicleType?.trim() || prev.driver?.vehicle || undefined,
            plate: input.plate?.trim() || prev.driver?.plate || undefined,
            phone: resolvedPhone
          }
        };
      });
    };

    try {
      const profile = await getDriverProfileById(normalizedLookupId);
      applyDriverSnapshot({
        canonicalDriverId: profile.data.driver?.id || null,
        fullName: profile.data.driver?.fullName || null,
        vehicleType: profile.data.vehicle?.vehicleType || null,
        plate: profile.data.vehicle?.plateNumber || null,
        phone: profile.data.driver?.phone || null
      });
      return;
    } catch {
      // Continue with user-service fallback for environments where ride.driverId is userId
    }

    try {
      const userProfile = await userApi.getUserById(normalizedLookupId);
      applyDriverSnapshot({
        canonicalDriverId: null,
        fullName: userProfile.data.fullName || null,
        phone: userProfile.data.phone || null
      });
    } catch {
      // Keep state unchanged when both profile sources are unavailable
    }
  }, []);

  const startRide = useCallback(
    async (pickup: string, destinationValue: string) => {
      if (!selectedOption) {
        throw new Error('Chưa chọn loại xe');
      }

      const result = await customerApi.startRide({
        pickupLabel: pickup,
        destinationLabel: destinationValue,
        vehicleOptionId: selectedOption.id,
        quoteFareAmount: selectedOption.price,
        quoteCurrency: selectedOption.priceBreakdown?.currency || 'VND'
      });

      setActiveRide({
        id: result.ride.id,
        bookingId: result.ride.bookingId || null,
        status: result.ride.status || null,
        pickup: result.pickup.label,
        destination: result.destination.label,
        pickupLat: result.pickup.lat,
        pickupLng: result.pickup.lng,
        dropoffLat: result.destination.lat,
        dropoffLng: result.destination.lng,
        option: selectedOption,
        driver: result.driver,
        etaMinutes: selectedOption.etaMinutes,
        driverId: result.ride.driverId || null
      });

      if (result.ride.driverId) {
        void hydrateDriverProfile(result.ride.driverId);
      }
    },
    [hydrateDriverProfile, selectedOption]
  );

  const cancelActiveRide = useCallback(async () => {
    const ride = activeRideRef.current;
    if (!ride?.id) return;
    await customerApi.cancelRide(ride.id, ride.bookingId || null);
    setActiveRide(null);
  }, []);

  const assignDriverToActiveRide = useCallback(
    (driverId: string) => {
      if (!driverId) return;
      setActiveRide((prev) => {
        if (!prev) return prev;
        return {
          ...prev,
          driverId
        };
      });
      void hydrateDriverProfile(driverId);
    },
    [hydrateDriverProfile]
  );

  const refreshActiveRide = useCallback(async () => {
    if (!activeRide?.id) return null;

    if (activeRide.driverId && !activeRide.driver) {
      void hydrateDriverProfile(activeRide.driverId);
    }

    const now = Date.now();
    if (refreshInFlightRef.current) return activeRide;
    if (refreshBlockedUntilRef.current > now) return activeRide;
    if (now - lastRefreshAtRef.current < MIN_REFRESH_GAP_MS) return activeRide;

    refreshInFlightRef.current = true;
    lastRefreshAtRef.current = now;

    try {
      const response = await rideApi.getRide(activeRide.id);
      refreshBlockedUntilRef.current = 0;
      const serverRide = response.data;
      const serverDriverId = serverRide.driverId || null;
      const resolvedDriverId = resolvePreferredDriverId(serverDriverId, activeRide.driver?.id || null, activeRide.driverId || null);
      const resolvedDriver = resolvedDriverId && activeRide.driver?.id === resolvedDriverId ? activeRide.driver : null;
      const nextPickupLat = toFiniteNumber(serverRide.pickupLat) ?? activeRide.pickupLat;
      const nextPickupLng = toFiniteNumber(serverRide.pickupLng) ?? activeRide.pickupLng;
      const nextDropoffLat = toFiniteNumber(serverRide.dropoffLat) ?? activeRide.dropoffLat;
      const nextDropoffLng = toFiniteNumber(serverRide.dropoffLng) ?? activeRide.dropoffLng;
      const nextPickup = typeof serverRide.pickupLabel === 'string' && serverRide.pickupLabel.trim() ? serverRide.pickupLabel : activeRide.pickup;
      const nextDestination =
        typeof serverRide.dropoffLabel === 'string' && serverRide.dropoffLabel.trim() ? serverRide.dropoffLabel : activeRide.destination;

      const nextRide: ActiveRide = {
        ...activeRide,
        bookingId: serverRide.bookingId || activeRide.bookingId || null,
        status: serverRide.status || activeRide.status || null,
        pickup: nextPickup,
        destination: nextDestination,
        pickupLat: nextPickupLat,
        pickupLng: nextPickupLng,
        dropoffLat: nextDropoffLat,
        dropoffLng: nextDropoffLng,
        driverId: resolvedDriverId,
        driver: resolvedDriver
      };

      setActiveRide((prev) => {
        if (!prev || prev.id !== activeRide.id) return prev;
        return {
          ...prev,
          bookingId: serverRide.bookingId || prev.bookingId || null,
          status: serverRide.status || prev.status || null,
          pickup: nextPickup,
          destination: nextDestination,
          pickupLat: nextPickupLat,
          pickupLng: nextPickupLng,
          dropoffLat: nextDropoffLat,
          dropoffLng: nextDropoffLng,
          driverId: resolvedDriverId,
          driver: resolvedDriver
        };
      });

      if (resolvedDriverId && !resolvedDriver) {
        void hydrateDriverProfile(resolvedDriverId);
      }

      return nextRide;
    } catch (error) {
      if (isRateLimitError(error)) {
        refreshBlockedUntilRef.current = Date.now() + RATE_LIMIT_BACKOFF_MS;
      }
      return activeRide;
    } finally {
      refreshInFlightRef.current = false;
    }
  }, [activeRide, hydrateDriverProfile]);

  const decreaseEta = useCallback(() => {
    setActiveRide((prev) => (prev ? { ...prev, etaMinutes: Math.max(prev.etaMinutes - 1, 1) } : prev));
  }, []);

  const completeRidePayment = useCallback(
    async (method: string, amount?: number) => {
      if (!activeRide) throw new Error('Không có chuyến đi đang hoạt động');
      const paymentAmount = typeof amount === 'number' && Number.isFinite(amount) ? amount : activeRide.option.price;
      await customerApi.createPayment(activeRide.id, method, paymentAmount);
    },
    [activeRide]
  );

  const submitRating = useCallback(
    async (stars: number, comment: string, tipAmount?: number | null) => {
      if (!activeRide) throw new Error('Không có chuyến đi đang hoạt động');
      let reviewDriverId = resolvePreferredDriverId(activeRide.driver?.id, activeRide.driverId);
      if (!reviewDriverId) throw new Error('Chưa có dữ liệu tài xế từ hệ thống');

      try {
        const latestRide = await rideApi.getRide(activeRide.id);
        reviewDriverId = resolvePreferredDriverId(latestRide.data?.driverId || null, reviewDriverId);
      } catch {
        // Keep current id when latest ride fetch fails.
      }

      if (!isEightDigitId(reviewDriverId)) {
        try {
          const profile = await getDriverProfileById(reviewDriverId);
          reviewDriverId = resolvePreferredDriverId(profile.data.driver?.id, reviewDriverId);
        } catch {
          // Keep current id for customerApi normalization fallback.
        }
      }

      await customerApi.submitRating(activeRide.id, reviewDriverId, stars, comment, tipAmount);

      setHistory((prev) => [
        {
          id: activeRide.id,
          date: new Date().toISOString().slice(0, 16).replace('T', ' '),
          pickup: activeRide.pickup,
          destination: activeRide.destination,
          amount: activeRide.option.price,
          status: 'completed',
          reviewRating: stars,
          reviewComment: comment.trim() || null,
          reviewTipAmount: typeof tipAmount === 'number' && Number.isFinite(tipAmount) ? Math.max(Math.round(tipAmount), 0) : null,
          reviewStatus: 'submitted',
          reviewCreatedAt: new Date().toISOString(),
          reviewUpdatedAt: new Date().toISOString()
        },
        ...prev.filter((item) => item.id !== activeRide.id)
      ]);

      setSelectedOption(null);
      setActiveRide(null);
      setDestination('');
    },
    [activeRide]
  );

  const value = useMemo(
    () => ({
      bootstrapped,
      authenticated,
      user,
      destination,
      selectedOption,
      activeRide,
      history,
      walletBalance,
      setDestination,
      login,
      logout,
      loadHistory,
      updateProfile,
      chooseOption,
      startRide,
      cancelActiveRide,
      assignDriverToActiveRide,
      refreshActiveRide,
      decreaseEta,
      completeRidePayment,
      submitRating
    }),
    [
      bootstrapped,
      authenticated,
      user,
      destination,
      selectedOption,
      activeRide,
      history,
      walletBalance,
      login,
      logout,
      loadHistory,
      updateProfile,
      chooseOption,
      startRide,
      cancelActiveRide,
      assignDriverToActiveRide,
      refreshActiveRide,
      decreaseEta,
      completeRidePayment,
      submitRating
    ]
  );

  return <CustomerContext.Provider value={value}>{children}</CustomerContext.Provider>;
};

export const useCustomerStore = () => {
  const ctx = useContext(CustomerContext);
  if (!ctx) throw new Error('useCustomerStore phải được dùng trong CustomerProvider');
  return ctx;
};
