-- =============================================================================
-- 01_base_tables.sql
-- Input tables (written by R/db.R::load_lobster):
--   messages(event_id, time, t_ms, type, order_id, size, price, direction)
--   book(event_id, level, ask_price, ask_size, bid_price, bid_size)  -- long format
-- Prices are in dollars; empty book levels have NULL price and size 0.
--
-- All SQL in this project is written to run unchanged on both SQLite and DuckDB:
-- no engine-specific functions, explicit * 1.0 for float division, NULLIF on
-- every denominator, and integer bucketing via t_ms - t_ms % width.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_messages_event ON messages(event_id);
CREATE INDEX IF NOT EXISTS idx_book_event_level ON book(event_id, level);

-- Top of book after every message, plus the classic L1 microstructure fields.
--   spread     = ask - bid
--   mid        = (ask + bid) / 2
--   microprice = size-weighted mid; leans toward the side with LESS size,
--                i.e. toward where the price is more likely to move next
--   imb_l1     = (bid_size - ask_size) / (bid_size + ask_size), in [-1, 1]
DROP TABLE IF EXISTS tob;
CREATE TABLE tob AS
SELECT m.event_id,
       m.t_ms,
       m.type,
       b.bid_price AS bid,
       b.ask_price AS ask,
       b.bid_size,
       b.ask_size,
       b.ask_price - b.bid_price AS spread,
       (b.ask_price + b.bid_price) / 2.0 AS mid,
       (b.bid_price * b.ask_size + b.ask_price * b.bid_size) * 1.0
           / NULLIF(b.bid_size + b.ask_size, 0) AS microprice,
       (b.bid_size - b.ask_size) * 1.0
           / NULLIF(b.bid_size + b.ask_size, 0) AS imb_l1
FROM messages m
JOIN book b
  ON b.event_id = m.event_id AND b.level = 1
WHERE b.bid_size > 0
  AND b.ask_size > 0
  AND b.ask_price > b.bid_price;   -- drop one-sided / crossed snapshots

CREATE INDEX IF NOT EXISTS idx_tob_event ON tob(event_id);
CREATE INDEX IF NOT EXISTS idx_tob_tms ON tob(t_ms);

-- Every execution (visible type 4, hidden type 5).
-- LOBSTER `direction` is the side of the RESTING order, so the aggressor's
-- sign is its negative: +1 = buyer-initiated, -1 = seller-initiated.
DROP TABLE IF EXISTS fills;
CREATE TABLE fills AS
SELECT event_id,
       time,
       t_ms,
       type,
       size,
       price,
       -direction AS sign
FROM messages
WHERE type IN (4, 5);

CREATE INDEX IF NOT EXISTS idx_fills_event ON fills(event_id);
