-- =============================================================================
-- 05_trades_and_costs.sql
-- LOBSTER records one execution message per resting order hit, so a single
-- marketable order that sweeps several orders shows up as several consecutive
-- fills with the same timestamp and sign. We stitch them back into trades.
--
-- Transaction-cost measures (per trade, in basis points of the pre-trade mid):
--   effective spread  = 2 * sign * (vwap - mid_pre)       / mid_pre
--   realized spread   = 2 * sign * (vwap - mid_{t+5s})     / mid_pre
--   price impact(h)   =     sign * (mid_{t+h} - mid_pre)   / mid_pre
-- with  effective spread = realized spread + 2 * impact(5s):  what liquidity
-- providers earn vs. what they lose to informed flow (adverse selection).
-- =============================================================================

DROP TABLE IF EXISTS trades;
CREATE TABLE trades AS
WITH f AS (
    SELECT event_id, time, t_ms, size, price, sign,
           LAG(event_id) OVER (ORDER BY event_id) AS prev_event,
           LAG(time)     OVER (ORDER BY event_id) AS prev_time,
           LAG(sign)     OVER (ORDER BY event_id) AS prev_sign
    FROM fills
),
g AS (
    SELECT *,
           SUM(CASE WHEN prev_event = event_id - 1
                     AND prev_time = time
                     AND prev_sign = sign THEN 0 ELSE 1 END)
               OVER (ORDER BY event_id ROWS UNBOUNDED PRECEDING) AS trade_id
    FROM f
)
SELECT trade_id,
       MIN(event_id) AS first_event,
       MAX(event_id) AS last_event,
       MIN(t_ms) AS t_ms,
       MAX(sign) AS sign,
       SUM(size) AS size,
       SUM(price * size) / SUM(size) AS vwap,
       MIN(price) AS min_price,
       MAX(price) AS max_price,
       COUNT(*) AS n_fills
FROM g
GROUP BY trade_id;

CREATE INDEX IF NOT EXISTS idx_trades_id ON trades(trade_id);

DROP TABLE IF EXISTS trade_costs;
CREATE TABLE trade_costs AS
WITH anchors AS (
    SELECT t.*,
           (SELECT MAX(q.event_id) FROM tob q WHERE q.event_id < t.first_event) AS pre_event,
           (SELECT MIN(q.event_id) FROM tob q WHERE q.event_id >= t.last_event) AS post_event
    FROM trades t
),
q AS (
    SELECT a.trade_id, a.t_ms, a.sign, a.size, a.vwap, a.n_fills,
           a.t_ms - a.t_ms % 1000 AS sec_ms,
           pre.bid AS pre_bid, pre.ask AS pre_ask, pre.mid AS pre_mid,
           pre.spread AS pre_spread,
           CASE WHEN a.sign = 1 THEN pre.ask_size ELSE pre.bid_size END AS pre_touch_size,
           post.mid AS post_mid
    FROM anchors a
    JOIN tob pre       ON pre.event_id = a.pre_event
    LEFT JOIN tob post ON post.event_id = a.post_event
)
SELECT q.*,
       q.size * 1.0 / NULLIF(q.pre_touch_size, 0) AS size_to_touch,
       CASE WHEN q.n_fills > 0 AND (q.vwap > q.pre_ask OR q.vwap < q.pre_bid)
            THEN 1 ELSE 0 END AS walked_book,
       20000.0 * q.sign * (q.vwap - q.pre_mid) / q.pre_mid      AS eff_spread_bps,
       20000.0 * q.sign * (q.vwap - g5.mid)    / q.pre_mid      AS real_spread_5s_bps,
       10000.0 * q.sign * (q.post_mid - q.pre_mid) / q.pre_mid  AS impact_0_bps,
       10000.0 * q.sign * (g1.mid  - q.pre_mid) / q.pre_mid     AS impact_1s_bps,
       10000.0 * q.sign * (g5.mid  - q.pre_mid) / q.pre_mid     AS impact_5s_bps,
       10000.0 * q.sign * (g30.mid - q.pre_mid) / q.pre_mid     AS impact_30s_bps,
       10000.0 * q.sign * (g60.mid - q.pre_mid) / q.pre_mid     AS impact_60s_bps
FROM q
LEFT JOIN time_grid g1  ON g1.sec_ms  = q.sec_ms + 1000
LEFT JOIN time_grid g5  ON g5.sec_ms  = q.sec_ms + 5000
LEFT JOIN time_grid g30 ON g30.sec_ms = q.sec_ms + 30000
LEFT JOIN time_grid g60 ON g60.sec_ms = q.sec_ms + 60000;

-- Average impact path by trade-size decile (the "impact curve").
DROP TABLE IF EXISTS impact_by_size;
CREATE TABLE impact_by_size AS
WITH d AS (
    SELECT *, NTILE(10) OVER (ORDER BY size) AS size_decile
    FROM trade_costs
)
SELECT size_decile,
       COUNT(*) AS n_trades,
       AVG(size) AS avg_size,
       AVG(size_to_touch) AS avg_size_to_touch,
       AVG(walked_book * 1.0) AS frac_walked_book,
       AVG(eff_spread_bps) AS eff_spread_bps,
       AVG(real_spread_5s_bps) AS real_spread_5s_bps,
       AVG(impact_0_bps) AS impact_0_bps,
       AVG(impact_1s_bps) AS impact_1s_bps,
       AVG(impact_5s_bps) AS impact_5s_bps,
       AVG(impact_30s_bps) AS impact_30s_bps,
       AVG(impact_60s_bps) AS impact_60s_bps
FROM d
GROUP BY size_decile
ORDER BY size_decile;

-- Roll (1984) implied spread: bid-ask bounce makes consecutive trade-price
-- changes negatively autocorrelated; spread = 2 * sqrt(-cov(dp_t, dp_{t-1})).
-- (sqrt is taken in R to stay engine-neutral.)
DROP TABLE IF EXISTS roll_autocov;
CREATE TABLE roll_autocov AS
WITH d AS (
    SELECT trade_id, vwap - LAG(vwap) OVER (ORDER BY trade_id) AS dp
    FROM trades
),
d2 AS (
    SELECT dp, LAG(dp) OVER (ORDER BY trade_id) AS dp_lag
    FROM d
)
SELECT COUNT(*) AS n_pairs,
       AVG(dp * dp_lag) - AVG(dp) * AVG(dp_lag) AS autocov
FROM d2
WHERE dp IS NOT NULL AND dp_lag IS NOT NULL;
