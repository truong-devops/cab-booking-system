const SERVICE_URLS = {
  rides: process.env.RIDE_SERVICE_URL || 'http://ride-service:3005',
  users: process.env.USER_SERVICE_URL || 'http://user-service:4004',
  driver: process.env.DRIVER_SERVICE_URL || 'http://driver-service:3011',
  drivers: process.env.DRIVER_SERVICE_URL || 'http://driver-service:3011',
  internal: process.env.DRIVER_SERVICE_URL || 'http://driver-service:3011',
  admin: process.env.DRIVER_SERVICE_URL || 'http://driver-service:3011',
  bookings: process.env.BOOKING_SERVICE_URL || 'http://booking-service:3003',
  eta: process.env.ETA_SERVICE_URL || 'http://eta-service:3012',
  places: process.env.PLACES_SERVICE_URL || 'http://places-service:3014',
  pricing: process.env.PRICING_SERVICE_URL || 'http://pricing-service:3006',
  ai: process.env.AI_SERVICE_URL || 'http://ai-service:3013',
  payments: process.env.PAYMENT_SERVICE_URL || 'http://payment-service:3007',
  reviews: process.env.REVIEW_SERVICE_URL || 'http://review-service:3009',
  auth: process.env.AUTH_SERVICE_URL || 'http://auth-service:4001',
  notifications: process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service:3010'
};

module.exports = { SERVICE_URLS };
