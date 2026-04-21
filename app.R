# Entry point for Shiny Server, shinyapps.io, and Docker/Cloud Run.
# Loads the package (all R/ files, NAMESPACE, DESCRIPTION deps) then starts the app.
pkgload::load_all(export_all = FALSE, helpers = FALSE, attach_testthat = FALSE)
run_app()
