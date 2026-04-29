#' Render presentation with simulation KPIs
#'
#' Maps KPICalculator output + simulation params to Quarto presentation params
#' and renders the parameterized .qmd to HTML or PPTX.
#'
#' @param kpis Named list from KPICalculator$compute()
#' @param params Named list from params_r() reactive
#' @param sim_data Data frame from sim_filtered() (for date range)
#' @param output_file Path for rendered output
#' @param format "revealjs" (HTML) or "pptx"
#' @return Path to the rendered file (invisibly)
render_presentation <- function(kpis, params, sim_data, output_file,
                                format = c("revealjs", "pptx")) {
  format <- match.arg(format)

  # Date range from simulation data
  ts <- sim_data$timestamp
  date_debut <- format(min(ts, na.rm = TRUE), "%d/%m/%Y")
  date_fin <- format(max(ts, na.rm = TRUE), "%d/%m/%Y")

  # PAC share of total consumption
  total_conso <- sum(sim_data$offtake_kwh, na.rm = TRUE)
  pac_conso <- kpis$conso_pac_baseline
  pct_pac <- if (total_conso > 0) round(pac_conso / total_conso * 100) else 55

  # Annual projections (seasonal extrapolation)
  proj <- project_annual_kpis(kpis, sim_data)

  # Pre-compute helpers (needed for BELIX analysis and chart data)
  kpi_calc <- KPICalculator$new()
  p_list <- if (inherits(params, "SimulationParams")) params$as_list() else params

  # BELIX pilotage analysis
  belix <- kpi_calc$get_belix_pilotage(sim_data, p_list)

  # Build params list for Quarto
  qparams <- list(
    # Site (static defaults — could be made configurable)
    site_name = "Profondeville",
    n_logements = 20,
    n_immeubles = 4,
    surface_m2 = 2000,
    conso_chauffage_mwh_an = 198,
    co2_evite_20ans_t = 717,
    # Technical (from simulation params)
    pac_kw = params$p_pac_th_kw %||% 60,
    pv_kwc = params$pv_kwc %||% 64,
    volume_ballon_l = params$volume_ballon_l %||% 32000,
    t_min = params$t_min %||% 45,
    t_max = params$t_max %||% 55,
    cop_median_hiver = 2.5,
    cop_median_misaison = 4.5,
    # Simulation period
    date_debut = date_debut,
    date_fin = date_fin,
    n_days = round(kpis$n_days),
    mode_optim = "LP",
    type_contrat = params$type_contrat %||% "spot",
    # Financial KPIs
    cout_soutirage_baseline = round(kpis$cout_soutirage_baseline),
    cout_soutirage_opti = round(kpis$cout_soutirage_opti),
    rev_injection_baseline = round(kpis$rev_injection_baseline),
    rev_injection_opti = round(kpis$rev_injection_opti),
    facture_baseline = round(kpis$facture_baseline),
    facture_opti = round(kpis$facture_opti),
    gain_eur = round(kpis$gain_eur),
    gain_pct = round(abs(kpis$gain_pct)),
    gain_eur_per_day = round(kpis$gain_eur_per_day, 2),
    # Energy KPIs
    soutirage_baseline_kwh = round(kpis$soutirage_baseline),
    soutirage_opti_kwh = round(kpis$soutirage_opti),
    injection_baseline_kwh = round(kpis$injection_baseline),
    injection_opti_kwh = round(kpis$injection_opti),
    ac_baseline = kpis$ac_baseline,
    ac_opti = kpis$ac_opti,
    as_baseline = kpis$as_baseline,
    as_opti = kpis$as_opti,
    conso_pac_baseline_kwh = round(kpis$conso_pac_baseline),
    conso_pac_opti_kwh = round(kpis$conso_pac_opti),
    pct_pac_conso = pct_pac,
    # CO2 KPIs
    co2_baseline_kg = round(kpis$co2_baseline_kg %||% 0),
    co2_saved_kg = round(kpis$co2_saved_kg %||% 0),
    co2_pct_reduction = round(kpis$co2_pct_reduction %||% 0),
    co2_equiv_car_km = round(kpis$co2_equiv_car_km %||% 0),
    co2_equiv_trees_year = round(kpis$co2_equiv_trees_year %||% 0),
    # Annual projections
    proj_heat_coverage_pct = proj$heat_coverage_pct,
    proj_facture_baseline_an = proj$facture_baseline_an,
    proj_facture_opti_an = proj$facture_opti_an,
    proj_gain_eur_an = proj$gain_eur_an,
    proj_gain_pct_an = proj$gain_pct_an,
    proj_pv_total_an = proj$pv_total_an,
    proj_ac_opti_an = proj$ac_opti_an,
    proj_co2_saved_an_kg = proj$co2_saved_an_kg,
    # BELIX pilotage KPIs
    belix_pct_temps_offpeak = belix$pct_temps_offpeak,
    belix_pct_pac_offpeak = belix$pct_pac_offpeak,
    belix_ecart_pp = belix$ecart_pp,
    belix_verdict = belix$verdict
  )

  # Locate the .qmd template
  qmd_path <- system.file("presentations", "presentation.qmd", package = "wisepocpac")
  if (qmd_path == "") {
    qmd_path <- file.path("inst", "presentations", "presentation.qmd")
  }

  # --- PAC par tranche horaire ---
  tranche_baseline <- kpi_calc$get_pac_par_tranche(sim_data, p_list, "baseline")
  tranche_opti <- kpi_calc$get_pac_par_tranche(sim_data, p_list, "optimized")
  tranche_baseline$scenario <- "Baseline"
  tranche_opti$scenario <- "Optimise"
  tranche_data <- rbind(tranche_baseline, tranche_opti)

  # --- Profil horaire moyen (puissance PAC + prix) ---
  get_pac_kwh_vec <- function(sim, params, type) {
    if (type == "optimized") {
      sim$sim_pac_on * params$p_pac_kw * params$dt_h
    } else if ("pac_kwh" %in% names(sim)) {
      sim$pac_kwh
    } else {
      pmax(0, sim$offtake_kwh + sim$pv_kwh - sim$intake_kwh - sim$conso_hors_pac)
    }
  }
  compute_profile <- function(sim, params, type) {
    pac_kwh <- get_pac_kwh_vec(sim, params, type)
    h <- as.integer(format(sim$timestamp, "%H", tz = "Europe/Brussels"))
    dplyr::tibble(hour = h, pac_kwh = pac_kwh) %>%
      dplyr::group_by(hour) %>%
      dplyr::summarise(
        pac_moy_kw = mean(pac_kwh, na.rm = TRUE) / params$dt_h,
        .groups = "drop"
      )
  }
  profil_bl <- compute_profile(sim_data, p_list, "baseline")
  profil_bl$scenario <- "Baseline"
  profil_op <- compute_profile(sim_data, p_list, "optimized")
  profil_op$scenario <- "Optimise"
  profil_data <- rbind(profil_bl, profil_op)

  h_vec <- as.integer(format(sim_data$timestamp, "%H", tz = "Europe/Brussels"))
  profil_prix <- dplyr::tibble(hour = h_vec, prix = sim_data$prix_offtake) %>%
    dplyr::group_by(hour) %>%
    dplyr::summarise(prix_moy = mean(prix, na.rm = TRUE), .groups = "drop")

  # Copy template + assets to a temp dir for rendering
  tmp_dir <- tempfile("presentation_")
  dir.create(tmp_dir)
  src_dir <- dirname(qmd_path)
  file.copy(list.files(src_dir, full.names = TRUE), tmp_dir, recursive = TRUE)

  # Save pre-computed chart data for the .qmd
  saveRDS(tranche_data, file.path(tmp_dir, "tranche_data.rds"))
  saveRDS(list(profil = profil_data, prix = profil_prix),
          file.path(tmp_dir, "profil_data.rds"))

  tmp_qmd <- file.path(tmp_dir, "presentation.qmd")

  # Render
  quarto::quarto_render(
    input = tmp_qmd,
    output_format = format,
    execute_params = qparams
  )

  # Find rendered output
  ext <- if (format == "revealjs") "html" else "pptx"
  rendered <- file.path(tmp_dir, paste0("presentation.", ext))

  file.copy(rendered, output_file, overwrite = TRUE)
  unlink(tmp_dir, recursive = TRUE)

  invisible(output_file)
}
