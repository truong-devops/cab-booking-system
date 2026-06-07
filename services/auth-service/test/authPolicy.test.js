const AUTH_ENV_KEYS = [
  'AUTH_PUBLIC_REGISTER_ROLES',
  'AUTH_ROLES',
  'DEV_MAGIC_PASSWORD',
  'NODE_ENV'
];

const ORIGINAL_ENV = process.env;

function loadPolicy(overrides = {}) {
  process.env = { ...ORIGINAL_ENV };
  AUTH_ENV_KEYS.forEach((key) => {
    delete process.env[key];
  });
  Object.entries(overrides).forEach(([key, value]) => {
    if (value == null) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  });
  jest.resetModules();
  return require('../src/config/authPolicy');
}

afterEach(() => {
  process.env = ORIGINAL_ENV;
  jest.resetModules();
});

describe('auth policy', () => {
  test('allows only public registration roles by default', () => {
    const { PUBLIC_REGISTER_ROLES, resolvePublicRegisterRole } = loadPolicy();

    expect(PUBLIC_REGISTER_ROLES).toEqual(['user', 'driver']);
    expect(resolvePublicRegisterRole()).toBe('user');
    expect(resolvePublicRegisterRole('user')).toBe('user');
    expect(resolvePublicRegisterRole('driver')).toBe('driver');
    expect(resolvePublicRegisterRole('admin')).toBeNull();
    expect(resolvePublicRegisterRole('ops')).toBeNull();
  });

  test('honors explicit public registration roles without allowing unknown roles', () => {
    const { PUBLIC_REGISTER_ROLES, resolvePublicRegisterRole } = loadPolicy({
      AUTH_ROLES: 'user,driver,admin',
      AUTH_PUBLIC_REGISTER_ROLES: 'user,admin,unknown'
    });

    expect(PUBLIC_REGISTER_ROLES).toEqual(['user', 'admin']);
    expect(resolvePublicRegisterRole('admin')).toBe('admin');
    expect(resolvePublicRegisterRole('unknown')).toBeNull();
  });

  test('disables dev magic password unless explicitly configured outside production', () => {
    expect(loadPolicy().getDevMagicPassword()).toBeNull();
    expect(loadPolicy({ DEV_MAGIC_PASSWORD: 'local-only' }).getDevMagicPassword()).toBe('local-only');
    expect(loadPolicy({ NODE_ENV: 'production', DEV_MAGIC_PASSWORD: 'local-only' }).getDevMagicPassword()).toBeNull();
  });
});
