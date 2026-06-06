import axios from 'axios';

function resolveApiBaseUrl() {
  if (import.meta.env.VITE_API_BASE_URL) return import.meta.env.VITE_API_BASE_URL;
  if (typeof window !== 'undefined' && window.location?.origin) return window.location.origin;
  return '';
}

const baseURL = resolveApiBaseUrl().replace(/\/+$/, '');

const api = axios.create({ baseURL, withCredentials: true });

api.interceptors.request.use((config) => {
  const token = localStorage.getItem('accessToken');
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

let isRefreshing = false;
let queue = [];

api.interceptors.response.use(
  (res) => res,
  async (err) => {
    const original = err.config;

    if (err.response?.status === 401 && !original._retry) {
      original._retry = true;

      if (isRefreshing) {
        return new Promise((resolve, reject) => queue.push({ resolve, reject, original }));
      }

      isRefreshing = true;
      try {
        const refreshToken = localStorage.getItem('refreshToken');
        if (!refreshToken) {
          throw new Error('Missing refresh token');
        }

        const refreshRes = await axios.post(`${baseURL}/v1/auth/refresh`, { refreshToken }, { withCredentials: true });
        const nextAccessToken = refreshRes.data?.tokens?.accessToken;
        const nextRefreshToken = refreshRes.data?.tokens?.refreshToken || refreshToken;

        if (!nextAccessToken) {
          throw new Error('Refresh response missing access token');
        }

        localStorage.setItem('accessToken', nextAccessToken);
        localStorage.setItem('refreshToken', nextRefreshToken);

        queue.forEach((p) => p.resolve(api(p.original)));
        queue = [];

        return api(original);
      } catch (e) {
        queue.forEach((p) => p.reject(e));
        queue = [];
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
        window.location.href = '/admin/login';
        return Promise.reject(e);
      } finally {
        isRefreshing = false;
      }
    }

    return Promise.reject(err);
  }
);

export default api;
