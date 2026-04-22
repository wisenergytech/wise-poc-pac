#' Dimensionnement Tab Module UI
#'
#' Contains automagic grid search results, PV scenarios, and battery scenarios.
#'
#' @param id module id
#' @noRd
mod_dimensionnement_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    explainer(
      shiny::tags$summary("Comprendre le dimensionnement"),
      shiny::tags$p("Outil d'aide a la decision pour ", shiny::tags$strong("dimensionner votre installation"), "."),
      shiny::tags$ul(
        shiny::tags$li(shiny::tags$strong("Scenarii PV :"), " compare automatiquement votre taille PV actuelle avec +/- 2 kWc. Le graphique montre le cout net annuel (barres) et le taux d'autoconsommation (ligne). Un PV plus grand produit plus mais injecte aussi plus -- le point optimal depend de votre profil."),
        shiny::tags$li(shiny::tags$strong("Scenarii Batterie :"), " compare 5 tailles de batterie (0 a 20 kWh). Une batterie absorbe le surplus que le ballon ne peut plus stocker. Le cout diminue mais le retour sur investissement depend du prix de la batterie (non modelise ici)."),
        shiny::tags$li(shiny::tags$strong("Automagic :"), " teste ", shiny::tags$code("140 combinaisons"), " (7 tailles PV x 5 batteries x 2 modes x 2 contrats) et identifie la meilleure. La heatmap permet de voir les zones de cout optimal et les rendements decroissants.")
      ),
      shiny::tags$p(shiny::tags$strong("Conseil :"), " regardez le tableau des top 30. Parfois la 2e meilleure config coute 5 EUR de plus mais necessite une batterie beaucoup plus petite -- ce qui peut etre plus rentable vu le cout d'achat.")),
    shiny::conditionalPanel(
      condition = sprintf("output['%s']", ns("has_automagic")),
      ns = function(x) x,
      bslib::layout_columns(col_widths = 12,
        bslib::card(full_screen = TRUE, bslib::card_header(shiny::HTML("&#10024; Resultat Automagic -- meilleure configuration")),
          bslib::card_body(
            shiny::uiOutput(ns("automagic_best")),
            plotly::plotlyOutput(ns("plot_automagic_heatmap"), height = "350px"),
            DT::DTOutput(ns("table_automagic")))))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("Scenarii PV -- impact du dimensionnement"),
        bslib::card_body(
          shiny::tags$div(class = "form-text mb-2", style = sprintf("color:%s;font-size:.8rem;", cl$text_muted),
            "Compare automatiquement le scenario actuel avec +/- 2 kWc par pas de 1 kWc."),
          plotly::plotlyOutput(ns("plot_dim_pv"), height = "350px")))),
    shiny::conditionalPanel(
      condition = sprintf("input['%s']", shiny::NS("sidebar", "batterie_active")),
      ns = function(x) x,
      bslib::layout_columns(col_widths = 12,
        bslib::card(full_screen = TRUE, bslib::card_header("Scenarii Batterie -- impact de la capacite"),
          bslib::card_body(plotly::plotlyOutput(ns("plot_dim_batt"), height = "350px")))))
  )
}

#' Dimensionnement Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_dimensionnement_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_filtered   <- sidebar$sim_filtered
    params_r       <- sidebar$params_r
    sim_result     <- sidebar$sim_result
    raw_data       <- sidebar$raw_data
    date_range     <- sidebar$date_range
    baseline_type  <- sidebar$baseline_type
    parent_session <- sidebar$parent_session

    # ---- Automagic state ----
    automagic_results <- shiny::reactiveVal(NULL)

    output$has_automagic <- shiny::reactive({ !is.null(automagic_results()) })
    shiny::outputOptions(output, "has_automagic", suspendWhenHidden = FALSE)

    # ---- Run automagic (triggered from sidebar button via sidebar$run_automagic) ----
    shiny::observeEvent(sidebar$run_automagic(), {
      p <- params_r()
      df_raw <- raw_data()

      pv_range   <- seq(max(1, p$pv_kwc - 3), p$pv_kwc + 3, by = 1)
      batt_range <- c(0, 5, 10, 15, 20)

      shiny::withProgress(message = "Automagic en cours...", value = 0, {
        all_res <- run_grid_search(
          df_raw, p,
          pv_range = pv_range, batt_range = batt_range,
          progress_fn = function(k, total, detail) {
            shiny::setProgress(k / total, detail = detail)
          }
        )
        automagic_results(all_res)
      })

      if (!is.null(parent_session)) {
        bslib::updateNavsetCardTab(parent_session, "main_tabs", selected = "Dimensionnement")
      }
      shiny::showNotification(
        sprintf("Automagic termine! %d combinaisons testees. Meilleur cout: %d EUR/an",
                nrow(automagic_results()), automagic_results()$Cout_EUR[1]),
        type = "message", duration = 8)
    }, ignoreInit = TRUE)

    # ---- Automagic best ----
    output$automagic_best <- shiny::renderUI({
      shiny::req(automagic_results())
      best <- automagic_results() %>% dplyr::slice(1)

      shiny::tags$div(style = sprintf("background:%s;border-radius:8px;padding:16px;margin-bottom:16px;", cl$bg_input),
        bslib::layout_columns(col_widths = c(2, 2, 2, 2, 2, 2),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$accent), paste0(best$PV_kWc, " kWc")),
            shiny::tags$div(class = "kpi-label", "PV optimal")),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$accent3), paste0(best$Batterie_kWh, " kWh")),
            shiny::tags$div(class = "kpi-label", "Batterie")),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$success), toupper(best$Mode)),
            shiny::tags$div(class = "kpi-label", "Mode")),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$pv), toupper(best$Contrat)),
            shiny::tags$div(class = "kpi-label", "Contrat")),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$success), paste0(best$Cout_EUR, " EUR")),
            shiny::tags$div(class = "kpi-label", "Facture nette/an")),
          shiny::tags$div(class = "text-center",
            shiny::tags$div(class = "kpi-value", style = sprintf("color:%s;font-size:1.4rem;", cl$opti), paste0(best$Autoconso_pct, "%")),
            shiny::tags$div(class = "kpi-label", "Autoconsommation"))
        ),
        shiny::tags$div(style = sprintf("text-align:center;margin-top:8px;font-size:.7rem;color:%s;", cl$text_muted),
          shiny::actionButton(session$ns("apply_best"), "Appliquer cette configuration",
            icon = shiny::icon("check"),
            style = sprintf("background:%s;border:none;color:%s;font-family:'JetBrains Mono',monospace;font-size:.78rem;margin-top:4px;",
              cl$success, cl$text_light)))
      )
    })

    # ---- Apply best config ----
    shiny::observeEvent(input$apply_best, {
      shiny::req(automagic_results())
      best <- automagic_results() %>% dplyr::slice(1)
      if (!is.null(parent_session)) {
        shiny::updateCheckboxInput(parent_session, "pv_auto", value = FALSE)
        shiny::updateSliderInput(parent_session, "pv_kwc_manual", value = best$PV_kWc)
        shiny::updateCheckboxInput(parent_session, "batterie_active", value = best$Batterie_kWh > 0)
        shiny::updateNumericInput(parent_session, "batt_kwh", value = best$Batterie_kWh)
        if (best$Mode == "optimizer") {
          shiny::updateRadioButtons(parent_session, "approche", selected = "optimiseur")
        } else if (best$Mode == "optimizer_lp") {
          shiny::updateRadioButtons(parent_session, "approche", selected = "optimiseur_lp")
        } else if (best$Mode == "optimizer_qp") {
          shiny::updateRadioButtons(parent_session, "approche", selected = "optimiseur_qp")
        } else {
          shiny::updateRadioButtons(parent_session, "approche", selected = "rulebased")
        }
        shiny::updateRadioButtons(parent_session, "type_contrat", selected = best$Contrat)
      }
      shiny::showNotification("Configuration appliquee! Lancez la simulation pour voir les details.", type = "message")
    })

    # ---- Automagic heatmap ----
    output$plot_automagic_heatmap <- plotly::renderPlotly({
      shiny::req(automagic_results())
      res <- automagic_results()
      best_per_combo <- res %>%
        dplyr::group_by(PV_kWc, Batterie_kWh) %>%
        dplyr::slice_min(Cout_EUR, n = 1, with_ties = FALSE) %>%
        dplyr::ungroup()
      plotly::plot_ly(best_per_combo, x = ~factor(PV_kWc), y = ~factor(Batterie_kWh),
        z = ~Cout_EUR, type = "heatmap",
        text = ~paste0(Cout_EUR, " EUR\n", Mode, " / ", Contrat, "\nAC: ", Autoconso_pct, "%"),
        hoverinfo = "text",
        colorscale = list(c(0, cl$success), c(0.5, cl$pv), c(1, cl$danger)),
        colorbar = list(title = list(text = "EUR/an", font = list(color = cl$text_muted, size = 10)),
          tickfont = list(color = cl$text_muted, size = 9))) %>%
        pl_layout(xlab = "PV installe (kWc)", ylab = "Batterie (kWh)")
    })

    # ---- Automagic table ----
    output$table_automagic <- DT::renderDT({
      shiny::req(automagic_results())
      res <- automagic_results() %>%
        dplyr::rename(`PV (kWc)` = PV_kWc, `Batt (kWh)` = Batterie_kWh,
               `Facture (EUR)` = Cout_EUR, `AC (%)` = Autoconso_pct,
               `Inj (kWh)` = Injection_kWh, `Offt (kWh)` = Soutirage_kWh) %>%
        utils::head(30)
      DT::datatable(res, rownames = FALSE,
        options = list(dom = "tip", pageLength = 10, order = list(list(4, "asc"))),
        class = "compact",
        caption = "Top 30 configurations (triees par facture croissante)") %>%
        DT::formatStyle("Facture (EUR)", fontWeight = "bold",
          color = DT::styleInterval(
            stats::quantile(res$`Facture (EUR)`, c(0.33, 0.66), na.rm = TRUE),
            c(cl$success, cl$pv, cl$danger)))
    })

    # ---- Dimensionnement PV ----
    output$plot_dim_pv <- plotly::renderPlotly({
      shiny::req(sim_result(), date_range()); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
      d1 <- as.POSIXct(date_range()[1], tz = "Europe/Brussels")
      d2 <- as.POSIXct(date_range()[2], tz = "Europe/Brussels") + lubridate::days(1)
      df_base <- res$df %>% dplyr::filter(timestamp >= d1, timestamp < d2)

      kwc_ref <- p$pv_kwc
      kwc_range <- seq(max(1, kwc_ref - 2), kwc_ref + 2, by = 1)

      scenarii <- dplyr::bind_rows(lapply(kwc_range, function(kwc) {
        p_sc <- p; p_sc$pv_kwc <- kwc; p_sc$pv_kwc_ref <- p$pv_kwc
        df_sc <- df_base %>% dplyr::mutate(pv_kwh = pv_kwh * kwc / kwc_ref)
        res <- run_scenario(df_sc, p_sc, mode = "smart")
        tibble::tibble(
          kWc = kwc,
          `Injection (kWh)` = res$Injection_kWh,
          `Soutirage (kWh)` = res$Soutirage_kWh,
          `Autoconso (%)` = res$Autoconso_pct,
          `Facture nette (EUR)` = res$Cout_EUR
        )
      }))

      is_current <- scenarii$kWc == kwc_ref
      bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)

      plotly::plot_ly() %>%
        plotly::add_bars(data = scenarii, x = ~factor(kWc), y = ~`Facture nette (EUR)`, name = "Facture nette",
          marker = list(color = bar_colors, line = list(width = 0)),
          text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
          textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
        plotly::add_trace(data = scenarii, x = ~factor(kWc), y = ~`Autoconso (%)`, name = "Autoconso %",
          type = "scatter", mode = "lines+markers", yaxis = "y2",
          line = list(color = cl$success, width = 2),
          marker = list(color = cl$success, size = 8)) %>%
        plotly::layout(
          yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
            gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
            titlefont = list(color = cl$success)),
          barmode = "group"
        ) %>%
        pl_layout(xlab = "kWc installe", ylab = "Facture nette (EUR/an)")
    })

    # ---- Dimensionnement batterie ----
    output$plot_dim_batt <- plotly::renderPlotly({
      shiny::req(sim_result(), date_range()); res <- sim_result(); p <- if (!is.null(res$params)) res$params else params_r()
      if (!p$batterie_active) return(plotly::plot_ly() %>% pl_layout())
      d1 <- as.POSIXct(date_range()[1], tz = "Europe/Brussels")
      d2 <- as.POSIXct(date_range()[2], tz = "Europe/Brussels") + lubridate::days(1)
      df_base <- res$df %>% dplyr::filter(timestamp >= d1, timestamp < d2)

      cap_range <- c(0, 5, 10, 15, 20)

      scenarii <- dplyr::bind_rows(lapply(cap_range, function(cap) {
        p_sc <- p
        p_sc$batterie_active <- cap > 0
        p_sc$batt_kwh <- cap
        res <- run_scenario(df_base, p_sc, mode = "smart")
        tibble::tibble(
          `Batterie (kWh)` = cap,
          `Injection (kWh)` = res$Injection_kWh,
          `Soutirage (kWh)` = res$Soutirage_kWh,
          `Autoconso (%)` = res$Autoconso_pct,
          `Facture nette (EUR)` = res$Cout_EUR
        )
      }))

      is_current <- scenarii$`Batterie (kWh)` == p$batt_kwh
      bar_colors <- ifelse(is_current, cl$accent, cl$text_muted)

      plotly::plot_ly() %>%
        plotly::add_bars(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Facture nette (EUR)`, name = "Facture nette",
          marker = list(color = bar_colors, line = list(width = 0)),
          text = ~paste0(`Facture nette (EUR)`, " EUR"), textposition = "outside",
          textfont = list(color = cl$text, size = 10, family = "JetBrains Mono")) %>%
        plotly::add_trace(data = scenarii, x = ~factor(`Batterie (kWh)`), y = ~`Autoconso (%)`, name = "Autoconso %",
          type = "scatter", mode = "lines+markers", yaxis = "y2",
          line = list(color = cl$success, width = 2),
          marker = list(color = cl$success, size = 8)) %>%
        plotly::layout(
          yaxis2 = list(title = "Autoconso (%)", overlaying = "y", side = "right",
            gridcolor = "rgba(0,0,0,0)", tickfont = list(color = cl$success, size = 10),
            titlefont = list(color = cl$success)),
          barmode = "group"
        ) %>%
        pl_layout(xlab = "Capacite batterie (kWh)", ylab = "Facture nette (EUR/an)")
    })
  })
}
