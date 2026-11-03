# Install the R packages this project uses.
# A CRAN mirror is set explicitly: `Rscript` is non-interactive and cannot
# prompt you to choose one.
options(repos = c(CRAN = "https://cloud.r-project.org"))

pkgs <- c("DBI", "RSQLite", "ggplot2", "rmarkdown", "knitr", "testthat")
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) install.packages(missing)

still_missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(still_missing)) {
  stop("could not install: ", paste(still_missing, collapse = ", "))
}
message("All packages installed.")
message("Optional: install.packages('duckdb') to run the same SQL on DuckDB.")
