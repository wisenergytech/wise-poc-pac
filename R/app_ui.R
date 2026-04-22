#' The application User-Interface
#'
#' @param request Internal parameter for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_ui <- function(request) {
  # Colors (cl) and helpers (tip, kpi_card, explainer, pl_layout)
  # are loaded from R/fct_ui_theme.R by Golem's R/ sourcing.

  shiny::tagList(
    golem_add_external_resources(),

    bslib::page_fillable(
      theme = wise_theme(),

      bslib::layout_sidebar(fillable = TRUE,
        sidebar = bslib::sidebar(width = 300, bg = cl$bg_card,
          mod_sidebar_ui("sidebar")
        ),

        mod_status_bar_ui("status_bar"),

        bslib::navset_card_tab(id = "main_tabs",
          bslib::nav_panel(title = "Energie", icon = shiny::icon("bolt"),
            mod_energie_ui("energie")),
          bslib::nav_panel(title = "Finances", icon = shiny::icon("euro-sign"),
            mod_finances_ui("finances")),
          bslib::nav_panel(title = "Impact CO2", icon = shiny::icon("leaf"),
            mod_co2_ui("co2")),
          # bslib::nav_panel(title = "Dimensionnement", icon = shiny::icon("solar-panel"),
          #   mod_dimensionnement_ui("dimensionnement")),
          bslib::nav_panel(title = "Comparaison", icon = shiny::icon("right-left"),
            mod_comparaison_ui("comparaison")),
          bslib::nav_panel(title = "Documentation", icon = shiny::icon("book"),
            mod_documentation_ui("documentation"))
        )
      ) # fin layout_sidebar
    ) # fin page_fillable
  ) # fin tagList
}

#' Add external Resources to the Application
#'
#' This function is internally used to allow you to add external
#' resources inside the Shiny application.
#'
#' @noRd
golem_add_external_resources <- function() {
  golem::add_resource_path("www", app_sys("app/www"))

  shiny::tags$head(
    golem::favicon(),
    shiny::tags$link(rel = "stylesheet", type = "text/css", href = "www/custom.css")
  )
}
