-- =============================================================================
-- 09_summary.sql
-- One tidy (metric, value) table of headline numbers for the README / report.
-- =============================================================================

DROP TABLE IF EXISTS summary;
CREATE TABLE summary AS
SELECT 'messages' AS metric, COUNT(*) * 1.0 AS value FROM messages
UNION ALL SELECT 'limit order submissions', SUM(CASE WHEN type = 1 THEN 1.0 ELSE 0 END) FROM messages
UNION ALL SELECT 'cancellations (full + partial)', SUM(CASE WHEN type IN (2, 3) THEN 1.0 ELSE 0 END) FROM messages
UNION ALL SELECT 'executions (fills)', COUNT(*) * 1.0 FROM fills
UNION ALL SELECT 'trades (stitched)', COUNT(*) * 1.0 FROM trades
UNION ALL SELECT 'share volume', SUM(size) * 1.0 FROM trades
UNION ALL SELECT 'cancel-to-trade ratio',
    (SELECT SUM(CASE WHEN type IN (2, 3) THEN 1.0 ELSE 0 END) FROM messages)
    / NULLIF((SELECT COUNT(*) FROM trades), 0)
UNION ALL SELECT 'avg quoted spread ($)', AVG(spread) FROM tob
UNION ALL SELECT 'share of time at 1-tick spread', AVG(CASE WHEN spread < 0.0105 THEN 1.0 ELSE 0.0 END) FROM tob
UNION ALL SELECT 'avg effective spread (bps)', AVG(eff_spread_bps) FROM trade_costs
UNION ALL SELECT 'avg realized spread 5s (bps)', AVG(real_spread_5s_bps) FROM trade_costs
UNION ALL SELECT 'avg price impact 5s (bps)', AVG(impact_5s_bps) FROM trade_costs
UNION ALL SELECT 'share of trades walking the book', AVG(walked_book * 1.0) FROM trade_costs
UNION ALL SELECT 'roll autocovariance', autocov FROM roll_autocov;
