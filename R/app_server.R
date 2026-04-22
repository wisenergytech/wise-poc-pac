#' The application server-side
#'
#' @param input,output,session Internal parameters for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_server <- function(input, output, session) {

  # Initialize future plan for async CO2 fetching
  future::plan(future::multisession)

  # Load .env if present (for API keys etc.)
  env_file <- if (file.exists(".env")) ".env" else file.path(app_sys(), "..", "..", ".env")
  if (file.exists(env_file)) {
    env_lines <- readLines(env_file, warn = FALSE)
    for (line in env_lines) {
      line <- trimws(line)
      if (nchar(line) == 0 || startsWith(line, "#")) next
      parts <- strsplit(line, "=", fixed = TRUE)[[1]]
      if (length(parts) >= 2) {
        key <- trimws(parts[1])
        val <- trimws(paste(parts[-1], collapse = "="))
        do.call(Sys.setenv, setNames(list(val), key))
      }
    }
  }

  # ---- Sidebar module: handles params, data loading, simulation ----
  # Returns a list of reactives consumed by all other modules

  sidebar <- mod_sidebar_server("sidebar")

  # ---- Status bar ----
  mod_status_bar_server("status_bar", sidebar)

  # ---- Tab modules ----
  mod_energie_server("energie", sidebar)
  mod_finances_server("finances", sidebar)
  mod_co2_server("co2", sidebar)
  mod_dimensionnement_server("dimensionnement", sidebar)
  mod_comparaison_server("comparaison", sidebar)
  # ---- Documentation (vignettes) ----
  mod_documentation_server("documentation")
}
