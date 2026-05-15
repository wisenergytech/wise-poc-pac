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
                                format = c("revealjs", "pptx"),
                                kpis_cible = NULL, params_cible = NULL) {
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

  # CO2 impact (compute early so qparams gets real values, not zeros)
  co2_kpis <- tryCatch({
    co2_result <- fetch_co2_intensity(
      min(sim_data$timestamp, na.rm = TRUE),
      max(sim_data$timestamp, na.rm = TRUE)
    )
    co2_15min <- interpolate_co2_15min(co2_result$df, sim_data$timestamp)
    impact <- compute_co2_impact(sim_data, co2_15min)
    co2_base_kg <- sum(impact$co2_baseline_g, na.rm = TRUE) / 1000
    list(
      co2_baseline_kg = co2_base_kg,
      co2_saved_kg = impact$co2_saved_kg,
      co2_pct_reduction = impact$co2_pct_reduction,
      co2_intensity_baseline = impact$intensity_before,
      co2_intensity_opti = impact$intensity_after,
      co2_equiv_car_km = impact$equiv_car_km,
      co2_equiv_trees_year = impact$equiv_trees_year
    )
  }, error = function(e) NULL)

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
    pv_kwc_ref = params$pv_kwc_ref %||% params$pv_kwc %||% 64,
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
    # CO2 KPIs (from pre-computed co2_kpis, falls back to 0 if unavailable)
    co2_baseline_kg = round(co2_kpis$co2_baseline_kg %||% 0),
    co2_saved_kg = round(co2_kpis$co2_saved_kg %||% 0),
    co2_pct_reduction = round(co2_kpis$co2_pct_reduction %||% 0),
    co2_intensity_baseline = round(co2_kpis$co2_intensity_baseline %||% 0),
    co2_intensity_opti = round(co2_kpis$co2_intensity_opti %||% 0),
    co2_equiv_car_km = round(co2_kpis$co2_equiv_car_km %||% 0),
    co2_equiv_trees_year = round(co2_kpis$co2_equiv_trees_year %||% 0),
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
    belix_verdict = belix$verdict,
    # Dual-contract decomposition (optional)
    has_dual_contrat = !is.null(kpis_cible),
    type_contrat_cible = if (!is.null(params_cible)) params_cible$type_contrat else "",
    dual_fa = round(kpis$facture_baseline),
    dual_fb = round(kpis$facture_opti),
    dual_fd = if (!is.null(kpis_cible)) round(kpis_cible$facture_opti) else 0,
    dual_levier1 = round(kpis$facture_baseline - kpis$facture_opti),
    dual_levier2 = if (!is.null(kpis_cible)) round(kpis$facture_opti - kpis_cible$facture_opti) else 0,
    dual_gain_total = if (!is.null(kpis_cible)) round(kpis$facture_baseline - kpis_cible$facture_opti) else 0,
    dual_gain_total_pct = if (!is.null(kpis_cible) && abs(kpis$facture_baseline) > 0.001) {
      round((kpis$facture_baseline - kpis_cible$facture_opti) / abs(kpis$facture_baseline) * 100)
    } else 0,
    # Dual-contract annual projections
    dual_proj_gain_total_an = if (!is.null(kpis_cible)) {
      round((kpis$facture_baseline - kpis_cible$facture_opti) * proj$facture_baseline_an / max(kpis$facture_baseline, 1))
    } else 0,
    dual_proj_fd_an = if (!is.null(kpis_cible)) {
      round(kpis_cible$facture_opti * proj$facture_baseline_an / max(kpis$facture_baseline, 1))
    } else 0
  )

  # Locate the .qmd template
  qmd_path <- system.file("presentations", "presentation.qmd", package = "wisepocpac")
  if (qmd_path == "") {
    qmd_path <- file.path("inst", "presentations", "presentation.qmd")
  }

  # --- PAC par tranche horaire (plotly object) ---
  tranche_baseline <- kpi_calc$get_pac_par_tranche(sim_data, p_list, "baseline")
  tranche_opti <- kpi_calc$get_pac_par_tranche(sim_data, p_list, "optimized")
  tranche_baseline$scenario <- "Baseline"
  tranche_opti$scenario <- "Optimise"
  tranche_data <- rbind(tranche_baseline, tranche_opti)
  p_tranches <- plot_pac_tranches(tranche_data)

  # --- Profil horaire moyen (plotly object) ---
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
  p_profil <- plot_profil_horaire(profil_data, profil_prix)

  # --- CO2 cumulative chart (reuse co2_kpis computation if available) ---
  p_co2_cumul <- tryCatch({
    co2_result <- fetch_co2_intensity(
      min(sim_data$timestamp, na.rm = TRUE),
      max(sim_data$timestamp, na.rm = TRUE)
    )
    co2_15min <- interpolate_co2_15min(co2_result$df, sim_data$timestamp)
    impact <- compute_co2_impact(sim_data, co2_15min)
    plot_co2_cumul(sim_data, impact)
  }, error = function(e) NULL)

  # Copy template + assets to a temp dir for rendering
  tmp_dir <- tempfile("presentation_")
  dir.create(tmp_dir)
  src_dir <- dirname(qmd_path)
  file.copy(list.files(src_dir, full.names = TRUE), tmp_dir, recursive = TRUE)

  # Save pre-built plotly objects for the .qmd
  saveRDS(p_tranches, file.path(tmp_dir, "plot_tranches.rds"))
  saveRDS(p_profil, file.path(tmp_dir, "plot_profil.rds"))
  if (!is.null(p_co2_cumul)) {
    saveRDS(p_co2_cumul, file.path(tmp_dir, "plot_co2_cumul.rds"))
  }

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

#' Render simulation report as Markdown
#'
#' Produces a plain markdown file with the same content as the RevealJS
#' presentation, suitable for AI parsing or archival.
#'
#' @param kpis,params,sim_data,kpis_cible,params_cible Same as render_presentation
#' @param output_file Path for the .md output
#' @return Path to the rendered file (invisibly)
render_markdown <- function(kpis, params, sim_data, output_file,
                            kpis_cible = NULL, params_cible = NULL) {
  p_list <- if (inherits(params, "SimulationParams")) params$as_list() else params

  # Date range
  ts <- sim_data$timestamp
  date_debut <- format(min(ts, na.rm = TRUE), "%d/%m/%Y")
  date_fin <- format(max(ts, na.rm = TRUE), "%d/%m/%Y")

  # PAC share
  total_conso <- sum(sim_data$offtake_kwh, na.rm = TRUE)
  pac_conso <- kpis$conso_pac_baseline
  pct_pac <- if (total_conso > 0) round(pac_conso / total_conso * 100) else 55

  # Annual projections
  proj <- project_annual_kpis(kpis, sim_data)

  # CO2
  co2_kpis <- tryCatch({
    co2_result <- fetch_co2_intensity(min(ts, na.rm = TRUE), max(ts, na.rm = TRUE))
    co2_15min <- interpolate_co2_15min(co2_result$df, ts)
    impact <- compute_co2_impact(sim_data, co2_15min)
    co2_base_kg <- sum(impact$co2_baseline_g, na.rm = TRUE) / 1000
    list(
      co2_baseline_kg = co2_base_kg,
      co2_saved_kg = impact$co2_saved_kg,
      co2_pct_reduction = impact$co2_pct_reduction,
      co2_intensity_baseline = impact$intensity_before,
      co2_intensity_opti = impact$intensity_after,
      co2_equiv_car_km = impact$equiv_car_km,
      co2_equiv_trees_year = impact$equiv_trees_year
    )
  }, error = function(e) NULL)

  # BELIX analysis
  kpi_calc <- KPICalculator$new()
  belix <- kpi_calc$get_belix_pilotage(sim_data, p_list)

  # Helpers
  fmt <- function(x, digits = 0) formatC(x, format = "f", big.mark = " ", digits = digits)
  fmt1 <- function(x) formatC(x, format = "f", big.mark = " ", digits = 1)
  pct_delta <- function(base, opti) round((base - opti) / base * 100)
  p <- list(
    site_name = "Profondeville", n_logements = 20, n_immeubles = 4,
    surface_m2 = 2000, conso_chauffage_mwh_an = 198, co2_evite_20ans_t = 717,
    pac_kw = p_list$p_pac_th_kw %||% 60,
    pv_kwc = p_list$pv_kwc %||% 64,
    pv_kwc_ref = p_list$pv_kwc_ref %||% p_list$pv_kwc %||% 64,
    volume_ballon_l = p_list$volume_ballon_l %||% 32000,
    t_min = p_list$t_min %||% 45, t_max = p_list$t_max %||% 55,
    cop_median_hiver = 2.5, cop_median_misaison = 4.5,
    date_debut = date_debut, date_fin = date_fin,
    n_days = round(kpis$n_days), type_contrat = p_list$type_contrat %||% "spot",
    # Financial
    cout_soutirage_baseline = round(kpis$cout_soutirage_baseline),
    cout_soutirage_opti = round(kpis$cout_soutirage_opti),
    rev_injection_baseline = round(kpis$rev_injection_baseline),
    rev_injection_opti = round(kpis$rev_injection_opti),
    facture_baseline = round(kpis$facture_baseline),
    facture_opti = round(kpis$facture_opti),
    gain_eur = round(kpis$gain_eur), gain_pct = round(abs(kpis$gain_pct)),
    gain_eur_per_day = round(kpis$gain_eur_per_day, 2),
    # Energy
    soutirage_baseline_kwh = round(kpis$soutirage_baseline),
    soutirage_opti_kwh = round(kpis$soutirage_opti),
    injection_baseline_kwh = round(kpis$injection_baseline),
    injection_opti_kwh = round(kpis$injection_opti),
    ac_baseline = kpis$ac_baseline, ac_opti = kpis$ac_opti,
    as_baseline = kpis$as_baseline, as_opti = kpis$as_opti,
    conso_pac_baseline_kwh = round(kpis$conso_pac_baseline),
    conso_pac_opti_kwh = round(kpis$conso_pac_opti),
    pct_pac_conso = pct_pac,
    # CO2
    co2_baseline_kg = round(co2_kpis$co2_baseline_kg %||% 0),
    co2_saved_kg = round(co2_kpis$co2_saved_kg %||% 0),
    co2_pct_reduction = round(co2_kpis$co2_pct_reduction %||% 0),
    co2_intensity_baseline = round(co2_kpis$co2_intensity_baseline %||% 0),
    co2_intensity_opti = round(co2_kpis$co2_intensity_opti %||% 0),
    co2_equiv_car_km = round(co2_kpis$co2_equiv_car_km %||% 0),
    co2_equiv_trees_year = round(co2_kpis$co2_equiv_trees_year %||% 0),
    # Projections
    proj_heat_coverage_pct = proj$heat_coverage_pct,
    proj_facture_baseline_an = proj$facture_baseline_an,
    proj_facture_opti_an = proj$facture_opti_an,
    proj_gain_eur_an = proj$gain_eur_an, proj_gain_pct_an = proj$gain_pct_an,
    proj_pv_total_an = proj$pv_total_an, proj_ac_opti_an = proj$ac_opti_an,
    proj_co2_saved_an_kg = proj$co2_saved_an_kg,
    # BELIX
    belix_pct_temps_offpeak = belix$pct_temps_offpeak,
    belix_pct_pac_offpeak = belix$pct_pac_offpeak,
    belix_ecart_pp = belix$ecart_pp, belix_verdict = belix$verdict,
    # Dual-contract
    has_dual_contrat = !is.null(kpis_cible),
    type_contrat_cible = if (!is.null(params_cible)) params_cible$type_contrat else ""
  )
  # Dual-contract values
  if (!is.null(kpis_cible)) {
    p$dual_fa <- round(kpis$facture_baseline)
    p$dual_fb <- round(kpis$facture_opti)
    p$dual_fd <- round(kpis_cible$facture_opti)
    p$dual_levier1 <- round(kpis$facture_baseline - kpis$facture_opti)
    p$dual_levier2 <- round(kpis$facture_opti - kpis_cible$facture_opti)
    p$dual_gain_total <- round(kpis$facture_baseline - kpis_cible$facture_opti)
    p$dual_gain_total_pct <- if (abs(kpis$facture_baseline) > 0.001) {
      round((kpis$facture_baseline - kpis_cible$facture_opti) / abs(kpis$facture_baseline) * 100)
    } else 0
    p$dual_proj_gain_total_an <- round((kpis$facture_baseline - kpis_cible$facture_opti) *
      proj$facture_baseline_an / max(kpis$facture_baseline, 1))
    p$dual_proj_fd_an <- round(kpis_cible$facture_opti *
      proj$facture_baseline_an / max(kpis$facture_baseline, 1))
  }

  dual <- isTRUE(p$has_dual_contrat)

  # --- Build markdown ---
  md <- c(
    sprintf("# Pilotage du reseau de chaleur de %s avec WISE Brain", p$site_name),
    "", "**Proof of Concept**", "",
    sprintf("*Rapport genere le %s*", format(Sys.time(), "%Y-%m-%d %H:%M")),
    "",
    "---",
    "",
    "## Sommaire",
    "",
    sprintf("1. Le site — %s, installation et constats", p$site_name),
    "2. L'opportunite — Marche de l'energie et strategies de flexibilite",
    "3. Notre approche — Donnees, algorithme ToU",
    "4. Les resultats — Economies et impact",
    "5. Et ensuite ? — Prochaines etapes",
    "",
    "---",
    "",
    "# 1. Le site",
    "",
    "## Le projet en bref",
    "",
    sprintf("**%d logements** repartis en **%d immeubles** residentiels (%s m2), rue des Dechanges, 5170 %s.",
      p$n_logements, p$n_immeubles, fmt(p$surface_m2), p$site_name),
    "",
    "- Reseau de chaleur mis en service en **novembre 2024**",
    "- Promoteur : **Devlop Ream Group** | Operateur DBFMO : **Karno** (K-0001)",
    sprintf("- Consommation chauffage annuelle : **%d MWh**", p$conso_chauffage_mwh_an),
    "",
    "## Installation technique",
    "",
    "- **Champ de sondes geothermiques** (source principale)",
    "- **PAC geothermique (GSHP)** : 40 kW, fonctionnement on/off",
    "- **PAC aerothermique (ASHP)** : 20 kW, modulation continue (backup & equilibrage)",
    sprintf("- **Ballon tampon** pour le stockage thermique (%s L)", fmt(p$volume_ballon_l)),
    sprintf("- **Installation PV** (~%s kWc, panneaux installes sept. 2025)", p$pv_kwc),
    "- Compteur ORES bidirectionnel (import/export)",
    "",
    "La combinaison **PAC + PV + stockage thermique** offre plusieurs degres de liberte pour l'optimisation.",
    "",
    "---",
    "",
    "# 2. Les constats",
    "",
    "## Ce que les donnees mesurees revelent",
    "",
    sprintf("**%d jours** de donnees reelles (%s -> %s) :", p$n_days, p$date_debut, p$date_fin),
    "",
    "| Metrique mesuree | Valeur | Ce que ca signifie |",
    "|---|---:|---|",
    sprintf("| **Autoconsommation PV** | %s%% | ~%d%% du PV est reinjecte (vendu a bas prix) |",
      fmt1(p$ac_baseline), round(100 - p$ac_baseline)),
    sprintf("| **Autosuffisance** | %s%% | ~%d%% de l'electricite vient du reseau (achetee a prix fort) |",
      fmt1(p$as_baseline), round(100 - p$as_baseline)),
    sprintf("| **Part PAC dans la conso** | %d%% | La PAC est le premier poste de consommation electrique |", p$pct_pac_conso),
    sprintf("| **Facture nette** | %s EUR / %d j | Soit ~%s EUR/an extrapole |",
      fmt(p$facture_baseline), p$n_days, fmt(p$proj_facture_baseline_an)),
    "",
    sprintf("**En resume** : la PAC tourne surtout **la nuit et le matin**, quand l'energie est chere, carbonee et le PV ne produit pas. Le ballon tampon (%s L) offre une flexibilite de stockage thermique **inexploitee**.",
      fmt(p$volume_ballon_l)),
    "",
    "---",
    "",
    "# 3. L'opportunite",
    "",
    "## Le marche de l'energie pousse au pilotage intelligent",
    "",
    "- **Volatilite croissante** : les prix spot varient de < 0 a > 300 EUR/MWh au sein d'une meme journee",
    "- **Prix negatifs structurels** : au printemps/ete, la surproduction solaire fait regulierement plonger les prix",
    "- **Prix bas = electricite verte** : quand le solaire et l'eolien dominent le mix, les prix chutent **et** l'intensite carbone aussi",
    "- **Contrats dynamiques** : seuls les consommateurs en contrat indexe sur le spot peuvent capter ces opportunites",
    "- **Flexibilite = valeur** : un reseau de chaleur avec stockage thermique est idealement place pour **absorber les heures gratuites**",
    "",
    "## Quelles strategies de flexibilite ?",
    "",
    "| Strategie | Gain estime | Risque confort | Principe |",
    "|---|---:|:---:|---|",
    "| **ToU shifting** | **15-30%** | Faible | Decaler la PAC vers les heures creuses / prix bas |",
    "| Peak shaving | 5-15% | Faible | Ecreter les pics de puissance (tarif capacitaire) |",
    "| Curtailment | 2-5% | Moyen | Couper la PAC pendant les prix extremes |",
    "| **ToU + Peak** | **20-40%** | Faible | Combinaison des deux premiers leviers |",
    "",
    sprintf("Le **Time-of-Use** est le levier le plus rentable pour ce site : le ballon tampon de %s L offre l'inertie necessaire.", fmt(p$volume_ballon_l)),
    "",
    "---",
    "",
    "# 4. Notre approche",
    "",
    "## Sources de donnees",
    "",
    "| Flux | Source | Ce qu'on mesure |",
    "|------|--------|-----------------|",
    "| **Consommation PAC** | Controleur Komfor (BigQuery) | Electricite consommee + temperature du ballon |",
    "| **Echanges reseau** | Compteur ORES (BigQuery) | Soutirage et injection (import/export) |",
    sprintf("| **Production PV** | Profil Elia (API) | Estimation regionale mise a l'echelle (~%s kWc) |", p$pv_kwc),
    "",
    "Donnees externes ajoutees :",
    "",
    "- **Prix spot BELPEX** (ENTSO-E) : combien coute le kWh a cet instant ?",
    "- **Temperature exterieure** (Open-Meteo) : quel est le rendement (COP) de la PAC ?",
    "",
    "## Hypotheses de la simulation",
    "",
    sprintf("**1. Une seule PAC de %d kW thermique** : le site dispose de deux sous-systemes (GSHP 40 kW + ASHP 20 kW). On les traite comme une seule unite modulante — surestime legerement la flexibilite.", p$pac_kw),
    "",
    sprintf("**2. Aucun pilotage tarifaire dans la baseline** : le site est sous contrat BELIX. Les heures creuses representent %s%% de la journee, mais la PAC n'y consomme que %s%% de son energie. C'est un **thermostat pur**.",
      round(p$belix_pct_temps_offpeak, 1), round(p$belix_pct_pac_offpeak, 1)),
    "",
    "## L'optimiseur ToU",
    "",
    "**Idee** : deplacer la consommation PAC des heures cheres vers les heures bon marche, grace a l'inertie thermique du ballon tampon.",
    "",
    "- Programmation lineaire (LP), blocs de 24h avec chevauchement",
    sprintf("- Temperature du ballon maintenue dans [%d-%d C]", p$t_min, p$t_max),
    "- COP variable selon la temperature exterieure",
    "- **Les occupants ne ressentent rien** — seul le planning de la PAC change",
    "",
    "---",
    "",
    "# 5. Les resultats",
    ""
  )

  # Financial impact
  if (dual) {
    md <- c(md,
      sprintf("## Impact financier : -%d%% sur la facture", p$dual_gain_total_pct),
      "",
      sprintf("**Simulation** : %d jours | %s -> %s | PAC %d kW | PV %s kWc | Ballon %s L [%d-%d C]",
        p$n_days, p$type_contrat, p$type_contrat_cible, p$pac_kw, p$pv_kwc,
        fmt(p$volume_ballon_l), p$t_min, p$t_max),
      "",
      "|  | EUR | % facture actuelle |",
      "|--|----:|---:|",
      sprintf("| **Situation actuelle** (%s, thermostat) | **%s** | — |",
        p$type_contrat, fmt(p$dual_fa)),
      sprintf("| Levier 1 : Pilotage ToU (meme contrat) | -%s | -%d%% |",
        fmt(p$dual_levier1), round(p$dual_levier1 / p$dual_fa * 100)),
      sprintf("| Levier 2 : Passage %s -> %s | -%s | -%d%% |",
        p$type_contrat, p$type_contrat_cible, fmt(p$dual_levier2),
        round(p$dual_levier2 / p$dual_fa * 100)),
      sprintf("| **Resultat final** (%s + Wise Brain) | **%s** | **-%d%%** |",
        p$type_contrat_cible, fmt(p$dual_fd), p$dual_gain_total_pct),
      "",
      sprintf("**Economie totale : %s EUR** sur %d jours = levier pilotage (%s EUR) + levier contrat (%s EUR).",
        fmt(p$dual_gain_total), p$n_days, fmt(p$dual_levier1), fmt(p$dual_levier2)),
      ""
    )
  } else {
    md <- c(md,
      sprintf("## Impact financier : -%d%% sur la facture", p$gain_pct),
      "",
      sprintf("**Simulation** : %d jours | contrat %s | PAC %d kW | PV %s kWc | Ballon %s L [%d-%d C]",
        p$n_days, p$type_contrat, p$pac_kw, p$pv_kwc,
        fmt(p$volume_ballon_l), p$t_min, p$t_max),
      "",
      "|  | Baseline (thermostat) | Optimise (Wise Brain) | Gain |",
      "|--|----------------------:|--------------------:|-----:|",
      sprintf("| Cout soutirage | %s EUR | %s EUR | %s EUR |",
        fmt(p$cout_soutirage_baseline), fmt(p$cout_soutirage_opti),
        fmt(p$cout_soutirage_baseline - p$cout_soutirage_opti)),
      sprintf("| Revenu injection | %s EUR | %s EUR | %s EUR |",
        fmt(p$rev_injection_baseline), fmt(p$rev_injection_opti),
        fmt(p$rev_injection_opti - p$rev_injection_baseline)),
      sprintf("| **Facture nette** | **%s EUR** | **%s EUR** | **-%s EUR (-%d%%)** |",
        fmt(p$facture_baseline), fmt(p$facture_opti), fmt(p$gain_eur), p$gain_pct),
      sprintf("| **Extrapole /an** | **%s EUR** | **%s EUR** | **-%s EUR/an** |",
        fmt(p$proj_facture_baseline_an), fmt(p$proj_facture_opti_an), fmt(p$proj_gain_eur_an)),
      "",
      sprintf("**%s EUR d'economie par jour**, juste en pilotant intelligemment la PAC.", fmt(p$gain_eur_per_day, 2)),
      ""
    )
  }

  # Energy
  md <- c(md,
    "## Energie et flexibilite",
    "",
    "| Metrique | Baseline | Optimise (Wise Brain) | Delta |",
    "|----------|--------:|---------:|------:|",
    sprintf("| Soutirage reseau | %s kWh | %s kWh | %s kWh (-%d%%) |",
      fmt(p$soutirage_baseline_kwh), fmt(p$soutirage_opti_kwh),
      fmt(p$soutirage_baseline_kwh - p$soutirage_opti_kwh),
      pct_delta(p$soutirage_baseline_kwh, p$soutirage_opti_kwh)),
    sprintf("| Injection reseau | %s kWh | %s kWh | %s kWh (-%d%%) |",
      fmt(p$injection_baseline_kwh), fmt(p$injection_opti_kwh),
      fmt(p$injection_baseline_kwh - p$injection_opti_kwh),
      pct_delta(p$injection_baseline_kwh, p$injection_opti_kwh)),
    sprintf("| Autoconsommation PV | %s%% | %s%% | +%d points |",
      fmt1(p$ac_baseline), fmt1(p$ac_opti), round(p$ac_opti - p$ac_baseline)),
    sprintf("| Autosuffisance | %s%% | %s%% | +%d points |",
      fmt1(p$as_baseline), fmt1(p$as_opti), round(p$as_opti - p$as_baseline)),
    sprintf("| Conso PAC electrique | %s kWh | %s kWh | %s kWh (-%d%%) |",
      fmt(p$conso_pac_baseline_kwh), fmt(p$conso_pac_opti_kwh),
      fmt(p$conso_pac_baseline_kwh - p$conso_pac_opti_kwh),
      pct_delta(p$conso_pac_baseline_kwh, p$conso_pac_opti_kwh)),
    "",
    sprintf("La PAC = **%d%% de l'electricite du batiment**. Le Wise Brain ne reduit pas la consommation, il la **decale** vers les heures solaires et les prix bas.", p$pct_pac_conso),
    ""
  )

  # Projection annuelle
  md <- c(md,
    "## Projection annuelle (estimation)",
    "",
    sprintf("Les %d jours de mesures couvrent **%d%% de la demande de chauffage annuelle**. Projection sur 12 mois :",
      p$n_days, p$proj_heat_coverage_pct),
    ""
  )
  if (dual) {
    md <- c(md,
      "| KPI | Mesure | Projection annuelle |",
      "|-----|---:|---:|",
      sprintf("| **Facture actuelle** (%s) | %s EUR | ~%s EUR |",
        p$type_contrat, fmt(p$dual_fa), fmt(p$proj_facture_baseline_an)),
      sprintf("| **Facture finale** (%s + Wise Brain) | %s EUR | ~%s EUR |",
        p$type_contrat_cible, fmt(p$dual_fd), fmt(p$dual_proj_fd_an)),
      sprintf("| **Economie totale** | %s EUR (-%d%%) | **~%s EUR/an** |",
        fmt(p$dual_gain_total), p$dual_gain_total_pct, fmt(p$dual_proj_gain_total_an)),
      sprintf("| Production PV | %s kWh | ~%s kWh |",
        fmt(round(p$soutirage_baseline_kwh + p$injection_baseline_kwh)), fmt(p$proj_pv_total_an)),
      sprintf("| CO2 evite | %s kg | ~%s kg |", fmt(p$co2_saved_kg), fmt(p$proj_co2_saved_an_kg)),
      ""
    )
  } else {
    md <- c(md,
      sprintf("| KPI | Mesure (%d j) | Projection annuelle |", p$n_days),
      "|-----|---:|---:|",
      sprintf("| **Facture baseline** | %s EUR | ~%s EUR |",
        fmt(p$facture_baseline), fmt(p$proj_facture_baseline_an)),
      sprintf("| **Facture optimisee** | %s EUR | ~%s EUR |",
        fmt(p$facture_opti), fmt(p$proj_facture_opti_an)),
      sprintf("| **Economie** | %s EUR (-%d%%) | **~%s EUR (-%d%%)** |",
        fmt(p$gain_eur), p$gain_pct, fmt(p$proj_gain_eur_an), p$proj_gain_pct_an),
      sprintf("| Production PV | %s kWh | ~%s kWh |",
        fmt(round(p$soutirage_baseline_kwh + p$injection_baseline_kwh)), fmt(p$proj_pv_total_an)),
      sprintf("| Autoconsommation opti | %s%% | ~%s%% |",
        fmt1(p$ac_opti), fmt1(p$proj_ac_opti_an)),
      sprintf("| CO2 evite | %s kg | ~%s kg |", fmt(p$co2_saved_kg), fmt(p$proj_co2_saved_an_kg)),
      ""
    )
  }

  # CO2
  if (p$co2_saved_kg > 0) {
    md <- c(md,
      "## Reduction des emissions CO2",
      "",
      sprintf("En decalant la PAC vers les heures solaires : **-%s kg CO2** sur %d jours (-%d%%). L'intensite carbone ponderee passe de **%d** a **%d gCO2/kWh**.",
        fmt(p$co2_saved_kg), p$n_days, p$co2_pct_reduction,
        p$co2_intensity_baseline, p$co2_intensity_opti),
      "",
      sprintf("Equivalent : **%s km** en voiture evites, ou **%d arbres** plantes par an.",
        fmt(p$co2_equiv_car_km), p$co2_equiv_trees_year),
      "",
      "| KPI CO2 | Baseline | Optimise | Delta |",
      "|---------|--------:|--------:|------:|",
      sprintf("| Emissions totales | %s kg | %s kg | -%s kg (-%d%%) |",
        fmt(p$co2_baseline_kg), fmt(p$co2_baseline_kg - p$co2_saved_kg),
        fmt(p$co2_saved_kg), p$co2_pct_reduction),
      sprintf("| Intensite carbone | %d gCO2/kWh | %d gCO2/kWh | -%d gCO2/kWh |",
        p$co2_intensity_baseline, p$co2_intensity_opti,
        p$co2_intensity_baseline - p$co2_intensity_opti),
      sprintf("| Equivalent voiture | — | — | %s km evites |", fmt(p$co2_equiv_car_km)),
      sprintf("| Equivalent arbres | — | — | %d arbres/an |", p$co2_equiv_trees_year),
      ""
    )
  }

  # Message cle
  md <- c(md,
    "---",
    "",
    "# 6. Et ensuite ?",
    "",
    "## Le message cle",
    ""
  )
  if (dual) {
    md <- c(md, sprintf(
      "> La PAC du projet K-0001 a Profondeville represente %d%% de la consommation electrique et tourne surtout la nuit quand l'energie est chere. Le Wise Brain la fait tourner quand le soleil brille et les prix sont bas — sans toucher au confort. En combinant pilotage ToU et passage %s -> %s : **-%d%% sur la facture, ~%s EUR/an d'economie**.",
      p$pct_pac_conso, p$type_contrat, p$type_contrat_cible,
      p$dual_gain_total_pct, fmt(p$dual_proj_gain_total_an)))
  } else {
    md <- c(md, sprintf(
      "> La PAC du projet K-0001 a Profondeville represente %d%% de la consommation electrique et tourne surtout la nuit quand l'energie est chere. Le Wise Brain la fait tourner quand le soleil brille et les prix sont bas — sans toucher au confort. Resultat : **-%d%% sur la facture, ~%s EUR/an d'economie**.",
      p$pct_pac_conso, p$gain_pct, fmt(p$proj_gain_eur_an)))
  }

  md <- c(md,
    "",
    "## Prochaines etapes",
    "",
    sprintf("- **Peak shaving** : ecreter les pointes de puissance (%d -> %d kW) en sequencant le demarrage des deux PAC ?",
      p$pac_kw, round(p$pac_kw * 2/3)),
    "- **Curtailment** : limiter l'injection PV en periode de prix negatifs pour maximiser l'autoconsommation ?",
    "- **Distinction GSHP / ASHP** : piloter les deux PAC independamment (on/off vs modulante)",
    "",
    "---",
    "",
    "# FAQ",
    "",
    "## Pourquoi dit-on qu'il n'y a pas de pilotage BELIX ?",
    "",
    sprintf("Les heures creuses representent **%s%% de la journee**, mais la PAC n'y consomme que **%s%% de son energie**. Une PAC pilotee concentrerait sa consommation en heures creuses (80-90%%). C'est un **thermostat pur**.",
      round(p$belix_pct_temps_offpeak, 1), round(p$belix_pct_pac_offpeak, 1)),
    "",
    "## Pourquoi la PAC consomme-t-elle moins en optimise ?",
    "",
    sprintf("Reduction de ~%d%% (%s kWh). Le Wise Brain produit la **meme chaleur** avec **moins d'electricite** :",
      pct_delta(p$conso_pac_baseline_kwh, p$conso_pac_opti_kwh),
      fmt(p$conso_pac_baseline_kwh - p$conso_pac_opti_kwh)),
    "",
    "| Mecanisme | Explication | Impact |",
    "|-----------|-------------|--------|",
    sprintf("| **COP plus eleve** | PAC en journee (plus chaud). COP %s a 15C vs %s a 0C | Principal |",
      p$cop_median_misaison, p$cop_median_hiver),
    "| **Moins de pertes thermiques** | Ballon maintenu plus proche de T_min en moyenne | Secondaire |",
    "| **Modulation continue** | Puissance [0-100%] au lieu du tout-ou-rien | Mineur |",
    "",
    sprintf("## Pourquoi le PV affiche ~%s kWc alors que l'installation fait %s kWc ?", p$pv_kwc_ref, p$pv_kwc),
    "",
    "On utilise le **profil regional Elia** (Namur) mis a l'echelle. L'installation Profondeville performe ~36% mieux que la moyenne regionale (meilleure orientation/inclinaison). Un **facteur de performance local** (1.36) corrige le profil Elia.",
    "",
    "## Comment mesure-t-on l'impact CO2 ?",
    "",
    "L'intensite carbone du reseau belge varie chaque heure selon le mix de production (donnees Elia Open Data) :",
    "",
    "| Source | Methodologie | Usage |",
    "|--------|-------------|-------|",
    "| **ODS192** | Consumption-based (imports inclus) | Source principale |",
    "| **ODS201** | Production-based (mix generation + facteurs IPCC) | Backfill des trous ODS192 |",
    "",
    "---",
    "",
    sprintf("*Genere par PAC Optimizer v%s*",
      as.character(tryCatch(utils::packageVersion("wisepocpac"), error = function(e) "dev")))
  )

  writeLines(md, output_file)
  invisible(output_file)
}
