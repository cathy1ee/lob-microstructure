# -----------------------------------------------------------------------------
# db.R — database connection, LOBSTER loading, and running the SQL pipeline.
#
# The SQL in sql/ is engine-neutral. SQLite (via RSQLite) is the default;
# set options(lobms.engine = "duckdb") to run the same pipeline on DuckDB,
# which is noticeably faster on multi-day / multi-ticker data.
# -----------------------------------------------------------------------------

db_connect <- function(path = "output/lob.sqlite",
                       engine = getOption("lobms.engine", "sqlite")) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  if (identical(engine, "duckdb")) {
    if (!requireNamespace("duckdb", quietly = TRUE)) {
      stop("options(lobms.engine = 'duckdb') needs install.packages('duckdb')")
    }
    DBI::dbConnect(duckdb::duckdb(), dbdir = sub("\\.sqlite$", ".duckdb", path))
  } else {
    DBI::dbConnect(RSQLite::SQLite(), path)
  }
}

# Read one LOBSTER message/orderbook pair into `messages` and `book`.
#   messages: event_id, time, t_ms, type, order_id, size, price ($), direction
#   book:     event_id, level, ask_price, ask_size, bid_price, bid_size (long)
# Row i of the orderbook file is the state after message i, so both share
# event_id = row number.
load_lobster <- function(con, message_file, orderbook_file) {
  msg <- utils::read.csv(message_file, header = FALSE)
  # some LOBSTER files carry trailing empty columns
  msg <- msg[, 1:6]
  names(msg) <- c("time", "type", "order_id", "size", "price", "direction")
  ob <- as.matrix(utils::read.csv(orderbook_file, header = FALSE))
  if (nrow(ob) != nrow(msg)) stop("message and orderbook files have different row counts")
  if (ncol(ob) %% 4 != 0) stop("orderbook file must have 4 columns per level")

  n <- nrow(msg)
  L <- ncol(ob) %/% 4

  messages <- data.frame(
    event_id = seq_len(n),
    time = msg$time,
    t_ms = as.integer(round(msg$time * 1000)),
    type = as.integer(msg$type),
    order_id = msg$order_id,
    size = as.integer(msg$size),
    price = msg$price / 1e4,
    direction = as.integer(msg$direction)
  )

  ap <- ob[, seq(1, 4 * L, by = 4), drop = FALSE]
  as_ <- ob[, seq(2, 4 * L, by = 4), drop = FALSE]
  bp <- ob[, seq(3, 4 * L, by = 4), drop = FALSE]
  bs <- ob[, seq(4, 4 * L, by = 4), drop = FALSE]
  # as.vector() is column-major: all of level 1, then all of level 2, ...
  book <- data.frame(
    event_id = rep(seq_len(n), times = L),
    level = rep(seq_len(L), each = n),
    ask_price = as.vector(ap) / 1e4,
    ask_size = as.integer(as.vector(as_)),
    bid_price = as.vector(bp) / 1e4,
    bid_size = as.integer(as.vector(bs))
  )
  # LOBSTER marks empty levels with +/-9999999999 and size 0
  book$ask_price[book$ask_size == 0] <- NA
  book$bid_price[book$bid_size == 0] <- NA

  DBI::dbWriteTable(con, "messages", messages, overwrite = TRUE)
  DBI::dbWriteTable(con, "book", book, overwrite = TRUE)
  invisible(list(n_messages = n, levels = L))
}

# Split a .sql file into statements: strip `--` comments, split on `;`.
# (None of the project SQL contains `--` or `;` inside string literals.)
read_sql_statements <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines <- sub("--.*$", "", lines)
  stmts <- strsplit(paste(lines, collapse = "\n"), ";", fixed = TRUE)[[1]]
  stmts <- trimws(stmts)
  stmts[nzchar(stmts)]
}

run_sql_file <- function(con, path, verbose = TRUE) {
  t0 <- Sys.time()
  for (s in read_sql_statements(path)) DBI::dbExecute(con, s)
  if (verbose) {
    message(sprintf("  %-32s %5.1fs", basename(path),
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }
  invisible(TRUE)
}

run_pipeline <- function(con, sql_dir = "sql", verbose = TRUE) {
  files <- sort(list.files(sql_dir, pattern = "\\.sql$", full.names = TRUE))
  if (verbose) message("running SQL pipeline:")
  for (f in files) run_sql_file(con, f, verbose)
  invisible(files)
}

# Convenience: find the LOBSTER file pair in a directory.
find_lobster_files <- function(dir) {
  msg <- list.files(dir, pattern = "_message_\\d+\\.csv$", full.names = TRUE)
  if (length(msg) == 0) stop("no *_message_N.csv file in ", dir)
  msg <- msg[1]
  ob <- sub("_message_", "_orderbook_", msg)
  if (!file.exists(ob)) stop("missing orderbook file: ", ob)
  list(message_file = msg, orderbook_file = ob)
}

tbl <- function(con, name) DBI::dbGetQuery(con, paste("SELECT * FROM", name))
