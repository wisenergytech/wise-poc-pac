#' Contraintes Tab Module UI
#'
#' Contains constraint scorecard and conditional verification plots.
#'
#' @param id module id
#' @noRd
mod_contraintes_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 12,
      bslib::card(bslib::card_body(shiny::uiOutput(ns("cv_scorecard"))))),
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE,
        bslib::card_header(
          bslib::layout_columns(col_widths = c(6, 6),
            shiny::selectInput(ns("cv_check"), NULL, choices = list(
              "Contraintes" = c(
                "Marge temperature vs bornes" = "marge_temp",
                "SOC batterie vs bornes" = "soc_bornes",
                "Charge/decharge simultanees" = "simult"),
              "Conservation (smoke tests)" = c(
                "Bilan electrique (residu)" = "bilan_elec",
                "Bilan thermique (residu)" = "bilan_therm",
                "Conservation energie totale" = "conserv_totale"),
              "Qualite optimisation" = c(
                "Prix effectif kWh thermique" = "prix_kwh_th",
                "Cout marginal baseline vs opti" = "cout_marginal"),
              "Validite physique" = c(
                "Puissance PAC vs capacite" = "puissance_pac",
                "Taux de variation T (dT/dt)" = "dt_dt",
                "COP realise vs theorique" = "cop_realise",
                "Autoconsommation PV" = "autoconso_pv")
            ), selected = "bilan_elec"),
            shiny::tags$div())),
        bslib::card_body(plotly::plotlyOutput(ns("plot_cv_main"), height = "400px"))))
  )
}

#' Contraintes Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_contraintes_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_filtered <- sidebar$sim_filtered
    params_r     <- sidebar$params_r

    # ---- Scorecard ----
    output$cv_scorecard <- shiny::renderUI({
      shiny::req(sim_filtered()); sim <- sim_filtered(); p <- params_r()
      pac_qt <- p$p_pac_kw * p$dt_h
      n_tot <- sum(!is.na(sim$sim_t_ballon))

      n_low  <- sum(sim$sim_t_ballon < p$t_min, na.rm = TRUE)
      n_high <- sum(sim$sim_t_ballon > p$t_max, na.rm = TRUE)
      pct_t <- round((1 - (n_low + n_high) / n_tot) * 100, 1)
      col_t <- if (pct_t >= 99) cl$success else if (pct_t >= 95) "#f59e0b" else cl$danger

      res_e <- sim$pv_kwh + sim$sim_offtake - sim$conso_hors_pac - sim$sim_pac_on * pac_qt - sim$sim_intake
      if (p$batterie_active && !is.null(sim$batt_flux)) {
        batt_eff <- sqrt(p$batt_rendement)
        res_e <- res_e + pmax(0, -sim$batt_flux) * batt_eff - pmax(0, sim$batt_flux)
      }
      max_e <- round(max(abs(res_e), na.rm = TRUE), 4)
      col_e <- if (max_e < 0.001) cl$success else if (max_e < 0.01) "#f59e0b" else cl$danger

      cap <- p$capacite_kwh_par_degre; k_perte <- 0.004 * p$dt_h; t_amb <- 20
      chaleur <- sim$sim_pac_on * pac_qt * sim$sim_cop
      t_pred <- (dplyr::lag(sim$sim_t_ballon) * (cap - k_perte) + chaleur + k_perte * t_amb - sim$soutirage_estime_kwh) / cap
      res_th <- sim$sim_t_ballon - t_pred
      max_th <- round(max(abs(res_th), na.rm = TRUE), 3)
      col_th <- if (max_th < 0.01) cl$success else if (max_th < 0.5) "#f59e0b" else cl$danger

      batt_html <- ""
      if (p$batterie_active && !is.null(sim$batt_soc)) {
        n_soc_v <- sum(sim$batt_soc < p$batt_soc_min - 0.001 | sim$batt_soc > p$batt_soc_max + 0.001, na.rm = TRUE)
        n_simult <- sum(pmax(0, sim$batt_flux) > 0.001 & pmax(0, -sim$batt_flux) > 0.001, na.rm = TRUE)
        col_b <- if (n_soc_v + n_simult == 0) cl$success else cl$danger
        batt_html <- sprintf(" &middot; Batt : <b style='color:%s'>%d viol.</b>", col_b, n_soc_v + n_simult)
      }

      shiny::tags$div(style = sprintf("font-family:'JetBrains Mono',monospace;font-size:.78rem;color:%s;", cl$text_muted),
        shiny::HTML(sprintf(
          "T confort : <b style='color:%s'>%s%%</b> (%d+%d qt) &middot; Bilan elec : <b style='color:%s'>%s</b> &middot; Bilan therm : <b style='color:%s'>%s C</b>%s",
          col_t, pct_t, n_low, n_high, col_e, max_e, col_th, max_th, batt_html)))
    })

    # ---- Graphique unique conditionnel ----
    output$plot_cv_main <- plotly::renderPlotly({
      shiny::req(sim_filtered(), input$cv_check)
      sim <- sim_filtered(); p <- params_r()
      pac_qt <- p$p_pac_kw * p$dt_h
      check <- input$cv_check

      if (check == "marge_temp") {
        d <- sim %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>%
          dplyr::summarise(t_bal = mean(sim_t_ballon, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h) %>%
          dplyr::mutate(marge_min = t_bal - p$t_min, marge_max = p$t_max - t_bal)
        plotly::plot_ly(d, x = ~timestamp) %>%
          plotly::add_trace(y = ~marge_min, type = "scatter", mode = "lines", name = "Marge T_min",
            line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(29,67,69,0.06)") %>%
          plotly::add_trace(y = ~marge_max, type = "scatter", mode = "lines", name = "Marge T_max",
            line = list(color = "#f59e0b", width = 1), fill = "tozeroy", fillcolor = "rgba(245,158,11,0.06)") %>%
          plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp), y = 0, yend = 0,
            line = list(color = cl$danger, dash = "dash", width = 1), name = "Seuil violation") %>%
          pl_layout(ylab = "Marge (C)")

      } else if (check == "soc_bornes") {
        if (!p$batterie_active || is.null(sim$batt_soc)) return(plotly::plot_ly() %>% pl_layout(title = "Batterie non active"))
        d <- sim %>% dplyr::mutate(soc_pct = batt_soc * 100)
        plotly::plot_ly(d, x = ~timestamp) %>%
          plotly::add_trace(y = ~soc_pct, type = "scatter", mode = "lines", name = "SoC",
            line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(29,67,69,0.08)") %>%
          plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
            y = p$batt_soc_min * 100, yend = p$batt_soc_min * 100,
            line = list(color = cl$danger, dash = "dash", width = 1), name = "SoC min") %>%
          plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
            y = p$batt_soc_max * 100, yend = p$batt_soc_max * 100,
            line = list(color = "#f59e0b", dash = "dash", width = 1), name = "SoC max") %>%
          pl_layout(ylab = "SoC (%)")

      } else if (check == "simult") {
        if (!p$batterie_active || is.null(sim$batt_flux)) return(plotly::plot_ly() %>% pl_layout(title = "Batterie non active"))
        d <- sim %>% dplyr::mutate(charge = pmax(0, batt_flux), decharge = pmax(0, -batt_flux),
          simult = pmin(charge, decharge))
        plotly::plot_ly(d, x = ~timestamp) %>%
          plotly::add_trace(y = ~charge, type = "scatter", mode = "lines", name = "Charge", line = list(color = cl$success, width = 1)) %>%
          plotly::add_trace(y = ~decharge, type = "scatter", mode = "lines", name = "Decharge", line = list(color = cl$reel, width = 1)) %>%
          plotly::add_bars(y = ~simult, name = "Simultanee", marker = list(color = cl$danger)) %>%
          pl_layout(ylab = "kWh/qt")

      } else if (check == "bilan_elec") {
        d <- sim %>% dplyr::mutate(
          entrees = pv_kwh + sim_offtake,
          sorties = conso_hors_pac + sim_pac_on * pac_qt + sim_intake,
          residu  = entrees - sorties)
        if (p$batterie_active && !is.null(sim$batt_flux)) {
          batt_eff <- sqrt(p$batt_rendement)
          d <- d %>% dplyr::mutate(entrees = entrees + pmax(0, -batt_flux) * batt_eff,
            sorties = sorties + pmax(0, batt_flux), residu = entrees - sorties)
        }
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::summarise(residu = sum(residu, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_bars(y = ~residu, name = "Residu",
            marker = list(color = ifelse(abs(d_h$residu) > 0.01, cl$danger, cl$success))) %>%
          pl_layout(ylab = "Residu electrique (kWh)")

      } else if (check == "bilan_therm") {
        cap <- p$capacite_kwh_par_degre; k_perte <- 0.004 * p$dt_h; t_amb <- 20
        d <- sim %>% dplyr::mutate(
          chaleur_pac = sim_pac_on * pac_qt * sim_cop,
          t_predit = (dplyr::lag(sim_t_ballon) * (cap - k_perte) + chaleur_pac + k_perte * t_amb - soutirage_estime_kwh) / cap,
          ecart = sim_t_ballon - t_predit) %>% dplyr::filter(!is.na(ecart))
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::summarise(ecart = mean(ecart, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_bars(y = ~ecart, name = "Ecart T",
            marker = list(color = ifelse(abs(d_h$ecart) > 0.5, cl$danger, cl$success))) %>%
          pl_layout(ylab = "Ecart T simule - T predit (C)")

      } else if (check == "conserv_totale") {
        cap <- p$capacite_kwh_par_degre
        d <- sim %>% dplyr::mutate(
          entrant_cum = cumsum(pv_kwh + sim_offtake),
          sortant_cum = cumsum(sim_intake + conso_hors_pac),
          pac_cum = cumsum(sim_pac_on * pac_qt),
          delta_stock = (sim_t_ballon - sim_t_ballon[1]) * cap,
          residu_cum = entrant_cum - sortant_cum - pac_cum)
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::slice_tail(n = 1) %>% dplyr::ungroup() %>% dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_trace(y = ~entrant_cum, type = "scatter", mode = "lines", name = "Entrant cumule", line = list(color = cl$success, width = 1.5)) %>%
          plotly::add_trace(y = ~sortant_cum + pac_cum, type = "scatter", mode = "lines", name = "Sortant + PAC cumule", line = list(color = cl$reel, width = 1.5)) %>%
          pl_layout(ylab = "Energie cumulee (kWh)")

      } else if (check == "prix_kwh_th") {
        d <- sim %>% dplyr::mutate(
          cout_qt = sim_offtake * prix_offtake - sim_intake * prix_injection,
          chaleur_th = sim_pac_on * pac_qt * sim_cop,
          prix_th = ifelse(chaleur_th > 0.01, cout_qt / chaleur_th, NA_real_)) %>%
          dplyr::filter(!is.na(prix_th), prix_th > -1, prix_th < 2)
        plotly::plot_ly(d, x = ~timestamp) %>%
          plotly::add_trace(y = ~prix_th, type = "scatter", mode = "markers", name = "Prix kWh_th",
            marker = list(color = cl$opti, size = 3, opacity = 0.5)) %>%
          plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
            y = mean(d$prix_th, na.rm = TRUE), yend = mean(d$prix_th, na.rm = TRUE),
            line = list(color = cl$pv, dash = "dash", width = 1), name = sprintf("Moy: %.3f", mean(d$prix_th, na.rm = TRUE))) %>%
          pl_layout(ylab = "EUR/kWh_th")

      } else if (check == "cout_marginal") {
        d <- sim %>% dplyr::mutate(
          cout_base_qt = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
          cout_opti_qt = sim_offtake * prix_offtake - sim_intake * prix_injection,
          eco_qt = cout_base_qt - cout_opti_qt)
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::summarise(eco = sum(eco_qt, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_bars(y = ~eco, name = "Economie/h",
            marker = list(color = ifelse(d_h$eco >= 0, cl$success, cl$danger))) %>%
          pl_layout(ylab = "Economie par heure (EUR)")

      } else if (check == "puissance_pac") {
        d <- sim %>% dplyr::mutate(puissance_kw = sim_pac_on * p$p_pac_kw)
        plotly::plot_ly(d, x = ~timestamp) %>%
          plotly::add_trace(y = ~puissance_kw, type = "scatter", mode = "lines", name = "Puissance PAC",
            line = list(color = cl$pac, width = 1), fill = "tozeroy", fillcolor = "rgba(5,150,105,0.08)") %>%
          plotly::add_segments(x = min(d$timestamp), xend = max(d$timestamp),
            y = p$p_pac_kw, yend = p$p_pac_kw,
            line = list(color = cl$danger, dash = "dash", width = 1), name = sprintf("P_max = %s kW", p$p_pac_kw)) %>%
          pl_layout(ylab = "Puissance (kW)")

      } else if (check == "dt_dt") {
        d <- sim %>% dplyr::mutate(
          dt_dt = (sim_t_ballon - dplyr::lag(sim_t_ballon)) / p$dt_h) %>% dplyr::filter(!is.na(dt_dt))
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::summarise(dt_dt = mean(dt_dt, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_bars(y = ~dt_dt, name = "dT/dt",
            marker = list(color = ifelse(abs(d_h$dt_dt) > 20, cl$danger, cl$opti))) %>%
          pl_layout(ylab = "Taux de variation T (C/h)")

      } else if (check == "cop_realise") {
        d <- sim %>% dplyr::mutate(
          cop_theorique = calc_cop(t_ext, p$cop_nominal, p$t_ref_cop, t_ballon = sim_t_ballon),
          ecart_cop = sim_cop - cop_theorique) %>%
          dplyr::filter(sim_pac_on > 0)
        if (nrow(d) == 0) return(plotly::plot_ly() %>% pl_layout(title = "Aucun qt PAC ON"))
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>% dplyr::summarise(cop_sim = mean(sim_cop, na.rm = TRUE),
            cop_th = mean(cop_theorique, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_trace(y = ~cop_sim, type = "scatter", mode = "lines", name = "COP simule",
            line = list(color = cl$opti, width = 1.5)) %>%
          plotly::add_trace(y = ~cop_th, type = "scatter", mode = "lines", name = "COP theorique",
            line = list(color = cl$reel, width = 1, dash = "dot")) %>%
          pl_layout(ylab = "COP")

      } else if (check == "autoconso_pv") {
        d <- sim %>% dplyr::mutate(
          conso_tot_base = conso_hors_pac + ifelse(offtake_kwh > pac_qt * 0.5, pac_qt, 0),
          conso_tot_opti = conso_hors_pac + sim_pac_on * pac_qt,
          ac_base = pmin(pv_kwh, conso_tot_base),
          ac_opti = pmin(pv_kwh, conso_tot_opti))
        d_h <- d %>% dplyr::mutate(h = lubridate::floor_date(timestamp, "hour")) %>%
          dplyr::group_by(h) %>%
          dplyr::summarise(ac_base = sum(ac_base, na.rm = TRUE), ac_opti = sum(ac_opti, na.rm = TRUE),
            pv = sum(pv_kwh, na.rm = TRUE), .groups = "drop") %>%
          dplyr::rename(timestamp = h)
        plotly::plot_ly(d_h, x = ~timestamp) %>%
          plotly::add_trace(y = ~ac_base, type = "scatter", mode = "lines", name = "Autoconso baseline",
            line = list(color = cl$reel, width = 1), fill = "tozeroy", fillcolor = "rgba(217,119,6,0.06)") %>%
          plotly::add_trace(y = ~ac_opti, type = "scatter", mode = "lines", name = "Autoconso optimise",
            line = list(color = cl$opti, width = 1.5), fill = "tozeroy", fillcolor = "rgba(29,67,69,0.06)") %>%
          plotly::add_trace(y = ~pv, type = "scatter", mode = "lines", name = "PV total",
            line = list(color = cl$pv, width = 1, dash = "dot")) %>%
          pl_layout(ylab = "kWh/h")

      } else {
        plotly::plot_ly() %>% pl_layout(title = "Selectionnez une verification")
      }
    })
  })
}
