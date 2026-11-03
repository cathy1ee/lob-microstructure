# Run from the repo root:  Rscript -e 'testthat::test_dir("tests/testthat")'
root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
for (f in c("simulate_lob.R", "db.R", "analysis.R")) source(file.path(root, "R", f))

tmp <- tempfile("lobtest")
sim <- simulate_lobster(out_dir = tmp, start_sec = 34200, end_sec = 34200 + 900,
                        seed = 7, verbose = FALSE)
con <- db_connect(file.path(tmp, "test.sqlite"))
load_lobster(con, sim$message_file, sim$orderbook_file)
run_pipeline(con, file.path(root, "sql"), verbose = FALSE)
q <- function(sql) DBI::dbGetQuery(con, sql)

test_that("simulated book never goes negative and files round-trip", {
  expect_true(all(sim$orderbook[, grepl("size", colnames(sim$orderbook))] >= 0))
  expect_equal(q("SELECT COUNT(*) AS n FROM messages")$n, nrow(sim$messages))
  expect_equal(q("SELECT MAX(level) AS l FROM book")$l, 5)
})

test_that("top of book is sane", {
  bad <- q("SELECT COUNT(*) AS n FROM tob
            WHERE spread <= 0 OR microprice < bid OR microprice > ask
               OR imb_l1 < -1 OR imb_l1 > 1")$n
  expect_equal(bad, 0)
})

test_that("fills stitch back into exactly one trade per market order", {
  expect_equal(q("SELECT COUNT(*) AS n FROM trades")$n, sim$n_market_orders)
  expect_equal(q("SELECT SUM(size) AS s FROM trades")$s,
               q("SELECT SUM(size) AS s FROM fills")$s)
})

test_that("effective spread = realized spread + 2 x impact (identity)", {
  d <- q("SELECT eff_spread_bps, real_spread_5s_bps, impact_5s_bps
          FROM trade_costs WHERE impact_5s_bps IS NOT NULL")
  expect_gt(nrow(d), 0)
  expect_equal(d$eff_spread_bps, d$real_spread_5s_bps + 2 * d$impact_5s_bps,
               tolerance = 1e-8)
})

test_that("time grid is a complete 1-second clock", {
  g <- q("SELECT COUNT(*) AS n, MIN(sec_ms) AS lo, MAX(sec_ms) AS hi FROM time_grid")
  expect_equal(g$n, (g$hi - g$lo) / 1000 + 1)
})

test_that("imbalance signal: next move is +/-1 and deciles cover all rows", {
  expect_true(all(q("SELECT DISTINCT next_move FROM imbalance_signal")$next_move %in% c(-1, 1)))
  n_sig <- q("SELECT COUNT(*) AS n FROM imbalance_signal")$n
  n_dec <- q("SELECT SUM(n) AS n FROM imbalance_deciles
              WHERE measure = 'L1 queue imbalance'")$n
  expect_equal(n_sig, n_dec)
})

test_that("models fit", {
  res <- analyze(con)
  expect_true(is.finite(res$ofi$r2_scaled))
  expect_gt(res$imbalance$hit_rate_l1, 0.5)
})

DBI::dbDisconnect(con)
unlink(tmp, recursive = TRUE)
