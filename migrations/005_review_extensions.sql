BEGIN;

CREATE TABLE review_extensions (
    user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    study_day DATE NOT NULL,
    extra_cards BIGINT NOT NULL CHECK (extra_cards >= 0 AND extra_cards % 5 = 0)
);

INSERT INTO schema_migrations (version) VALUES (5);
COMMIT;
