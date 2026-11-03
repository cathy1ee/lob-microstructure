# -----------------------------------------------------------------------------
# plots.R — ggplot2 figures. Each function takes the list returned by
# analyze() and returns a ggplot object.
# -----------------------------------------------------------------------------

theme_lob <- function() {
  ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      plot.title = ggplot2::element_text(face = "bold"),
      plot.subtitle = ggplot2::element_text(color = "grey35"),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "bottom"
    )
}

PAL <- c("#2a6f97", "#e07a5f", "#3d405b", "#81b29a", "#f2cc8f")

plot_spread_distribution <- function(res) {
  d <- res$spreads
  d$share <- d$n / sum(d$n)
  ggplot2::ggplot(d, ggplot2::aes(factor(spread_ticks), share)) +
    ggplot2::geom_col(fill = PAL[1], width = 0.7) +
    ggplot2::scale_y_continuous(labels = function(x) paste0(round(100 * x), "%")) +
    ggplot2::labs(title = "Quoted spread distribution",
                  subtitle = "Share of book updates at each spread",
                  x = "Spread (ticks)", y = NULL) +
    theme_lob()
}

plot_imbalance <- function(res) {
  d <- res$imbalance$deciles
  ggplot2::ggplot(d, ggplot2::aes(avg_imbalance, p_up, color = measure)) +
    ggplot2::geom_hline(yintercept = 0.5, linetype = "dashed", color = "grey50") +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 2) +
    ggplot2::scale_color_manual(values = PAL[1:2], name = NULL) +
    ggplot2::scale_y_continuous(limits = c(0, 1)) +
    ggplot2::labs(title = "Queue imbalance predicts the next mid-price move",
                  subtitle = "P(next mid change is up) by imbalance decile",
                  x = "Average imbalance in decile", y = "P(next move up)") +
    theme_lob()
}

plot_ofi <- function(res) {
  d <- res$ofi$data
  ggplot2::ggplot(d, ggplot2::aes(ofi_scaled, d_mid_ticks)) +
    ggplot2::geom_point(alpha = 0.25, size = 1, color = PAL[3]) +
    ggplot2::geom_smooth(method = "lm", formula = y ~ x, color = PAL[2], se = TRUE) +
    ggplot2::labs(title = "Order flow imbalance vs. price change (10s buckets)",
                  subtitle = sprintf("Cont-Kukanov-Stoikov linear model, R² = %.2f",
                                     res$ofi$r2_scaled),
                  x = "OFI / average L1 depth", y = "Mid-price change (ticks)") +
    theme_lob()
}

plot_impact <- function(res) {
  d <- res$impact$by_size
  hz <- c(impact_0_bps = "immediate", impact_1s_bps = "1s", impact_5s_bps = "5s",
          impact_30s_bps = "30s", impact_60s_bps = "60s")
  long <- do.call(rbind, lapply(names(hz), function(h) {
    data.frame(avg_size = d$avg_size, impact = d[[h]], horizon = hz[[h]])
  }))
  long$horizon <- factor(long$horizon, levels = unname(hz))
  ggplot2::ggplot(long, ggplot2::aes(avg_size, impact, color = horizon)) +
    ggplot2::geom_line(linewidth = 0.9) +
    ggplot2::geom_point(size = 1.8) +
    ggplot2::scale_x_log10() +
    ggplot2::scale_color_manual(values = PAL, name = "Horizon") +
    ggplot2::labs(title = "Price impact by trade size",
                  subtitle = sprintf("Signed mid move after the trade, by size decile; 5s exponent = %.2f",
                                     res$impact$exponent),
                  x = "Average trade size (shares, log scale)", y = "Impact (bps)") +
    theme_lob()
}

plot_cost_decomposition <- function(res) {
  d <- res$impact$by_size
  long <- rbind(
    data.frame(size_decile = d$size_decile, part = "Realized spread (to liquidity provider)",
               bps = d$real_spread_5s_bps),
    data.frame(size_decile = d$size_decile, part = "2 x price impact (adverse selection)",
               bps = 2 * d$impact_5s_bps)
  )
  ggplot2::ggplot(long, ggplot2::aes(factor(size_decile), bps, fill = part)) +
    ggplot2::geom_col(width = 0.7) +
    ggplot2::scale_fill_manual(values = PAL[c(4, 2)], name = NULL) +
    ggplot2::labs(title = "Effective spread = realized spread + 2 x impact",
                  subtitle = "Who earns the spread? Decomposition at a 5s horizon",
                  x = "Trade size decile (1 = smallest)", y = "bps") +
    theme_lob()
}

plot_signature <- function(res) {
  v <- res$signature
  long <- rbind(
    data.frame(interval_sec = v$interval_sec, vol = v$vol_mid_pct, price = "Mid quote"),
    data.frame(interval_sec = v$interval_sec, vol = v$vol_trade_pct, price = "Last trade")
  )
  ggplot2::ggplot(long, ggplot2::aes(interval_sec, vol, color = price)) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 2) +
    ggplot2::scale_x_log10(breaks = v$interval_sec) +
    ggplot2::scale_color_manual(values = PAL[1:2], name = NULL) +
    ggplot2::labs(title = "Volatility signature plot",
                  subtitle = "Realized daily volatility vs. sampling interval",
                  x = "Sampling interval (seconds, log scale)", y = "Realized volatility (%)") +
    theme_lob()
}

plot_sign_acf <- function(res) {
  d <- res$sign_acf
  ggplot2::ggplot(d, ggplot2::aes(lag, acf)) +
    ggplot2::geom_hline(yintercept = 0, color = "grey40") +
    ggplot2::geom_hline(yintercept = c(-1, 1) * d$ci[1], linetype = "dashed", color = "grey60") +
    ggplot2::geom_col(fill = PAL[1], width = 0.7) +
    ggplot2::labs(title = "Autocorrelation of trade signs",
                  subtitle = "Buy/sell initiations cluster (dashed = 95% band under no correlation)",
                  x = "Lag (trades)", y = "ACF") +
    theme_lob()
}

plot_intraday <- function(res) {
  d <- res$intraday
  d$clock <- ms_to_clock(d$bucket_ms)
  long <- rbind(
    data.frame(clock = d$clock, value = d$n_trades, metric = "Trades"),
    data.frame(clock = d$clock, value = d$avg_spread * 100, metric = "Avg spread (ticks)"),
    data.frame(clock = d$clock, value = 100 * sqrt(d$rv_5s), metric = "Volatility (%, 5s RV)"),
    data.frame(clock = d$clock, value = d$avg_l1_depth, metric = "Avg L1 depth (shares)")
  )
  ggplot2::ggplot(long, ggplot2::aes(clock, value, group = 1)) +
    ggplot2::geom_line(color = PAL[1], linewidth = 0.9) +
    ggplot2::geom_point(color = PAL[1], size = 1.5) +
    ggplot2::facet_wrap(~metric, scales = "free_y", ncol = 2) +
    ggplot2::labs(title = "Intraday patterns (30-minute buckets)", x = NULL, y = NULL) +
    theme_lob() +
    ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 45, hjust = 1, size = 8))
}

save_figures <- function(res, dir = "output/figures") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  figs <- list(
    "01_spread_distribution" = plot_spread_distribution(res),
    "02_imbalance_signal" = plot_imbalance(res),
    "03_order_flow_imbalance" = plot_ofi(res),
    "04_price_impact" = plot_impact(res),
    "05_cost_decomposition" = plot_cost_decomposition(res),
    "06_volatility_signature" = plot_signature(res),
    "07_trade_sign_acf" = plot_sign_acf(res),
    "08_intraday" = plot_intraday(res)
  )
  for (nm in names(figs)) {
    ggplot2::ggsave(file.path(dir, paste0(nm, ".png")), figs[[nm]],
                    width = 8, height = 5, dpi = 150, bg = "white")
  }
  invisible(file.path(dir, paste0(names(figs), ".png")))
}
