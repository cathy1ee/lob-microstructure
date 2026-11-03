# -----------------------------------------------------------------------------
# simulate_lob.R
#
# A zero-intelligence limit order book simulator that writes its output in the
# LOBSTER format (https://lobsterdata.com), so the exact same SQL pipeline runs
# on simulated data and on real Nasdaq LOBSTER files.
#
# Model (in the spirit of Smith-Farmer-Gillemot-Krishnamurthy 2003 and
# Cont-Stoikov-Talreja 2010):
#   * Events arrive as a Poisson process whose rate follows an intraday U-shape
#     (busy at the open and close, quiet at midday).
#   * Each event is a limit order, a cancellation, or a market order.
#   * Limit orders are placed a geometric number of ticks away from the
#     opposite best quote (so most liquidity sits near the touch).
#   * Every resting order cancels at a constant hazard (full or partial), so
#     total cancel flow scales with book size and depth stays stationary.
#   * Market order signs are persistent (order splitting), which produces the
#     positive trade-sign autocorrelation seen in real markets.
#   * Market orders walk the book with price-time (FIFO) priority.
#
# LOBSTER message file columns:
#   time (sec after midnight), type, order_id, size, price (USD * 10000), direction
#   type: 1 submit, 2 partial cancel, 3 delete, 4 visible execution,
#         5 hidden execution, 7 trading halt
#   direction: side of the *resting/limit* order (1 buy, -1 sell). For an
#   execution, direction = -1 means a sell limit order was hit, i.e. the trade
#   was buyer-initiated.
#
# LOBSTER orderbook file: one row per message, the book state *after* it:
#   ask_price_1, ask_size_1, bid_price_1, bid_size_1, ..., up to `levels`.
#   Empty levels: ask price 9999999999, bid price -9999999999, size 0.
# -----------------------------------------------------------------------------

simulate_lobster <- function(out_dir = "data/sample",
                             ticker = "SIM",
                             date = "2026-01-02",
                             levels = 5L,
                             start_sec = 34200,     # 09:30:00
                             end_sec = 57600,       # 16:00:00
                             base_rate = 4,         # new orders / sec at midday
                             p_market = 0.12,       # share of new orders that are market orders
                             cancel_rate = 0.05,    # cancel hazard per resting order per sec
                             sign_persistence = 0.7,
                             start_price = 100,
                             seed = 42,
                             verbose = TRUE) {
  stopifnot(base_rate > 0, p_market > 0, p_market < 1, cancel_rate > 0)
  set.seed(seed)

  TICK <- 100L          # one cent in LOBSTER price units
  grid_n <- 4000L       # price grid size in ticks (~ +/- $20 around the start)
  base_tick <- round(start_price * 100) - grid_n %/% 2L   # price(idx) = (base_tick + idx) cents
  mid0 <- grid_n %/% 2L

  dep_b <- numeric(grid_n)   # aggregate bid depth per tick
  dep_a <- numeric(grid_n)   # aggregate ask depth per tick

  # message buffers (grown on demand)
  cap <- as.integer(2 * base_rate * (end_sec - start_sec)) + 10000L
  m_time <- numeric(cap); m_type <- integer(cap); m_id <- integer(cap)
  m_size <- integer(cap); m_idx <- integer(cap); m_dir <- integer(cap)
  k <- 0L

  # resting orders: id -> side / price index / remaining size
  o_side <- integer(cap); o_idx <- integer(cap); o_size <- integer(cap)
  act <- integer(cap)        # compact list of active order ids
  pos <- integer(cap)        # id -> position in `act` (0 = inactive)
  n_act <- 0L
  next_id <- 0L

  lot_sizes <- c(100L, 200L, 300L, 400L, 500L, 1000L)
  lot_probs <- c(.40, .20, .12, .08, .12, .08)
  mkt_sizes <- c(100L, 200L, 300L, 500L, 800L, 1000L, 2000L)
  mkt_probs <- c(.30, .20, .15, .15, .08, .08, .04)
  n_market <- 0L

  # ---- initial book: 2 orders on each of 10 levels per side, at the open ----
  for (lvl in 1:10) {
    for (s in c(1L, -1L)) {
      for (rep_i in 1:2) {
        p <- if (s == 1L) mid0 - lvl else mid0 + lvl
        sz <- sample(lot_sizes, 1, prob = lot_probs)
        next_id <- next_id + 1L; id <- next_id
        o_side[id] <- s; o_idx[id] <- p; o_size[id] <- sz
        n_act <- n_act + 1L; act[n_act] <- id; pos[id] <- n_act
        if (s == 1L) dep_b[p] <- dep_b[p] + sz else dep_a[p] <- dep_a[p] + sz
        k <- k + 1L
        m_time[k] <- start_sec; m_type[k] <- 1L; m_id[k] <- id
        m_size[k] <- sz; m_idx[k] <- p; m_dir[k] <- s
      }
    }
  }

  t <- start_sec
  T_len <- end_sec - start_sec
  last_sign <- 1L
  n_events <- 0L

  repeat {
    x <- (t - start_sec) / T_len
    mult <- 1 + 1.5 * (2 * x - 1)^2              # U-shaped intraday intensity
    canc <- cancel_rate * n_act                  # every resting order can cancel
    t <- t + stats::rexp(1, mult * (base_rate + canc))
    if (t >= end_sec) break
    n_events <- n_events + 1L

    # grow buffers if needed (a market order can create up to ~20 fills)
    if (k + 100L > length(m_time)) {
      add <- length(m_time)
      m_time <- c(m_time, numeric(add)); m_type <- c(m_type, integer(add))
      m_id <- c(m_id, integer(add)); m_size <- c(m_size, integer(add))
      m_idx <- c(m_idx, integer(add)); m_dir <- c(m_dir, integer(add))
    }
    if (next_id + 10L > length(o_side)) {
      add <- length(o_side)
      o_side <- c(o_side, integer(add)); o_idx <- c(o_idx, integer(add))
      o_size <- c(o_size, integer(add)); act <- c(act, integer(add))
      pos <- c(pos, integer(add))
    }

    bids <- which(dep_b > 0); asks <- which(dep_a > 0)
    bb <- if (length(bids)) bids[length(bids)] else NA_integer_
    ba <- if (length(asks)) asks[1] else NA_integer_

    # event type: cancel w.p. p_c, otherwise market w.p. p_market, else limit
    u <- stats::runif(1)
    p_c <- canc / (base_rate + canc)
    if (is.na(bb) || is.na(ba)) u <- 1   # a side is empty: force a limit order refill

    if (u >= p_c + (1 - p_c) * p_market) {
      # ------------------------------ limit order ------------------------------
      s <- if (is.na(bb)) 1L else if (is.na(ba)) -1L else sample(c(1L, -1L), 1)
      ref_ask <- if (!is.na(ba)) ba else bb + 1L
      ref_bid <- if (!is.na(bb)) bb else ba - 1L
      d <- 1L + as.integer(stats::rgeom(1, 0.3))
      p <- if (s == 1L) ref_ask - d else ref_bid + d
      p <- max(2L, min(grid_n - 1L, p))
      sz <- sample(lot_sizes, 1, prob = lot_probs)
      next_id <- next_id + 1L; id <- next_id
      o_side[id] <- s; o_idx[id] <- p; o_size[id] <- sz
      n_act <- n_act + 1L; act[n_act] <- id; pos[id] <- n_act
      if (s == 1L) dep_b[p] <- dep_b[p] + sz else dep_a[p] <- dep_a[p] + sz
      k <- k + 1L
      m_time[k] <- t; m_type[k] <- 1L; m_id[k] <- id
      m_size[k] <- sz; m_idx[k] <- p; m_dir[k] <- s

    } else if (u < p_c) {
      # ------------------------------ cancellation ------------------------------
      if (n_act > 0L) {
        j <- sample.int(n_act, 1); id <- act[j]
        full <- stats::runif(1) < 0.8 || o_size[id] <= 100L
        csz <- if (full) o_size[id] else (o_size[id] %/% 200L) * 100L
        p <- o_idx[id]
        if (o_side[id] == 1L) dep_b[p] <- dep_b[p] - csz else dep_a[p] <- dep_a[p] - csz
        k <- k + 1L
        m_time[k] <- t; m_type[k] <- if (full) 3L else 2L; m_id[k] <- id
        m_size[k] <- csz; m_idx[k] <- p; m_dir[k] <- o_side[id]
        o_size[id] <- o_size[id] - csz
        if (full) {
          last <- act[n_act]; act[j] <- last; pos[last] <- j
          pos[id] <- 0L; n_act <- n_act - 1L
        }
      }

    } else {
      # ------------------------------ market order ------------------------------
      n_market <- n_market + 1L
      s <- if (stats::runif(1) < sign_persistence) last_sign else sample(c(1L, -1L), 1)
      last_sign <- s
      remaining <- sample(mkt_sizes, 1, prob = mkt_probs)
      while (remaining > 0L) {
        if (s == 1L) {
          lv <- which(dep_a > 0); if (!length(lv)) break; p <- lv[1]
        } else {
          lv <- which(dep_b > 0); if (!length(lv)) break; p <- lv[length(lv)]
        }
        ids <- act[seq_len(n_act)]
        q <- sort(ids[o_idx[ids] == p & o_side[ids] == -s])   # FIFO: lower id = earlier
        if (!length(q)) stop("internal error: depth at a level with no resting orders")
        for (id in q) {
          if (remaining <= 0L) break
          f <- min(remaining, o_size[id])
          k <- k + 1L
          m_time[k] <- t; m_type[k] <- 4L; m_id[k] <- id
          m_size[k] <- f; m_idx[k] <- p; m_dir[k] <- -s
          o_size[id] <- o_size[id] - f
          remaining <- remaining - f
          if (s == 1L) dep_a[p] <- dep_a[p] - f else dep_b[p] <- dep_b[p] - f
          if (o_size[id] == 0L) {
            j <- pos[id]; last <- act[n_act]; act[j] <- last; pos[last] <- j
            pos[id] <- 0L; n_act <- n_act - 1L
          }
        }
      }
    }
  }

  messages <- data.frame(
    time = m_time[1:k],
    type = m_type[1:k],
    order_id = m_id[1:k],
    size = m_size[1:k],
    price = (base_tick + m_idx[1:k]) * TICK,
    direction = m_dir[1:k]
  )
  if (verbose) message(sprintf("simulated %d events -> %d messages (%d market orders)",
                               n_events, k, n_market))

  orderbook <- reconstruct_orderbook(messages, levels)

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stem <- sprintf("%s_%s_%d_%d", ticker, date, start_sec * 1000, end_sec * 1000)
  msg_file <- file.path(out_dir, sprintf("%s_message_%d.csv", stem, levels))
  ob_file <- file.path(out_dir, sprintf("%s_orderbook_%d.csv", stem, levels))
  write_lobster_csv(messages, msg_file, time_col = "time")
  write_lobster_csv(as.data.frame(orderbook), ob_file)
  if (verbose) message("wrote ", msg_file, "\nwrote ", ob_file)

  invisible(list(messages = messages, orderbook = orderbook,
                 message_file = msg_file, orderbook_file = ob_file,
                 n_market_orders = n_market))
}

# Replays a LOBSTER message stream and returns the LOBSTER orderbook matrix
# (book state after every message). Only valid when the stream starts from an
# empty book, as the simulator's does. Real LOBSTER data ships its own
# orderbook file, so this is not needed there.
reconstruct_orderbook <- function(messages, levels = 5L) {
  px <- sort(unique(messages$price))
  n <- nrow(messages)
  idx <- match(messages$price, px)
  dep_b <- numeric(length(px)); dep_a <- numeric(length(px))
  ob <- matrix(0, nrow = n, ncol = 4L * levels)
  sgn <- ifelse(messages$type == 1L, 1, ifelse(messages$type %in% c(2L, 3L, 4L), -1, 0))
  for (i in seq_len(n)) {
    if (sgn[i] != 0) {
      p <- idx[i]
      if (messages$direction[i] == 1L) dep_b[p] <- dep_b[p] + sgn[i] * messages$size[i]
      else dep_a[p] <- dep_a[p] + sgn[i] * messages$size[i]
    }
    ai <- which(dep_a > 0); bi <- rev(which(dep_b > 0))
    ai <- ai[seq_len(min(levels, length(ai)))]
    bi <- bi[seq_len(min(levels, length(bi)))]
    ap <- rep(9999999999, levels); as_ <- numeric(levels)
    bp <- rep(-9999999999, levels); bs <- numeric(levels)
    ap[seq_along(ai)] <- px[ai]; as_[seq_along(ai)] <- dep_a[ai]
    bp[seq_along(bi)] <- px[bi]; bs[seq_along(bi)] <- dep_b[bi]
    ob[i, ] <- as.vector(rbind(ap, as_, bp, bs))
  }
  nm <- character(0)
  for (l in seq_len(levels)) {
    nm <- c(nm, paste0(c("ask_price_", "ask_size_", "bid_price_", "bid_size_"), l))
  }
  colnames(ob) <- nm
  ob
}

# LOBSTER files have no header; integers must not be written in scientific
# notation (R would print 1e+06), so everything is formatted explicitly.
write_lobster_csv <- function(df, path, time_col = NULL) {
  out <- lapply(names(df), function(col) {
    v <- df[[col]]
    if (!is.null(time_col) && col == time_col) formatC(v, format = "f", digits = 9)
    else if (is.integer(v)) formatC(v, format = "d", big.mark = "")
    # doubles (prices, and LOBSTER's +/-9999999999 empty-level marker, which is
    # too big for an R integer) are written as whole numbers via "f"
    else formatC(v, format = "f", digits = 0, big.mark = "")
  })
  names(out) <- names(df)
  out <- as.data.frame(out, stringsAsFactors = FALSE)
  utils::write.table(out, path, sep = ",", quote = FALSE,
                     row.names = FALSE, col.names = FALSE)
}
