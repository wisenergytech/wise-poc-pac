#' The application User-Interface
#'
#' @param request Internal parameter for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_ui <- function(request) {
  # Colors (cl) and helpers (tip, kpi_card, explainer, pl_layout)
  # are loaded from R/fct_ui_theme.R by Golem's R/ sourcing.

  if (auth_enabled()) {
    # Auth mode: login form + placeholder for main app (rendered server-side)
    shiny::tagList(
      golem_add_external_resources(),
      mod_auth_ui("auth"),
      shiny::uiOutput("main_app_ui")
    )
  } else {
    # No auth: render app directly
    shiny::tagList(
      golem_add_external_resources(),
      main_app_ui_content()
    )
  }
}

#' Main app UI content (extracted for reuse)
#' @noRd
main_app_ui_content <- function() {
  shiny::tagList(
    # Loading overlay — visible until server signals params_r() is ready
    shiny::tags$div(id = "app-loading-overlay",
      style = paste0(
        "position:fixed;top:0;left:0;width:100%;height:100%;z-index:9999;",
        "background:rgba(246,247,248,0.92);display:flex;flex-direction:column;",
        "align-items:center;justify-content:center;"),
      shiny::tags$div(style = paste0(
        "width:44px;height:44px;border:3px solid #E2E8F0;",
        "border-top-color:#1D4345;border-radius:50%;",
        "animation:spin .8s linear infinite;")),
      shiny::tags$div(style = paste0(
        "margin-top:16px;font-family:'JetBrains Mono',monospace;",
        "font-size:.82rem;color:#475569;letter-spacing:.1em;"),
        "CHARGEMENT DES DONN\u00c9ES...")),

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
  )
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
    shiny::tags$link(rel = "stylesheet", type = "text/css", href = "www/custom.css"),
    shiny::tags$script(shiny::HTML("
      Shiny.addCustomMessageHandler('hide-loading-overlay', function(msg) {
        var overlay = document.getElementById('app-loading-overlay');
        if (overlay) {
          overlay.style.transition = 'opacity 0.4s ease';
          overlay.style.opacity = '0';
          setTimeout(function() { overlay.remove(); }, 400);
        }
      });
    "))
  )
}
