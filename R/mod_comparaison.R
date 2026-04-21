#' Comparaison Tab Module UI
#'
#' Contains multi-variable comparison chart with dual Y axes.
#'
#' @param id module id
#' @noRd
mod_comparaison_ui <- function(id) {

  ns <- shiny::NS(id)
  shiny::tagList(
    bslib::layout_columns(col_widths = 12,
      bslib::card(full_screen = TRUE, bslib::card_header("Comparer 2 ou 3 series temporelles"),
        bslib::card_body(
          bslib::layout_columns(col_widths = c(3, 3, 3, 3),
            shiny::selectInput(ns("compare_var1"), "Serie 1 (axe gauche)",
              choices = NULL, selected = NULL),
            shiny::selectInput(ns("compare_var2"), "Serie 2 (axe droit)",
              choices = NULL, selected = NULL),
            shiny::selectInput(ns("compare_var3"), "Serie 3 (optionnelle)",
              choices = NULL, selected = NULL),
            shiny::dateRangeInput(ns("compare_range"), "Zoom periode",
              start = Sys.Date() - 7, end = Sys.Date(), language = "fr")),
          plotly::plotlyOutput(ns("plot_compare"), height = "480px"))))
  )
}

#' Comparaison Tab Module Server
#'
#' @param id module id
#' @param sidebar reactives list returned by mod_sidebar_server
#' @noRd
mod_comparaison_server <- function(id, sidebar) {
  shiny::moduleServer(id, function(input, output, session) {

    sim_result   <- sidebar$sim_result
    sim_filtered <- sidebar$sim_filtered
    date_range   <- sidebar$date_range

    compare_vars <- c(
      "Production PV (kWh)" = "pv_kwh",
      "Soutirage baseline (kWh)" = "offtake_kwh",
      "Soutirage optimise (kWh)" = "sim_offtake",
      "Injection baseline (kWh)" = "intake_kwh",
      "Injection optimisee (kWh)" = "sim_intake",
      "Autoconsommation baseline (kWh)" = "autoconso_baseline",
      "Autoconsommation optimisee (kWh)" = "autoconso_opti",
      "Facture baseline (EUR)" = "facture_baseline",
      "Facture optimisee (EUR)" = "facture_opti",
      "Conso hors PAC (kWh)" = "conso_hors_pac",
      "Soutirage ECS (kWh)" = "soutirage_estime_kwh",
      "Temperature ballon baseline (C)" = "t_ballon",
      "Temperature ballon optimisee (C)" = "sim_t_ballon",
      "Temperature exterieure (C)" = "t_ext",
      "COP" = "sim_cop",
      "PAC on (optimise)" = "sim_pac_on",
      "Prix soutirage (EUR/kWh)" = "prix_offtake",
      "Prix injection (EUR/kWh)" = "prix_injection",
      "Prix spot (EUR/kWh)" = "prix_eur_kwh"
    )

    compare_derived <- c("autoconso_baseline", "autoconso_opti", "facture_baseline", "facture_opti")

    shiny::observeEvent(sim_result(), {
      sim <- sim_result()$sim
      avail_native <- compare_vars[compare_vars %in% names(sim)]
      avail_derived <- compare_vars[compare_vars %in% compare_derived]
      avail <- c(avail_native, avail_derived)
      shiny::updateSelectInput(session, "compare_var1", choices = avail,
        selected = if ("pv_kwh" %in% avail) "pv_kwh" else avail[1])
      shiny::updateSelectInput(session, "compare_var2", choices = avail,
        selected = if ("prix_eur_kwh" %in% avail) "prix_eur_kwh" else avail[min(2, length(avail))])
      avail3 <- c("Aucune" = "", avail)
      shiny::updateSelectInput(session, "compare_var3", choices = avail3, selected = "")
    })

    get_unit <- function(var) {
      if (is.null(var) || var == "") return(NA_character_)
      label <- names(compare_vars)[compare_vars == var]
      if (length(label) == 0) return(NA_character_)
      m <- regmatches(label, regexpr("\\(([^)]+)\\)", label))
      if (length(m) == 0) return(NA_character_)
      gsub("[()]", "", m)
    }

    shiny::observeEvent(date_range(), {
      shiny::req(date_range())
      shiny::updateDateRangeInput(session, "compare_range",
        start = date_range()[1], end = date_range()[2],
        min = date_range()[1], max = date_range()[2])
    })

    compare_data <- shiny::reactive({
      shiny::req(sim_result(), input$compare_range)
      sim <- sim_result()$sim
      d1 <- as.POSIXct(input$compare_range[1], tz = "Europe/Brussels")
      d2 <- as.POSIXct(input$compare_range[2], tz = "Europe/Brussels") + lubridate::days(1)
      sim %>%
        dplyr::filter(timestamp >= d1, timestamp < d2) %>%
        dplyr::mutate(
          autoconso_baseline = pmax(0, pv_kwh - intake_kwh),
          autoconso_opti = pmax(0, pv_kwh - sim_intake),
          facture_baseline = offtake_kwh * prix_offtake - intake_kwh * prix_injection,
          facture_opti = sim_offtake * prix_offtake - sim_intake * prix_injection
        )
    })

    output$plot_compare <- plotly::renderPlotly({
      shiny::req(compare_data(), input$compare_var1, input$compare_var2)
      df <- compare_data()
      v1 <- input$compare_var1; v2 <- input$compare_var2
      v3 <- input$compare_var3
      if (is.null(v3) || v3 == "") v3 <- NA_character_
      vars <- c(v1, v2, if (!is.na(v3)) v3 else NULL)
      if (!all(vars %in% names(df))) return(plotly::plot_ly())

      summable <- c("pv_kwh", "offtake_kwh", "sim_offtake", "intake_kwh", "sim_intake",
        "conso_hors_pac", "soutirage_estime_kwh", "sim_pac_on",
        "autoconso_baseline", "autoconso_opti",
        "facture_baseline", "facture_opti")

      nr <- nrow(df)
      level <- if (nr <= 14 * 96) "qt" else if (nr <= 60 * 96) "hour" else if (nr <= 180 * 96) "day" else "week"
      label <- c(qt = "15 min", hour = "Horaire", day = "Journalier", week = "Hebdomadaire")[level]

      df_work <- df %>% dplyr::mutate(.w = dplyr::case_when(
        level == "qt" ~ timestamp,
        level == "hour" ~ lubridate::floor_date(timestamp, "hour"),
        level == "day" ~ lubridate::floor_date(timestamp, "day"),
        level == "week" ~ lubridate::floor_date(timestamp, "week")
      ))
      agg_exprs <- lapply(vars, function(v) {
        if (v %in% summable) rlang::expr(sum(.data[[!!v]], na.rm = TRUE))
        else rlang::expr(mean(.data[[!!v]], na.rm = TRUE))
      })
      names(agg_exprs) <- vars
      df_agg <- df_work %>% dplyr::group_by(.w) %>%
        dplyr::summarise(!!!agg_exprs, .groups = "drop") %>%
        dplyr::rename(timestamp = .w)

      label1 <- names(compare_vars)[compare_vars == v1]
      label2 <- names(compare_vars)[compare_vars == v2]
      unit1 <- get_unit(v1); unit2 <- get_unit(v2)

      add_smart_trace <- function(p, y_vals, var_name, label, color, yaxis, dash = NULL) {
        if (var_name %in% summable) {
          p %>% plotly::add_bars(y = y_vals, name = label,
            marker = list(color = color, opacity = 0.7), yaxis = yaxis)
        } else {
          p %>% plotly::add_trace(y = y_vals, type = "scatter", mode = "lines",
            name = label, line = list(color = color, width = 2, dash = dash), yaxis = yaxis)
        }
      }

      p <- plotly::plot_ly(df_agg, x = ~timestamp) %>%
        add_smart_trace(df_agg[[v1]], v1, label1, cl$opti, "y") %>%
        add_smart_trace(df_agg[[v2]], v2, label2, cl$accent3, "y2")

      if (!is.na(v3)) {
        label3 <- names(compare_vars)[compare_vars == v3]
        unit3 <- get_unit(v3)
        if (!is.na(unit3) && !is.na(unit1) && unit3 == unit1) {
          axe3 <- "y"; col3 <- cl$success
        } else if (!is.na(unit3) && !is.na(unit2) && unit3 == unit2) {
          axe3 <- "y2"; col3 <- cl$pv
        } else {
          axe3 <- "y"; col3 <- cl$success
          shiny::showNotification(sprintf("Serie 3 (unite %s) placee sur l'axe gauche par defaut", unit3),
            type = "warning", duration = 3)
        }
        p <- p %>% add_smart_trace(df_agg[[v3]], v3, label3, col3, axe3, dash = "dot")
      }

      p %>% plotly::layout(
        title = paste0("Agregation: ", label),
        yaxis = list(title = label1, tickfont = list(color = cl$opti),
          titlefont = list(color = cl$opti)),
        yaxis2 = list(title = label2, overlaying = "y", side = "right",
          tickfont = list(color = cl$accent3), titlefont = list(color = cl$accent3),
          gridcolor = "rgba(0,0,0,0)"),
        hovermode = "x unified",
        barmode = "group"
      ) %>%
        pl_layout()
    })
  })
}
