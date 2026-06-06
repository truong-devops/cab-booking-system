function resolveApiBaseUrl() {
  if (import.meta.env.VITE_API_BASE_URL) return import.meta.env.VITE_API_BASE_URL;
  if (typeof window !== 'undefined' && window.location?.origin) return window.location.origin;
  return '';
}

const API_BASE_URL = resolveApiBaseUrl().replace(/\/+$/, '');
export const isMock = import.meta.env.VITE_MOCK === 'true';

function getToken() {
  return localStorage.getItem('admin_token');
}

export async function apiRequest(path, options = {}) {
  const token = getToken();
  const { headers: optionHeaders, cache: optionCache, ...rest } = options;
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...(optionHeaders || {})
  };

  const response = await fetch(`${API_BASE_URL}${path}`, {
    cache: optionCache ?? 'no-store',
    ...rest,
    headers
  });

  if (response.status === 304) {
    return null;
  }

  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = { message: text };
    }
  }

  if (!response.ok) {
    const message = payload?.error?.message || payload?.message || 'Yêu cầu thất bại';
    const error = new Error(message);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }

  return payload;
}
