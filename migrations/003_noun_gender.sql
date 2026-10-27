BEGIN;

ALTER TABLE nouns ADD COLUMN gender TEXT NOT NULL DEFAULT 'unknown'
    CHECK (gender IN ('masculine', 'feminine', 'unknown'));

INSERT INTO schema_migrations (version) VALUES (3);
COMMIT;
