CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE SEQUENCE IF NOT EXISTS user8_seq START 10000050;

CREATE TABLE IF NOT EXISTS users (
  id char(8) PRIMARY KEY DEFAULT LPAD(nextval('user8_seq')::text,8,'0'),
  email text UNIQUE,
  username text UNIQUE,
  password_hash text NOT NULL,
  role text NOT NULL DEFAULT 'user',
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS username text;
ALTER TABLE users
  ALTER COLUMN email DROP NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_username_uq
  ON users (username);

CREATE TABLE IF NOT EXISTS refresh_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id char(8) NOT NULL,
  token text NOT NULL UNIQUE,
  expired_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS refresh_tokens_user_id_idx
  ON refresh_tokens (user_id);
