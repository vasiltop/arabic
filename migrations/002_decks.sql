BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE decks (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    uid UUID NOT NULL DEFAULT gen_random_uuid(),
    name TEXT NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
    enabled BOOLEAN NOT NULL DEFAULT true,
    is_default BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, uid),
    UNIQUE (id, user_id)
);
CREATE UNIQUE INDEX decks_name_unique ON decks (user_id, lower(name));
CREATE UNIQUE INDEX decks_default_unique ON decks (user_id) WHERE is_default;

INSERT INTO decks (user_id, name, is_default) SELECT id, 'Default', true FROM users;

CREATE TABLE entries (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    deck_id BIGINT NOT NULL,
    uid UUID NOT NULL DEFAULT gen_random_uuid(),
    type TEXT NOT NULL CHECK (length(type) > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, uid),
    FOREIGN KEY (deck_id, user_id) REFERENCES decks(id, user_id)
);
CREATE INDEX entries_deck_idx ON entries (deck_id);
CREATE INDEX entries_user_idx ON entries (user_id);

INSERT INTO entries (id, user_id, deck_id, type, created_at, updated_at)
SELECT n.id, n.user_id, d.id, 'noun', n.created_at, n.updated_at
FROM nouns n JOIN decks d ON d.user_id=n.user_id AND d.is_default;
SELECT setval(pg_get_serial_sequence('entries', 'id'), COALESCE(max(id), 1), count(*) > 0) FROM entries;

ALTER TABLE nouns DROP COLUMN user_id;
ALTER TABLE nouns DROP COLUMN created_at;
ALTER TABLE nouns DROP COLUMN updated_at;
ALTER TABLE nouns ALTER COLUMN id DROP DEFAULT;
ALTER TABLE nouns ADD CONSTRAINT nouns_entry_fk FOREIGN KEY (id) REFERENCES entries(id) ON DELETE CASCADE;

ALTER TABLE review_cards DROP CONSTRAINT review_cards_noun_id_fkey;
ALTER TABLE review_cards DROP CONSTRAINT review_cards_form_check;
ALTER TABLE review_cards RENAME COLUMN noun_id TO entry_id;
ALTER TABLE review_cards RENAME COLUMN form TO variant;
ALTER TABLE review_cards RENAME CONSTRAINT review_cards_noun_id_form_key TO review_cards_entry_variant_unique;
ALTER TABLE review_cards ADD CONSTRAINT review_cards_entry_fk FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE;

CREATE TABLE deck_imports (
    token TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    payload TEXT NOT NULL,
    snapshot TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 minutes'),
    consumed_at TIMESTAMPTZ
);
CREATE INDEX deck_imports_expiry_idx ON deck_imports (expires_at);

INSERT INTO schema_migrations (version) VALUES (1), (2) ON CONFLICT DO NOTHING;
COMMIT;
