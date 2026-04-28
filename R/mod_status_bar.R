#' Status Bar Module UI
#'
#' Displays current parameters, simulation state, and results summary.
#'
#' @param id module id
#' @noRd
mod_status_bar_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::uiOutput(ns("status_bar"))
}

#' Status Bar Module Server
#'
#' Renders the status bar from sim_state and parameter reactives.
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_status_bar_server <- function(id, sidebar) {
  moduleServer(id, function(input, output, session) {

    output$status_bar <- shiny::renderUI({
      p <- tryCatch(sidebar$params_r(), error = function(e) NULL)
      if (is.null(p)) return(shiny::tags$div(id = "status_bar",
        shiny::tags$div(class = "status-line",
          shiny::tags$span(class = "status-tag", "RUN "),
          shiny::tags$span(shiny::HTML("Chargement des donn\u00e9es..."),
            shiny::tags$span(class = "spinner")))))
      running <- sidebar$sim_running()
      res <- tryCatch(sidebar$sim_result(), error = function(e) NULL)
      has_sim <- !running && !is.null(res) && !is.null(res$sim)

      approche <- sidebar$approche()
      ml <- c(optimizer = "MILP", milp = "MILP", lp = "LP", optimizer_lp = "LP", optimizer_qp = "QP", qp = "QP")
      mode_label <- if (has_sim) ml[res$mode] else {
        c(optimiseur = "MILP", optimiseur_lp = "LP", optimiseur_qp = "QP")[approche]
      }
      if (is.na(mode_label) || is.null(mode_label)) mode_label <- "?"

      is_csv <- tryCatch(sidebar$data_source(), error = function(e) "demo") == "csv"
      is_simple <- isTRUE(get_ui_config()$simple_mode)
      is_measured <- isTRUE(sidebar$csv_measured_eligible()) && !isTRUE(sidebar$pv_whatif())

      thermostat <- if (is_measured) {
        "Mesur\u00e9e"
      } else if (isTRUE(sidebar$pv_tracking())) {
        sprintf("AC %d%%", sidebar$autoconso_cible() %||% 35)
      } else {
        "thermostat"
      }
      contrat <- if (p$type_contrat == "fixe") {
        sprintf("fixe %.3f/%.3f EUR/kWh", p$prix_fixe_offtake, p$prix_fixe_injection)
      } else {
        sprintf("spot (taxe=%.3f, coeff_inj=%.2f)", p$taxe_transport_eur_kwh, p$coeff_injection)
      }

      header <- if (running) {
        shiny::tags$span(shiny::HTML(sprintf("SIMULATION %s EN COURS", mode_label)),
          shiny::tags$span(class = "spinner"),
          shiny::tags$span(class = "status-running", "..."))
      } else if (has_sim) {
        sim <- res$sim
        jours <- round(as.numeric(difftime(max(sim$timestamp), min(sim$timestamp), units = "days")), 1)
        k_sb <- sidebar$kpis_r()
        gain <- k_sb$gain_eur
        pct <- k_sb$gain_pct
        gain_col <- if (gain > 0.01) cl$success else if (gain < -0.01) cl$danger else cl$text_muted
        shiny::tags$span(shiny::HTML(sprintf("SIMULATION %s -- %.1f j &middot; %s pts &middot; GAIN <b style='color:%s'>%.1f EUR (%.1f%%)</b>",
          mode_label, jours, formatC(nrow(sim), format = "d", big.mark = " "),
          gain_col, gain, pct)))
      } else {
        shiny::tags$span(shiny::HTML(sprintf("PRET &middot; Mode selectionne : <b>%s</b>", mode_label)))
      }

      line_tag <- function(label, content) {
        shiny::tags$div(class = "status-line",
          shiny::tags$span(class = "status-tag", label),
          shiny::HTML(content))
      }

      date_range <- sidebar$date_range()
      data_src_label <- if (is_csv) "CSV" else "Demo"

      # ---- DIM line ----
      dim_parts <- c()
      if (is_csv && !isTRUE(sidebar$pv_whatif())) {
        dim_parts <- c(dim_parts, sprintf("PV=<b>%s kWc</b>", p$pv_kwc))
      } else {
        dim_parts <- c(dim_parts, sprintf("PV=<b>%s kWc</b> (ref=%s)", p$pv_kwc, p$pv_kwc_ref))
      }
      dim_parts <- c(dim_parts,
        sprintf("PAC=<b>%s kW</b> COP=%s", p$p_pac_kw, p$cop_nominal),
        sprintf("Ballon=<b>%s L</b> [%s..%s]&deg;C consigne=%s",
          p$volume_ballon_l, p$t_min, p$t_max, p$t_consigne))

      # ---- CFG line ----
      cfg_parts <- c(sprintf("Contrat=<b>%s</b>", contrat))

      if (!is_simple) {
        batt <- if (p$batterie_active) sprintf("%skWh/%skW rend=%.2f SoC[%d-%d]%%",
          p$batt_kwh, p$batt_kw, p$batt_rendement, round(p$batt_soc_min * 100), round(p$batt_soc_max * 100)) else "off"
        cfg_parts <- c(cfg_parts, sprintf("Batterie=<b>%s</b>", batt))
        cfg_parts <- c(cfg_parts, sprintf("TOU=<b>%s</b>", if (isTRUE(sidebar$tou_active())) "on" else "off"))
        cfg_parts <- c(cfg_parts, sprintf("Curtail=<b>%s</b>",
          if (isTRUE(sidebar$curtailment_active())) paste0(sidebar$curtail_kw(), "kW") else "off"))
        bloc <- switch(approche %||% "optimiseur_lp",
          optimiseur = paste0(sidebar$optim_bloc_h() %||% 4, "h"),
          optimiseur_lp = paste0(sidebar$optim_bloc_h_lp() %||% 24, "h"),
          optimiseur_qp = paste0(sidebar$optim_bloc_h_qp() %||% 24, "h"),
          "n/a")
        cfg_parts <- c(cfg_parts, sprintf("Bloc=<b>%s</b>", bloc))
        cfg_parts <- c(cfg_parts, sprintf("Slack=<b>%s EUR/C</b>",
          if (!is.null(sidebar$slack_penalty())) sidebar$slack_penalty() else "n/a"))
      }

      cfg_parts <- c(cfg_parts, sprintf("Baseline=<b>%s</b>", thermostat))
      cfg_parts <- c(cfg_parts, sprintf("Source: <b>%s</b>", data_src_label))

      if (!is_csv) {
        pv_src <- tryCatch(sidebar$pv_data_source(), error = function(e) "synthetic")
        pv_src_label <- if (!is.null(pv_src) && pv_src == "real_elia") {
          "R\u00e9el Elia (Namur)"
        } else if (!is.null(pv_src) && pv_src == "real_delaunoy") {
          pv_factor <- if (p$pv_kwc > 0) sprintf("%.2f", p$pv_kwc / 16) else "0"
          sprintf("R\u00e9el Delaunoy \u00d7%s", pv_factor)
        } else {
          "Synth\u00e9tique"
        }
        cfg_parts <- c(cfg_parts, sprintf("PV: <b>%s</b>", pv_src_label))
      }

      cfg_parts <- c(cfg_parts, sprintf("<b>%s</b> &rarr; <b>%s</b>",
        format(date_range[1], "%d/%m/%Y"), format(date_range[2], "%d/%m/%Y")))

      shiny::tags$div(id = "status_bar",
        line_tag("RUN ", as.character(header)),
        line_tag("DIM ", paste(dim_parts, collapse = " &middot; ")),
        line_tag("CFG ", paste(cfg_parts, collapse = " &middot; "))
      )
    })
    shiny::outputOptions(output, "status_bar", suspendWhenHidden = FALSE)
  })
}
