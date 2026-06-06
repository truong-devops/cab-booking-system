import Constants from 'expo-constants';

function inferApiBaseUrl() {
  const fromEnv = process.env.EXPO_PUBLIC_API_BASE_URL;
  if (fromEnv && fromEnv.trim()) {
    return fromEnv.trim().replace(/\/+$/, '');
  }

  if (typeof window !== 'undefined' && window.location?.origin) {
    return window.location.origin.replace(/\/+$/, '');
  }

  // Fallback: use host from Expo dev server (LAN/tunnel)
  const hostUri = Constants.expoConfig?.hostUri || '';
  const host = hostUri.split(':')[0];
  if (host) {
    return `http://${host}:42100`;
  }

  return '';
}

export const API_BASE_URL = inferApiBaseUrl();
export const WS_BASE_URL = process.env.EXPO_PUBLIC_WS_URL || '';

export function requireApiBaseUrl() {
  if (!API_BASE_URL) {
    throw new Error('Missing EXPO_PUBLIC_API_BASE_URL');
  }
  return API_BASE_URL;
}
