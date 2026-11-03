# -----------------------------------------------------------------------------
# analysis.R — statistical models on top of the SQL tables.
# SQL does the heavy lifting (joins, windows, aggregation over every message);
# R does the modeling: regressions, logistic fits, autocorrelations.
# -----------------------------------------------------------------------------

TICK_SIZE <- 0.01

# Cont-Kukanov-Stoikov: mid change over a 10s bucket vs. order flow imbalance.
fit_ofi <- function(con) {
  b <- DBI::dbGetQuery(con, "
    SELECT ofi, avg_l1_depth, d_mid
    FROM ofi_buckets
    WHERE d_mid IS NOT NULL AND gap_ms = 10000")
  b$d_mid_ticks <- b$d_mid / TICK_SIZE
  b$ofi_scaled <- b$ofi / b$avg_l1_depth
  raw <- stats::lm(d_mid_ticks ~ ofi, data = b)
  scaled <- stats::lm(d_mid_ticks ~ ofi_scaled, data = b)
  list(
    data = b,
    model_raw = raw,
    model_scaled = scaled,
    r2_raw = summary(raw)$r.squared,
    r2_scaled = summary(scaled)$r.squared,
    beta_scaled = unname(stats::coef(scaled)["ofi_scaled"]),
    t_scaled = summary(scaled)$coefficients["ofi_scaled", "t value"],
    n = nrow(b)
  )
}

# Does imbalance predict the next mid move? Logistic regression + hit rate.
fit_imbalance <- function(con) {
  d <- DBI::dbGetQuery(con, "
    SELECT imb_l1, imb_weighted, micro_tilt, next_move
    FROM imbalance_signal
    WHERE imb_weighted IS NOT NULL")
  d$up <- as.integer(d$next_move == 1)
  m_l1 <- stats::glm(up ~ imb_l1, data = d, family = stats::binomial())
  m_w <- stats::glm(up ~ imb_weighted, data = d, family = stats::binomial())
  hit <- function(x) mean(sign(x[x != 0]) == d$next_move[x != 0])
  list(
    model_l1 = m_l1,
    model_weighted = m_w,
    hit_rate_l1 = hit(d$imb_l1),
    hit_rate_weighted = hit(d$imb_weighted),
    deciles = tbl(con, "imbalance_deciles"),
    n = nrow(d)
  )
}

# Square-root law check: impact ~ a * size^b  (b ~ 0.5 in many markets).
fit_impact <- function(con, horizon = "impact_5s_bps") {
  d <- tbl(con, "impact_by_size")
  y <- d[[horizon]]
  ok <- is.finite(y) & y > 0
  exponent <- NA_real_
  model <- NULL
  if (sum(ok) >= 3) {
    model <- stats::lm(log(y[ok]) ~ log(d$avg_size[ok]))
    exponent <- unname(stats::coef(model)[2])
  }
  list(by_size = d, exponent = exponent, model = model, horizon = horizon)
}

# Roll (1984) implied spread from trade-price autocovariance.
roll_spread <- function(con) {
  a <- DBI::dbGetQuery(con, "SELECT autocov FROM roll_autocov")$autocov
  if (length(a) == 0 || is.na(a) || a >= 0) return(NA_real_)
  2 * sqrt(-a)
}

# Trade-sign autocorrelation (order splitting / herding -> long memory).
trade_sign_acf <- function(con, lag_max = 50) {
  s <- DBI::dbGetQuery(con, "SELECT sign FROM trades ORDER BY trade_id")$sign
  a <- stats::acf(s, lag.max = lag_max, plot = FALSE)
  data.frame(lag = as.vector(a$lag)[-1], acf = as.vector(a$acf)[-1],
             ci = 1.96 / sqrt(length(s)))
}

volatility_signature <- function(con) {
  v <- tbl(con, "rv_signature")
  # daily realized volatility in percent
  v$vol_mid_pct <- 100 * sqrt(v$rv_mid)
  v$vol_trade_pct <- 100 * sqrt(v$rv_trade)
  v
}

spread_distribution <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT ROUND(spread * 100) AS spread_ticks, COUNT(*) AS n
    FROM tob
    GROUP BY ROUND(spread * 100)
    ORDER BY spread_ticks")
}

summary_table <- function(con) {
  s <- tbl(con, "summary")
  s$value <- vapply(s$value, function(v) {
    if (is.na(v)) "NA"
    else if (abs(v) >= 1000) format(round(v), big.mark = ",")
    else formatC(v, digits = 4, format = "g")
  }, character(1))
  s
}

# Everything in one list, used by run_all.R and the report.
analyze <- function(con) {
  list(
    summary = summary_table(con),
    ofi = fit_ofi(con),
    imbalance = fit_imbalance(con),
    impact = fit_impact(con),
    roll = roll_spread(con),
    quoted_spread = DBI::dbGetQuery(con, "SELECT AVG(spread) AS s FROM tob")$s,
    effective_spread = DBI::dbGetQuery(con,
      "SELECT AVG(eff_spread_bps * pre_mid / 10000.0) AS s FROM trade_costs")$s,
    sign_acf = trade_sign_acf(con),
    signature = volatility_signature(con),
    spreads = spread_distribution(con),
    intraday = tbl(con, "intraday")
  )
}

ms_to_clock <- function(ms) {
  sprintf("%02d:%02d", as.integer(ms %/% 3600000), as.integer((ms %% 3600000) %/% 60000))
}

# Markdown summary of headline results.
write_results_md <- function(res, path = "output/RESULTS.md") {
  f <- function(x, d = 3) formatC(x, digits = d, format = "f")
  lines <- c(
    "# Results",
    "",
    "| Metric | Value |",
    "|---|---|",
    paste0("| ", res$summary$metric, " | ", res$summary$value, " |"),
    "",
    "## Key findings",
    "",
    sprintf("- **Order flow imbalance:** 10s OFI (scaled by L1 depth) explains **R² = %s** of mid-price changes (n = %d buckets, t = %s).",
            f(res$ofi$r2_scaled), res$ofi$n, f(res$ofi$t_scaled, 1)),
    sprintf("- **Queue imbalance:** the sign of L1 imbalance calls the direction of the next mid move **%s%%** of the time (depth-weighted: %s%%).",
            f(100 * res$imbalance$hit_rate_l1, 1), f(100 * res$imbalance$hit_rate_weighted, 1)),
    sprintf("- **Imbalance deciles:** P(next move up) goes from %s in the most ask-heavy decile to %s in the most bid-heavy.",
            f(min(res$imbalance$deciles$p_up[res$imbalance$deciles$measure == "L1 queue imbalance"]), 2),
            f(max(res$imbalance$deciles$p_up[res$imbalance$deciles$measure == "L1 queue imbalance"]), 2)),
    sprintf("- **Price impact:** 5s impact scales like size^%s (square-root law predicts ~0.5).",
            f(res$impact$exponent, 2)),
    sprintf("- **Spreads:** quoted $%s, effective $%s, Roll-implied $%s.",
            f(res$quoted_spread, 4), f(res$effective_spread, 4), f(res$roll, 4)),
    sprintf("- **Volatility signature:** daily vol from 1s trade prices is %s%% vs %s%% from 1s mids (bid-ask bounce inflates trade-based RV at high frequency).",
            f(res$signature$vol_trade_pct[res$signature$interval_sec == 1], 2),
            f(res$signature$vol_mid_pct[res$signature$interval_sec == 1], 2)),
    sprintf("- **Trade signs:** lag-1 autocorrelation of trade signs is %s (order splitting).",
            f(res$sign_acf$acf[1], 2)),
    ""
  )
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(lines, path)
  invisible(path)
}
