#' Run the Shiny Application
#' @param ... arguments to pass to golem_opts
#' @export
run_app <- function(...) {
  golem::with_golem_options(
    app = shinyApp(ui = app_ui, server = app_server),
    golem_opts = list(...)
  )
}
