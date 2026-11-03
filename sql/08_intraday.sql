-- =============================================================================
-- 08_intraday.sql
-- Intraday patterns in 30-minute buckets: activity, spreads, depth, volume,
-- volatility. Real equities show the well-known U-shape in volume and
-- volatility, and spreads that are widest right after the open.
-- (Averages over book updates, i.e. event-weighted.)
-- =============================================================================

DROP TABLE IF EXISTS intraday;
CREATE TABLE intraday AS
WITH q AS (
    SELECT t_ms - t_ms % 1800000 AS bucket_ms,
           COUNT(*) AS n_book_updates,
           AVG(spread) AS avg_spread,
           AVG((bid_size + ask_size) / 2.0) AS avg_l1_depth
    FROM tob
    GROUP BY t_ms - t_ms % 1800000
),
tr AS (
    SELECT t_ms - t_ms % 1800000 AS bucket_ms,
           COUNT(*) AS n_trades,
           SUM(size) AS volume,
           AVG(size) AS avg_trade_size
    FROM trades
    GROUP BY t_ms - t_ms % 1800000
),
r AS (
    SELECT sec_ms - sec_ms % 1800000 AS bucket_ms,
           (mid - LAG(mid) OVER (ORDER BY sec_ms)) / LAG(mid) OVER (ORDER BY sec_ms) AS r5
    FROM time_grid
    WHERE sec_ms % 5000 = 0
),
v AS (
    SELECT bucket_ms, SUM(r5 * r5) AS rv_5s, COUNT(r5) AS n_returns
    FROM r
    GROUP BY bucket_ms
)
SELECT q.bucket_ms,
       q.n_book_updates,
       q.avg_spread,
       q.avg_l1_depth,
       COALESCE(tr.n_trades, 0) AS n_trades,
       COALESCE(tr.volume, 0) AS volume,
       tr.avg_trade_size,
       v.rv_5s
FROM q
LEFT JOIN tr ON tr.bucket_ms = q.bucket_ms
LEFT JOIN v  ON v.bucket_ms  = q.bucket_ms
ORDER BY q.bucket_ms;
