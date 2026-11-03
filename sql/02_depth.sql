-- =============================================================================
-- 02_depth.sql
-- Multi-level depth and depth imbalance after every message.
--   imb_depth     : plain imbalance using all loaded levels
--   imb_weighted  : levels weighted 1/level, so the touch counts most
-- =============================================================================

DROP TABLE IF EXISTS depth;
CREATE TABLE depth AS
SELECT event_id,
       SUM(bid_size) AS bid_depth,
       SUM(ask_size) AS ask_depth,
       SUM(CASE WHEN bid_size > 0 THEN 1 ELSE 0 END) AS bid_levels,
       SUM(CASE WHEN ask_size > 0 THEN 1 ELSE 0 END) AS ask_levels,
       (SUM(bid_size) - SUM(ask_size)) * 1.0
           / NULLIF(SUM(bid_size) + SUM(ask_size), 0) AS imb_depth,
       (SUM(bid_size * 1.0 / level) - SUM(ask_size * 1.0 / level))
           / NULLIF(SUM(bid_size * 1.0 / level) + SUM(ask_size * 1.0 / level), 0) AS imb_weighted
FROM book
GROUP BY event_id;

CREATE INDEX IF NOT EXISTS idx_depth_event ON depth(event_id);
