-- =============================================================================
-- 06_realized_volatility.sql
-- Volatility signature plot (Andersen, Bollerslev, Diebold & Labys 2000):
-- realized variance RV(k) = sum of squared k-second returns over the session.
-- With no microstructure noise RV(k) is flat in k. Bid-ask bounce in TRADE
-- prices inflates RV at short intervals; MID quotes are much less affected.
-- =============================================================================

DROP TABLE IF EXISTS rv_signature;
CREATE TABLE rv_signature AS
WITH ks(k) AS (
    VALUES (1), (2), (5), (10), (15), (30), (60), (120), (300), (600)
),
sampled AS (
    SELECT ks.k, g.sec_ms, g.mid, g.last_trade_px
    FROM time_grid g
    CROSS JOIN ks
    WHERE g.sec_ms % (ks.k * 1000) = 0
),
r AS (
    SELECT k,
           (mid - LAG(mid) OVER w) / LAG(mid) OVER w AS r_mid,
           (last_trade_px - LAG(last_trade_px) OVER w) / LAG(last_trade_px) OVER w AS r_trade
    FROM sampled
    WINDOW w AS (PARTITION BY k ORDER BY sec_ms)
)
SELECT k AS interval_sec,
       COUNT(r_mid) AS n_returns,
       SUM(r_mid * r_mid) AS rv_mid,
       SUM(r_trade * r_trade) AS rv_trade
FROM r
GROUP BY k
ORDER BY k;
