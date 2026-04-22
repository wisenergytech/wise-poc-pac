#' The application User-Interface
#'
#' @param request Internal parameter for `{shiny}`.
#'     DO NOT REMOVE.
#' @noRd
app_ui <- function(request) {
  # Colors (cl) and helpers (tip, kpi_card, explainer, pac_theme, pl_layout)
  # are loaded from R/fct_ui_theme.R by Golem's R/ sourcing.

  shiny::tagList(
    golem_add_external_resources(),

    bslib::page_fillable(
      theme = pac_theme(),

      # Inline CSS (legacy from app.R -- will be migrated to custom.css in Phase 6)
      shiny::tags$head(shiny::tags$style(shiny::HTML(sprintf("
        body{background:%s} .card{border:1px solid %s;border-radius:12px}
        .card-header{background:transparent;border-bottom:1px solid %s;font-family:'JetBrains Mono',monospace;font-size:.8rem;text-transform:uppercase;letter-spacing:.1em;color:%s}
        .nav-tabs .nav-link{color:%s;border:none;font-family:'JetBrains Mono',monospace;font-size:.85rem;letter-spacing:.05em}
        .nav-tabs .nav-link.active{color:%s!important;border-bottom:2px solid %s}
        .kpi-value{font-family:'JetBrains Mono',monospace;font-size:1.8rem;font-weight:700;line-height:1}
        .kpi-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.1em;color:%s;margin-top:4px}
        .kpi-unit{font-size:.75rem;color:%s;margin-left:4px}
        .kpi-sub{font-size:.65rem;color:%s;margin-top:2px;font-family:'JetBrains Mono',monospace}
        .kpi-gain{font-size:.72rem;font-weight:600;margin-top:1px;font-family:'JetBrains Mono',monospace}
        .kpi-gain.positive{color:%s} .kpi-gain.negative{color:%s}
        .sidebar-section{margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid %s}
        .section-title{font-family:'JetBrains Mono',monospace;font-size:.7rem;text-transform:uppercase;letter-spacing:.15em;color:%s;margin-bottom:8px}
        .form-label{font-size:.78rem;color:%s}
        .form-control,.form-select{font-size:.82rem;background:%s!important;border-color:%s!important}
        .btn-primary{background:%s;border:none;font-family:'JetBrains Mono',monospace;font-size:.82rem;letter-spacing:.05em}
        .btn-primary:hover{background:%s;filter:brightness(1.15)}
        #status_bar{font-family:'JetBrains Mono',monospace;font-size:.75rem;color:%s;padding:8px 16px;background:%s;border-radius:8px;margin-bottom:12px}
        #status_bar .status-line{margin:2px 0}
        #status_bar .status-tag{color:%s;font-weight:700;margin-right:6px}
        #status_bar .spinner{display:inline-block;width:12px;height:12px;border:2px solid %s;border-top-color:%s;border-radius:50%%;animation:spin 0.8s linear infinite;vertical-align:middle;margin-left:8px}
        #status_bar .status-running{color:%s;font-weight:700;margin-left:8px}
        @keyframes spin{to{transform:rotate(360deg)}}
        .bslib-full-screen .card{border:none} .bslib-full-screen .card-body{background:%s}
        .info-tip{display:inline-block;width:16px;height:16px;border-radius:50%%;background:%s;color:%s;font-size:10px;text-align:center;line-height:16px;cursor:help;margin-left:4px;font-weight:700;vertical-align:middle}
        .info-tip:hover{filter:brightness(1.3)}
        .tab-explainer{background:%s;border:1px solid %s;border-radius:8px;padding:12px 16px;margin-bottom:16px;font-size:.82rem;color:%s;line-height:1.5}
        .tab-explainer summary{cursor:pointer;font-family:'JetBrains Mono',monospace;font-size:.75rem;text-transform:uppercase;letter-spacing:.1em;color:%s;list-style:none}
        .tab-explainer summary::-webkit-details-marker{display:none}
        .tab-explainer summary::before{content:'\\25B6  ';font-size:.6rem}
        .tab-explainer[open] summary::before{content:'\\25BC  '}
        .tab-explainer p{margin:8px 0 4px 0}
        .tab-explainer ul{margin:4px 0;padding-left:20px}
        .tab-explainer li{margin-bottom:2px}
        .tab-explainer strong{color:%s}
        .tab-explainer code{background:%s;padding:1px 5px;border-radius:3px;font-size:.78rem;color:%s}
        .vignette-content h1,.vignette-content h2,.vignette-content h3,.vignette-content h4{color:%s;font-family:'JetBrains Mono',monospace;margin-top:1.5em}
        .vignette-content h1{font-size:1.3rem} .vignette-content h2{font-size:1.1rem} .vignette-content h3{font-size:.95rem}
        .vignette-content pre{background:%s;border:1px solid %s;border-radius:8px;padding:12px;font-size:.78rem;color:%s;overflow-x:auto}
        .vignette-content code{background:%s;padding:1px 5px;border-radius:3px;font-size:.8rem;color:%s}
        .vignette-content pre code{background:transparent;padding:0}
        .vignette-content table{width:100%%;border-collapse:collapse;margin:12px 0;font-size:.82rem}
        .vignette-content th{background:%s;color:%s;padding:8px 12px;text-align:left;border-bottom:2px solid %s;font-family:'JetBrains Mono',monospace;font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}
        .vignette-content td{padding:6px 12px;border-bottom:1px solid %s;color:%s}
        .vignette-content blockquote{border-left:3px solid %s;padding-left:12px;color:%s;font-style:italic}
        .vignette-content a{color:%s}
        .vignette-content img{max-width:100%%;border-radius:8px}
      ", cl$bg_dark,cl$grid,cl$grid,cl$accent,cl$text_muted,cl$accent,cl$accent,cl$text_muted,
         cl$text_muted,cl$text_muted,cl$success,cl$danger,
         cl$grid,cl$accent,cl$text_muted,cl$bg_input,cl$grid,cl$accent,cl$accent,
         cl$text_muted,cl$bg_card,
         cl$accent,cl$grid,cl$accent,cl$accent,
         cl$bg_card,cl$accent3,cl$bg_dark,cl$bg_input,cl$grid,cl$text_muted,cl$accent,cl$accent,cl$bg_input,cl$opti,
         cl$accent,cl$bg_input,cl$grid,cl$opti,cl$bg_input,cl$opti,cl$bg_card,cl$accent,cl$grid,cl$grid,cl$text,cl$accent,cl$text_muted,cl$accent)))),

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
          bslib::nav_panel(title = "Details", icon = shiny::icon("magnifying-glass"),
            mod_details_ui("details")),
          bslib::nav_panel(title = "Dimensionnement", icon = shiny::icon("solar-panel"),
            mod_dimensionnement_ui("dimensionnement")),
          bslib::nav_panel(title = "Comparaison", icon = shiny::icon("right-left"),
            mod_comparaison_ui("comparaison")),
          bslib::nav_panel(title = "Contraintes", icon = shiny::icon("check-circle"),
            mod_contraintes_ui("contraintes")),
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
