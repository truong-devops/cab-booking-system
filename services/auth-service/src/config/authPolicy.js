const DEFAULT_ROLES = ['user', 'admin', 'ops', 'driver'];
const DEFAULT_PUBLIC_REGISTER_ROLES = ['user', 'driver'];

function parseRoles(value, fallback) {
  const source = value == null || value === '' ? fallback.join(',') : value;
  return String(source)
    .split(',')
    .map((role) => role.trim())
    .filter(Boolean);
}

const AUTH_ROLES = parseRoles(process.env.AUTH_ROLES, DEFAULT_ROLES);
const PUBLIC_REGISTER_ROLES = parseRoles(process.env.AUTH_PUBLIC_REGISTER_ROLES, DEFAULT_PUBLIC_REGISTER_ROLES)
  .filter((role) => AUTH_ROLES.includes(role));

function normalizeRole(role) {
  if (!role) {
    return '';
  }
  return String(role).trim();
}

function resolvePublicRegisterRole(role) {
  const requestedRole = normalizeRole(role) || 'user';
  if (!AUTH_ROLES.includes(requestedRole) || !PUBLIC_REGISTER_ROLES.includes(requestedRole)) {
    return null;
  }
  return requestedRole;
}

function getDevMagicPassword() {
  if (process.env.NODE_ENV === 'production') {
    return null;
  }
  return process.env.DEV_MAGIC_PASSWORD || null;
}

module.exports = {
  AUTH_ROLES,
  PUBLIC_REGISTER_ROLES,
  getDevMagicPassword,
  parseRoles,
  resolvePublicRegisterRole
};
