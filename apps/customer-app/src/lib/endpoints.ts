export const endpoints = {
  health: '/health',
  auth: {
    register: '/v1/auth/register',
    login: '/v1/auth/login',
    refresh: '/v1/auth/refresh',
    logout: '/v1/auth/logout',
    verify: '/v1/auth/verify'
  },
  pricing: {
    quotes: '/v1/pricing/quotes'
  },
  eta: {
    estimate: '/v1/eta/estimate'
  },
  ride: {
    list: '/v1/rides',
    detail: (id: string) => `/v1/rides/${id}`,
    update: (id: string) => `/v1/rides/${id}`,
    summary: (id: string) => `/v1/rides/${id}/summary`
  },
  booking: {
    create: '/v1/bookings',
    list: '/v1/bookings',
    detail: (id: string) => `/v1/bookings/${id}`,
    cancel: (id: string) => `/v1/bookings/${id}/cancel`
  },
  payment: {
    list: '/v1/payments',
    create: '/v1/payments',
    detail: (id: string) => `/v1/payments/${id}`,
    vietqr: (id: string) => `/v1/payments/${id}/vietqr-codes`
  },
  places: {
    autocomplete: '/v1/places/autocomplete',
    recent: '/v1/places/recent'
  },
  review: {
    list: '/v1/reviews',
    create: '/v1/reviews'
  },
  driver: {
    availability: '/v1/driver/availability'
  },
  drivers: {
    profile: (driverId: string) => `/v1/drivers/${driverId}/profile`
  },
  user: {
    detail: (id: string) => `/v1/users/${id}`
  }
};
