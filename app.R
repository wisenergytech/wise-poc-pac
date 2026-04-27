# Entry point for Shiny Server, shinyapps.io, and Docker/Cloud Run.
# Loads the package (all R/ files, NAMESPACE, DESCRIPTION deps) then starts the app.
pkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)
port <- as.integer(Sys.getenv("PORT", "3838"))
run_app(options = list(host = "0.0.0.0", port = port))
