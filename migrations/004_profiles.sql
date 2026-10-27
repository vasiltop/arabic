BEGIN;

ALTER TABLE users ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';

CREATE TABLE review_events (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    card_id BIGINT REFERENCES review_cards(id) ON DELETE SET NULL,
    form TEXT NOT NULL,
    reviewed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    rating INTEGER NOT NULL CHECK (rating BETWEEN 0 AND 3),
    xp INTEGER NOT NULL CHECK (xp >= 0)
);
CREATE INDEX review_events_user_time_idx ON review_events (user_id, reviewed_at);
CREATE INDEX review_events_card_idx ON review_events (card_id);

INSERT INTO schema_migrations (version) VALUES (4);
COMMIT;
