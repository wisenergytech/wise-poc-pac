#' Données Tab Module UI
#'
#' Displays import diagnostics, PAC detection results, PV reconstruction
#' status, and a data preview. Visible only in CSV mode.
#'
#' @param id module id
#' @noRd
mod_donnees_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = c(6, 6),
      # Left column: Import summary + PAC detection
      shiny::tagList(
        bslib::card(
          bslib::card_header(shiny::tags$strong("R\u00e9sum\u00e9 import")),
          bslib::card_body(shiny::uiOutput(ns("import_summary")))),
        bslib::card(
          bslib::card_header(shiny::tags$strong("D\u00e9tection PAC")),
          bslib::card_body(shiny::uiOutput(ns("pac_detection"))))
      ),
      # Right column: PV + Diagnostic
      shiny::tagList(
        bslib::card(
          bslib::card_header(shiny::tags$strong("PV reconstitu\u00e9")),
          bslib::card_body(shiny::uiOutput(ns("pv_status")))),
        bslib::card(
          bslib::card_header(shiny::tags$strong("Diagnostic \u00e9nerg\u00e9tique")),
          bslib::card_body(shiny::uiOutput(ns("diagnostic"))))
      )
    ),
    bslib::card(
      bslib::card_header(shiny::tags$strong("Aper\u00e7u des donn\u00e9es (20 premi\u00e8res lignes)")),
      bslib::card_body(DT::DTOutput(ns("data_preview"))))
  )
}

#' Données Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_donnees_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    # ---- Import summary ----
    output$import_summary <- shiny::renderUI({
      shiny::req(sidebar$data_source() == "csv")
      meta <- sidebar$import_meta()
      shiny::req(meta)

      shiny::tags$div(style = "font-size:.85rem;line-height:1.8;",
        shiny::HTML(paste(meta$summary_lines, collapse = "<br>")))
    })

    # ---- PAC detection ----
    output$pac_detection <- shiny::renderUI({
      shiny::req(sidebar$data_source() == "csv")
      meta <- sidebar$import_meta()
      shiny::req(meta, meta$pac_method)

      lines <- sprintf("<b>M\u00e9thode</b> : %s", meta$pac_method)
      if (!is.na(meta$pac_p95_kw)) {
        lines <- c(lines, sprintf("<b>Puissance PAC P95</b> : %.1f kW", meta$pac_p95_kw))
      }
      if (!is.na(meta$pac_talon_w)) {
        lines <- c(lines, sprintf("<b>Talon installation</b> : %.0f W", meta$pac_talon_w))
      }
      shiny::tags$div(style = "font-size:.85rem;line-height:1.8;",
        shiny::HTML(paste(lines, collapse = "<br>")))
    })

    # ---- PV status ----
    output$pv_status <- shiny::renderUI({
      shiny::req(sidebar$data_source() == "csv")
      meta <- sidebar$import_meta()
      shiny::req(meta)

      lines <- character(0)
      if (!is.null(meta$pv_total_kwh)) {
        lines <- c(lines, sprintf("<b>PV total reconstitu\u00e9</b> : %.0f kWh", meta$pv_total_kwh))
      }
      if (!is.null(meta$pv_stability_msg)) {
        icon <- if (isTRUE(meta$pv_stable)) "&#9989;" else "&#9888;"
        lines <- c(lines, sprintf("%s %s", icon, meta$pv_stability_msg))
      }
      if (!is.null(meta$pv_autocons_pct)) {
        lines <- c(lines, sprintf("<b>Autoconsommation</b> : %.1f%%", meta$pv_autocons_pct))
      }
      shiny::tags$div(style = "font-size:.85rem;line-height:1.8;",
        shiny::HTML(paste(lines, collapse = "<br>")))
    })

    # ---- Diagnostic ----
    output$diagnostic <- shiny::renderUI({
      shiny::req(sidebar$data_source() == "csv")
      meta <- sidebar$import_meta()
      shiny::req(meta, meta$diag_lines)

      shiny::tags$div(style = "font-size:.8rem;line-height:1.8;",
        shiny::HTML(paste(meta$diag_lines, collapse = "<br>")))
    })

    # ---- Data preview ----
    output$data_preview <- DT::renderDT({
      shiny::req(sidebar$data_source() == "csv")
      df <- sidebar$sim_filtered()
      shiny::req(df)
      preview <- utils::head(df, 20)
      # Round numeric columns for readability
      num_cols <- sapply(preview, is.numeric)
      preview[num_cols] <- lapply(preview[num_cols], round, 3)
      DT::datatable(preview, options = list(
        pageLength = 20, scrollX = TRUE, dom = "t",
        columnDefs = list(list(className = "dt-center", targets = "_all"))
      ), rownames = FALSE)
    })
  })
}
