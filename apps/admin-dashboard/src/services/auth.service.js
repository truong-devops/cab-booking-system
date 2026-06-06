import { apiRequest, isMock } from './api.service.js';
import { mockUser } from './mock.data.js';

function resolveApiBaseUrl() {
  if (import.meta.env.VITE_API_BASE_URL) return import.meta.env.VITE_API_BASE_URL;
  if (typeof window !== 'undefined' && window.location?.origin) return window.location.origin;
  return '';
}

const GATEWAY_BASE_URL = resolveApiBaseUrl().replace(/\/+$/, '');
const AUTH_BASE_URL = (import.meta.env.VITE_AUTH_SERVICE_URL || GATEWAY_BASE_URL).replace(/\/+$/, '');

function toDirectAuthUrl(path) {
  const base = String(AUTH_BASE_URL || '').replace(/\/+$/, '');
  return `${base}${path}`;
}

function shouldFallbackToDirectAuth(error, path) {
  const status = Number(error?.status || 0);
  const message = String(error?.message || '').toLowerCase();
  if (status === 0) {
    return message.includes('failed to fetch') || message.includes('networkerror') || message.includes('network request failed');
  }
  if (status !== 404) return false;
  return message.includes('cannot post') || message.includes('cannot get') || message.includes(path.toLowerCase());
}

function withNetworkContext(error) {
  const status = Number(error?.status || 0);
  if (status !== 0) {
    return error;
  }

  const gatewayBase = GATEWAY_BASE_URL;
  const err = new Error(`Khong ket noi duoc backend. Kiem tra API Gateway (${gatewayBase}) hoac AUTH service (${AUTH_BASE_URL}).`);
  err.status = 0;
  err.payload = error?.payload || null;
  return err;
}

async function directAuthRequest(path, { method = 'GET', token, body } = {}) {
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {})
  };

  const response = await fetch(toDirectAuthUrl(path), {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined
  });

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
    const message = payload?.error?.message || payload?.message || 'Yeu cau that bai';
    const err = new Error(message);
    err.status = response.status;
    err.payload = payload;
    throw err;
  }

  return payload;
}

export const authService = {
  async login({ email, password }) {
    if (isMock) {
      return { token: 'mock-token', user: mockUser };
    }

    let payload;
    let lastError = null;
    try {
      payload = await apiRequest('/v1/auth/login', {
        method: 'POST',
        body: JSON.stringify({ identifier: email, password })
      });
    } catch (error) {
      lastError = error;
      if (shouldFallbackToDirectAuth(error, '/v1/auth/login')) {
        try {
          payload = await apiRequest('/auth/login', {
            method: 'POST',
            body: JSON.stringify({ identifier: email, password })
          });
        } catch (fallbackError) {
          lastError = fallbackError;
          try {
            payload = await directAuthRequest('/auth/login', {
              method: 'POST',
              body: { identifier: email, password }
            });
          } catch (directError) {
            lastError = directError;
          }
        }
      }

      if (!payload) {
        throw withNetworkContext(lastError);
      }
    }

    const user = payload?.data;
    return {
      token: payload?.tokens?.accessToken,
      user: user
        ? {
            id: user.id,
            email: user.email,
            role: user.role,
            roles: user.roles || [user.role]
          }
        : null
    };
  },

  async register({ email, password, role = 'admin' }) {
    if (isMock) {
      const id = `mock-${role}-${Date.now()}`;
      return {
        data: {
          id,
          user_id: id,
          email,
          role
        },
        success: true
      };
    }

    try {
      return await apiRequest('/v1/auth/register', {
        method: 'POST',
        body: JSON.stringify({ email, password, role })
      });
    } catch (error) {
      let lastError = error;
      if (shouldFallbackToDirectAuth(error, '/v1/auth/register')) {
        try {
          return await apiRequest('/auth/register', {
            method: 'POST',
            body: JSON.stringify({ email, password, role })
          });
        } catch (fallbackError) {
          lastError = fallbackError;
          try {
            return await directAuthRequest('/auth/register', {
              method: 'POST',
              body: { email, password, role }
            });
          } catch (directError) {
            lastError = directError;
          }
        }
      }
      throw withNetworkContext(lastError);
    }
  },

  async me(token) {
    if (isMock) {
      return { user: mockUser };
    }

    try {
      let payload;
      try {
        payload = await apiRequest('/v1/auth/verify', {
          headers: token ? { Authorization: `Bearer ${token}` } : {}
        });
      } catch (error) {
        if (!shouldFallbackToDirectAuth(error, '/v1/auth/verify')) {
          throw error;
        }
        try {
          payload = await apiRequest('/auth/verify', {
            headers: token ? { Authorization: `Bearer ${token}` } : {}
          });
        } catch {
          payload = await directAuthRequest('/auth/verify', {
            method: 'GET',
            token
          });
        }
      }

      return {
        user: payload?.data
          ? {
              id: payload.data.userId,
              email: payload.data.email,
              role: payload.data.role,
              roles: payload.data.roles || [payload.data.role]
            }
          : null
      };
    } catch (error) {
      return null;
    }
  }
};
