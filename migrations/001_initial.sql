BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
    id BIGSERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_unique ON users (lower(username));

CREATE TABLE IF NOT EXISTS nouns (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    singular TEXT NOT NULL,
    plural TEXT NOT NULL,
    meaning TEXT NOT NULL,
    singular_sentence TEXT NOT NULL,
    singular_translation TEXT NOT NULL,
    plural_sentence TEXT NOT NULL,
    plural_translation TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS nouns_user_id_idx ON nouns (user_id, lower(singular));

CREATE TABLE IF NOT EXISTS review_cards (
    id BIGSERIAL PRIMARY KEY,
    noun_id BIGINT NOT NULL REFERENCES nouns(id) ON DELETE CASCADE,
    form TEXT NOT NULL CHECK (form IN ('singular', 'plural')),
    due_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    interval_days INTEGER NOT NULL DEFAULT 0 CHECK (interval_days >= 0),
    ease_factor DOUBLE PRECISION NOT NULL DEFAULT 2.5 CHECK (ease_factor >= 1.3),
    repetitions INTEGER NOT NULL DEFAULT 0 CHECK (repetitions >= 0),
    last_reviewed_at TIMESTAMPTZ,
    UNIQUE (noun_id, form)
);

CREATE INDEX IF NOT EXISTS review_cards_due_idx ON review_cards (due_at);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash CHAR(64) PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON sessions (user_id);
CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at);

INSERT INTO schema_migrations (version) VALUES (1) ON CONFLICT DO NOTHING;
COMMIT;
