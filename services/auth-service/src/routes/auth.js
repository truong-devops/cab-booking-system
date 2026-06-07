const express = require('express');
const { asyncHandler } = require('../utils/asyncHandler');
const { ApiError } = require('../utils/errors');
const {
  hashPassword,
  verifyPassword,
  signAccessToken,
  generateRefreshToken,
  hashRefreshToken,
  buildRefreshExpiry,
  ACCESS_TOKEN_EXPIRES_IN,
  verifyAccessToken
} = require('../utils/security');
const { revokeAccessToken, isAccessTokenRevoked } = require('../utils/revokedAccessTokenStore');
const { createUser, findUserByIdentifier, findUserById } = require('../repository/userRepository');
const { createRefreshToken, findRefreshToken, deleteRefreshToken } = require('../repository/tokenRepository');
const { toUser8 } = require('../utils/identity');
const { getDevMagicPassword, resolvePublicRegisterRole } = require('../config/authPolicy');
const monitoring = require('../monitoring');

const router = express.Router();

router.post(
  '/register',
  asyncHandler(async (req, res) => {
    const { email, username, password, role, name } = req.body || {};
    if (!email && !username) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'register',
        outcome: 'error',
        attributes: { reason: 'missing_identifier' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'email or username is required');
    }
    if (!password || password.length < 6) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'register',
        outcome: 'error',
        attributes: { reason: 'invalid_password' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'password must be at least 6 characters');
    }
    const requestedRole = resolvePublicRegisterRole(role);
    if (!requestedRole) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'register',
        outcome: 'error',
        attributes: { reason: 'invalid_role' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'role is not allowed');
    }

    const existingIdentifier = email || username;
    const existing = await findUserByIdentifier(existingIdentifier);
    if (existing) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'register',
        outcome: 'error',
        attributes: { reason: 'user_exists' }
      });
      throw new ApiError(409, 'CONFLICT', 'User already exists');
    }

    const passwordHash = await hashPassword(password);
    let user;
    try {
      user = await createUser({
        email: email || null,
        username: username || name || null,
        passwordHash,
        role: requestedRole,
        status: 'active'
      });
    } catch (error) {
      if (error?.code === '23505') {
        monitoring.recordBusinessEvent({
          domain: 'auth',
          event: 'register',
          outcome: 'error',
          attributes: { reason: 'user_exists' }
        });
        throw new ApiError(409, 'CONFLICT', 'User already exists');
      }
      throw error;
    }

    const accessToken = signAccessToken({
      userId: toUser8(user.id),
      role: user.role
    });
    const refreshToken = generateRefreshToken();
    await createRefreshToken({
      userId: user.id,
      tokenHash: hashRefreshToken(refreshToken),
      expiresAt: buildRefreshExpiry()
    });
    monitoring.recordBusinessEvent({
      domain: 'auth',
      event: 'register',
      outcome: 'success',
      attributes: {
        role: String(user.role || 'unknown').toLowerCase()
      }
    });

    return res.status(201).json({
      data: {
        id: toUser8(user.id),
        user_id: toUser8(user.id),
        email: user.email,
        username: user.username,
        role: user.role,
        status: user.status,
        createdAt: user.created_at
      },
      tokens: {
        accessToken,
        refreshToken,
        expiresIn: ACCESS_TOKEN_EXPIRES_IN
      }
    });
  })
);

router.post(
  '/login',
  asyncHandler(async (req, res) => {
    const { identifier: rawIdentifier, email, username, password } = req.body || {};
    const identifier = rawIdentifier || email || username;
    if (!identifier || !password) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'login',
        outcome: 'error',
        attributes: { reason: 'missing_credentials' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'identifier and password are required');
    }

    const user = await findUserByIdentifier(identifier);
    if (!user) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'login',
        outcome: 'error',
        attributes: { reason: 'user_not_found' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Invalid credentials');
    }
    if (user.status !== 'active') {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'login',
        outcome: 'error',
        attributes: { reason: 'user_inactive' }
      });
      throw new ApiError(403, 'FORBIDDEN', 'User is not active');
    }

    const magicPassword = getDevMagicPassword();
    const valid = Boolean(magicPassword && password === magicPassword) || (await verifyPassword(password, user.password_hash));
    if (!valid) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'login',
        outcome: 'error',
        attributes: { reason: 'invalid_password' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Invalid credentials');
    }

    const accessToken = signAccessToken({
      userId: toUser8(user.id),
      role: user.role
    });
    const refreshToken = generateRefreshToken();
    await createRefreshToken({
      userId: user.id,
      tokenHash: hashRefreshToken(refreshToken),
      expiresAt: buildRefreshExpiry()
    });
    monitoring.recordBusinessEvent({
      domain: 'auth',
      event: 'login',
      outcome: 'success',
      attributes: {
        role: String(user.role || 'unknown').toLowerCase()
      }
    });

    return res.json({
      data: {
        id: toUser8(user.id),
        user_id: toUser8(user.id),
        email: user.email,
        username: user.username,
        role: user.role,
        status: user.status,
        createdAt: user.created_at
      },
      tokens: {
        accessToken,
        refreshToken,
        expiresIn: ACCESS_TOKEN_EXPIRES_IN
      }
    });
  })
);

router.post(
  '/refresh',
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body || {};
    if (!refreshToken) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'refresh',
        outcome: 'error',
        attributes: { reason: 'missing_refresh_token' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'refreshToken is required');
    }

    const tokenHash = hashRefreshToken(refreshToken);
    const stored = await findRefreshToken(tokenHash);
    if (!stored) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'refresh',
        outcome: 'error',
        attributes: { reason: 'token_not_found' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Invalid refresh token');
    }

    const expiredAt = new Date(stored.expired_at);
    if (Number.isNaN(expiredAt.valueOf()) || expiredAt < new Date()) {
      await deleteRefreshToken(tokenHash);
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'refresh',
        outcome: 'error',
        attributes: { reason: 'token_expired' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Refresh token expired');
    }

    const user = await findUserById(stored.user_id);
    if (!user) {
      await deleteRefreshToken(tokenHash);
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'refresh',
        outcome: 'error',
        attributes: { reason: 'user_not_found' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'User not found');
    }

    await deleteRefreshToken(tokenHash);

    const accessToken = signAccessToken({
      userId: toUser8(user.id),
      role: user.role
    });
    const nextRefreshToken = generateRefreshToken();
    await createRefreshToken({
      userId: user.id,
      tokenHash: hashRefreshToken(nextRefreshToken),
      expiresAt: buildRefreshExpiry()
    });
    monitoring.recordBusinessEvent({
      domain: 'auth',
      event: 'refresh',
      outcome: 'success',
      attributes: {
        role: String(user.role || 'unknown').toLowerCase()
      }
    });

    return res.json({
      data: {
        id: toUser8(user.id),
        user_id: toUser8(user.id),
        email: user.email,
        username: user.username,
        role: user.role,
        status: user.status,
        createdAt: user.created_at
      },
      tokens: {
        accessToken,
        refreshToken: nextRefreshToken,
        expiresIn: ACCESS_TOKEN_EXPIRES_IN
      }
    });
  })
);

router.post(
  '/logout',
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body || {};
    const authHeader = req.header('authorization') || '';
    const [, accessToken] = authHeader.split(' ');

    if (!refreshToken && !accessToken) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'logout',
        outcome: 'error',
        attributes: { reason: 'missing_credentials' }
      });
      throw new ApiError(400, 'VALIDATION_ERROR', 'refreshToken or access token is required');
    }

    if (refreshToken) {
      const tokenHash = hashRefreshToken(refreshToken);
      await deleteRefreshToken(tokenHash);
    }
    if (accessToken) {
      try {
        const payload = verifyAccessToken(accessToken);
        revokeAccessToken(accessToken, payload?.exp);
      } catch (_error) {
        // Best-effort revoke for malformed/expired token.
        revokeAccessToken(accessToken);
      }
    }
    monitoring.recordBusinessEvent({
      domain: 'auth',
      event: 'logout',
      outcome: 'success'
    });
    return res.json({ ok: true });
  })
);

router.get(
  '/verify',
  asyncHandler(async (req, res) => {
    const authHeader = req.header('authorization') || '';
    const [, token] = authHeader.split(' ');
    if (!token) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'verify',
        outcome: 'error',
        attributes: { reason: 'missing_token' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Missing token');
    }

    try {
      const payload = verifyAccessToken(token);
      if (isAccessTokenRevoked(token)) {
        throw new Error('token_revoked');
      }
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'verify',
        outcome: 'success'
      });
      return res.json({
        data: {
          userId: payload.sub || payload.id,
          role: payload.role || null,
          roles: Array.isArray(payload.roles) ? payload.roles : []
        }
      });
    } catch (error) {
      monitoring.recordBusinessEvent({
        domain: 'auth',
        event: 'verify',
        outcome: 'error',
        attributes: { reason: 'invalid_token' }
      });
      throw new ApiError(401, 'UNAUTHORIZED', 'Invalid token');
    }
  })
);

module.exports = router;
