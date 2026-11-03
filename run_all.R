#!/usr/bin/env Rscript
# -----------------------------------------------------------------------------
# End-to-end pipeline. Run from the repository root.
#
#   Rscript run_all.R                       # simulate a trading day, analyze it
#   Rscript run_all.R data/lobster/AAPL     # analyze a real LOBSTER file pair
#
# Outputs:
#   output/lob.sqlite      all tables (query them yourself!)
#   output/figures/*.png   charts
#   output/RESULTS.md      headline numbers
# -----------------------------------------------------------------------------

if (!dir.exists("sql") || !dir.exists("R")) {
  stop("run this script from the repository root (the folder with sql/ and R/)")
}

for (f in c("R/simulate_lob.R", "R/db.R", "R/analysis.R", "R/plots.R")) source(f)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) {
  files <- find_lobster_files(args[1])
} else {
  if (length(list.files("data/sample", pattern = "_message_")) == 0) {
    message("no sample data found: simulating one trading day (takes a minute)...")
    simulate_lobster(out_dir = "data/sample")
  }
  files <- find_lobster_files("data/sample")
}

message("loading ", basename(files$message_file))
con <- db_connect("output/lob.sqlite")

info <- load_lobster(con, files$message_file, files$orderbook_file)
message(sprintf("loaded %s messages, %d book levels",
                format(info$n_messages, big.mark = ","), info$levels))

run_pipeline(con, "sql")

message("fitting models and drawing figures...")
res <- analyze(con)
figs <- save_figures(res, "output/figures")
write_results_md(res, "output/RESULTS.md")
DBI::dbDisconnect(con)

cat("\n", paste(readLines("output/RESULTS.md"), collapse = "\n"), "\n", sep = "")
message("\nfigures: ", paste(basename(figs), collapse = ", "))
message("render the full report with:  rmarkdown::render('report/report.Rmd')")
