-- =============================================================================
-- 04_order_flow_imbalance.sql
-- Order Flow Imbalance (Cont, Kukanov & Stoikov 2014, "The Price Impact of
-- Order Book Events"). For each book update n, comparing with update n-1:
--
--   e_n =  1{bid_n >= bid_{n-1}} * bidsz_n  -  1{bid_n <= bid_{n-1}} * bidsz_{n-1}
--        - 1{ask_n <= ask_{n-1}} * asksz_n  +  1{ask_n >= ask_{n-1}} * asksz_{n-1}
--
-- Positive e = net buying pressure at the touch (bids added / asks removed).
-- Summed over a time bucket, OFI explains most of the mid-price change in that
-- bucket, roughly linearly, with slope ~ 1 / depth.
-- =============================================================================

DROP TABLE IF EXISTS ofi_events;
CREATE TABLE ofi_events AS
WITH x AS (
    SELECT event_id, t_ms, mid, bid, ask, bid_size, ask_size,
           LAG(bid)      OVER w AS prev_bid,
           LAG(ask)      OVER w AS prev_ask,
           LAG(bid_size) OVER w AS prev_bid_size,
           LAG(ask_size) OVER w AS prev_ask_size
    FROM tob
    WINDOW w AS (ORDER BY event_id)
)
SELECT event_id,
       t_ms,
       mid,
       (bid_size + ask_size) / 2.0 AS l1_depth,
         (CASE WHEN bid >= prev_bid THEN bid_size      ELSE 0 END)
       - (CASE WHEN bid <= prev_bid THEN prev_bid_size ELSE 0 END)
       - (CASE WHEN ask <= prev_ask THEN ask_size      ELSE 0 END)
       + (CASE WHEN ask >= prev_ask THEN prev_ask_size ELSE 0 END) AS e
FROM x
WHERE prev_bid IS NOT NULL;

-- 10-second buckets: total OFI vs. change in mid over the same bucket.
DROP TABLE IF EXISTS ofi_buckets;
CREATE TABLE ofi_buckets AS
WITH b AS (
    SELECT t_ms - t_ms % 10000 AS bucket_ms,
           SUM(e) AS ofi,
           AVG(l1_depth) AS avg_l1_depth,
           COUNT(*) AS n_updates,
           MAX(event_id) AS last_event
    FROM ofi_events
    GROUP BY t_ms - t_ms % 10000
)
SELECT b.bucket_ms,
       b.ofi,
       b.avg_l1_depth,
       b.n_updates,
       t.mid AS end_mid,
       t.mid - LAG(t.mid) OVER (ORDER BY b.bucket_ms) AS d_mid,
       b.bucket_ms - LAG(b.bucket_ms) OVER (ORDER BY b.bucket_ms) AS gap_ms
FROM b
JOIN tob t ON t.event_id = b.last_event;
