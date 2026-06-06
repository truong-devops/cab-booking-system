import Constants from 'expo-constants';

function inferApiBaseUrl() {
  const fromEnv = process.env.EXPO_PUBLIC_API_BASE_URL;
  if (fromEnv && fromEnv.trim()) {
    return fromEnv.trim().replace(/\/+$/, '');
  }

  if (typeof window !== 'undefined' && window.location?.hostname) {
    return window.location.origin.replace(/\/+$/, '');
  }

  const hostUri = Constants.expoConfig?.hostUri || '';
  const host = hostUri.split(':')[0];
  if (host) {
    return `http://${host}:42100`;
  }

  return 'http://127.0.0.1:42100';
}

export const API_BASE_URL = inferApiBaseUrl();

export function requireApiBaseUrl() {
  if (!API_BASE_URL) {
    throw new Error('Thiếu địa chỉ API base URL');
  }
  return API_BASE_URL;
}
