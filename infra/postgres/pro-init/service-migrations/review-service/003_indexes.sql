CREATE UNIQUE INDEX IF NOT EXISTS reviews_ride_rider_uq
  ON reviews (ride_id, rider_id);

CREATE INDEX IF NOT EXISTS reviews_rider_id_created_at_idx
  ON reviews (rider_id, created_at DESC);

CREATE INDEX IF NOT EXISTS reviews_status_created_at_idx
  ON reviews (status, created_at DESC);

CREATE INDEX IF NOT EXISTS review_status_history_review_id_status_updated_at_idx
  ON review_status_history (review_id, status_updated_at DESC);

CREATE INDEX IF NOT EXISTS reviews_status_history_reviews_id_occurred_at_idx
  ON reviews_status_history (reviews_id, occurred_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idempotency_keys_route_user_key_uq
  ON idempotency_keys (route_key, user_id, idem_key);

CREATE UNIQUE INDEX IF NOT EXISTS inbox_events_event_consumer_uq
  ON inbox_events (event_id, consumer);

CREATE INDEX IF NOT EXISTS inbox_events_topic_received_at_idx
  ON inbox_events (topic, received_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS outbox_events_event_id_uq
  ON outbox_events (event_id);

CREATE INDEX IF NOT EXISTS outbox_events_status_occurred_at_idx
  ON outbox_events (status, occurred_at DESC);
