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

  if (auth_enabled()) {
    # ---- Auth gate ----
    authenticated <- mod_auth_server("auth")
    app_initialized <- shiny::reactiveVal(FALSE)

    output$main_app_ui <- shiny::renderUI({
      shiny::req(authenticated())
      # Hide login form, show main app
      # Signal server once the UI is in the DOM
      shiny::tagList(
        shiny::tags$script(shiny::HTML(
          "document.getElementById('auth-login-page').style.display = 'none';
           Shiny.setInputValue('app_ui_ready', true, {priority: 'event'});"
        )),
        main_app_ui_content()
      )
    })

    shiny::observeEvent(input$app_ui_ready, {
      if (!app_initialized()) {
        app_initialized(TRUE)
        init_app_modules(input, output, session)
      }
    })
  } else {
    # ---- No auth: init directly ----
    init_app_modules(input, output, session)
  }
}

#' Initialize all app modules
#' @noRd
init_app_modules <- function(input, output, session) {
  sidebar <- mod_sidebar_server("sidebar")

  # ---- Hide loading overlay once params are ready ----
  shiny::observe({
    p <- tryCatch(sidebar$params_r(), error = function(e) NULL)
    shiny::req(p)
    session$sendCustomMessage("hide-loading-overlay", list())
  }) |> shiny::bindEvent(sidebar$params_r())

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
