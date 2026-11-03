-- =============================================================================
-- 03_time_grid.sql
-- A regular 1-second clock. Each row holds the state as of the END of that
-- second: the last mid quote and the last traded price seen so far
-- (forward-filled). Used for impact horizons and realized volatility.
--
-- Forward fill without engine-specific IGNORE NULLS: COUNT(x) over a running
-- window only increments on non-NULL rows, so it labels each run of "x then
-- NULLs" with one group id; MAX(x) within that group fills the gap.
-- =============================================================================

DROP TABLE IF EXISTS time_grid;
CREATE TABLE time_grid AS
WITH RECURSIVE
secs(sec_ms) AS (
    SELECT (SELECT MIN(t_ms) - MIN(t_ms) % 1000 FROM tob)
    UNION ALL
    SELECT sec_ms + 1000 FROM secs
    WHERE sec_ms + 1000 <= (SELECT MAX(t_ms) FROM tob)
),
last_quote AS (
    SELECT t_ms - t_ms % 1000 AS sec_ms, MAX(event_id) AS event_id
    FROM tob
    GROUP BY t_ms - t_ms % 1000
),
last_fill AS (
    SELECT t_ms - t_ms % 1000 AS sec_ms, MAX(event_id) AS event_id
    FROM fills
    GROUP BY t_ms - t_ms % 1000
),
joined AS (
    SELECT s.sec_ms, t.mid, t.spread, f.price AS trade_px
    FROM secs s
    LEFT JOIN last_quote lq ON lq.sec_ms = s.sec_ms
    LEFT JOIN tob t         ON t.event_id = lq.event_id
    LEFT JOIN last_fill lf  ON lf.sec_ms = s.sec_ms
    LEFT JOIN fills f       ON f.event_id = lf.event_id
),
grouped AS (
    SELECT sec_ms, mid, spread, trade_px,
           COUNT(mid)      OVER (ORDER BY sec_ms ROWS UNBOUNDED PRECEDING) AS g_mid,
           COUNT(trade_px) OVER (ORDER BY sec_ms ROWS UNBOUNDED PRECEDING) AS g_trade
    FROM joined
)
SELECT sec_ms,
       MAX(mid)      OVER (PARTITION BY g_mid)   AS mid,
       MAX(spread)   OVER (PARTITION BY g_mid)   AS spread,
       MAX(trade_px) OVER (PARTITION BY g_trade) AS last_trade_px
FROM grouped;

CREATE INDEX IF NOT EXISTS idx_time_grid_sec ON time_grid(sec_ms);
