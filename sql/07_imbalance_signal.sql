-- =============================================================================
-- 07_imbalance_signal.sql
-- Does queue imbalance predict the direction of the NEXT mid-price move?
-- (Cartea, Donnelly & Jaimungal 2018; Gould & Bonart 2016.)
--
-- For every book state we find the next event at which the mid changes and
-- record its direction (+1 up / -1 down). "Next change" is found without a
-- correlated subquery: a running count of mid changes gives each state the
-- number of the change it is waiting for.
-- =============================================================================

DROP TABLE IF EXISTS imbalance_signal;
CREATE TABLE imbalance_signal AS
WITH c AS (
    SELECT event_id, mid,
           mid - LAG(mid) OVER (ORDER BY event_id) AS d_mid
    FROM tob
),
n AS (
    SELECT event_id, d_mid,
           SUM(CASE WHEN d_mid <> 0 THEN 1 ELSE 0 END)
               OVER (ORDER BY event_id ROWS UNBOUNDED PRECEDING) AS n_changes
    FROM c
),
changes AS (
    SELECT n_changes AS change_no,
           event_id AS change_event,
           CASE WHEN d_mid > 0 THEN 1 ELSE -1 END AS direction
    FROM n
    WHERE d_mid <> 0
)
SELECT n.event_id,
       t.imb_l1,
       d.imb_weighted,
       (t.microprice - t.mid) / NULLIF(t.spread, 0) AS micro_tilt,
       ROUND(t.spread * 100) AS spread_ticks,
       ch.direction AS next_move,
       ch.change_event - n.event_id AS events_until_move
FROM n
JOIN tob t      ON t.event_id = n.event_id
JOIN depth d    ON d.event_id = n.event_id
JOIN changes ch ON ch.change_no = n.n_changes + 1;

-- Probability that the next move is UP, by imbalance decile.
DROP TABLE IF EXISTS imbalance_deciles;
CREATE TABLE imbalance_deciles AS
WITH l1 AS (
    SELECT 'L1 queue imbalance' AS measure, imb_l1 AS x, next_move,
           NTILE(10) OVER (ORDER BY imb_l1) AS decile
    FROM imbalance_signal
),
w AS (
    SELECT 'Depth-weighted imbalance' AS measure, imb_weighted AS x, next_move,
           NTILE(10) OVER (ORDER BY imb_weighted) AS decile
    FROM imbalance_signal
    WHERE imb_weighted IS NOT NULL
),
u AS (
    SELECT * FROM l1
    UNION ALL
    SELECT * FROM w
)
SELECT measure,
       decile,
       COUNT(*) AS n,
       AVG(x) AS avg_imbalance,
       AVG(CASE WHEN next_move = 1 THEN 1.0 ELSE 0.0 END) AS p_up
FROM u
GROUP BY measure, decile
ORDER BY measure, decile;
