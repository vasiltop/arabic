BEGIN;

CREATE TABLE noun_write_keys (
    user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE
);

INSERT INTO schema_migrations (version) VALUES (6);
COMMIT;
