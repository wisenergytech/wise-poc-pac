# =============================================================================
# MODULE CO2 ELIA — Intensite carbone du reseau electrique belge
# =============================================================================
# Recupere l'intensite CO2 horaire depuis Elia Open Data (API publique) :
#   - ODS192 : historique consumption-based (jusqu'a ~Dec 2025)
#   - ODS191 : temps reel consumption-based
#   - ODS201 : mix de generation → production-based (calcul via facteurs IPCC)
#   - Fallback : profil synthetique belge (moyennes horaires 2024)
#
# Methodologie : GHG Protocol Scope 2 (consumption-based quand disponible)
# =============================================================================

# ---------------------------------------------------------------------------
# Profil fallback : intensite CO2 horaire typique belge (gCO2eq/kWh)
# Consumption-based (imports inclus). Source : Elia ODS192 moyennes 2024.
# Index = heure UTC (0-23).
# ---------------------------------------------------------------------------
FALLBACK_CO2_PROFILE <- c(
  130, 125, 120, 115, 115, 118,   # 00-05h : nucleaire + eolien dominant
  145, 185, 215, 228, 222, 205,   # 06-11h : montee matin, gaz en marginal
  192, 182, 172, 178, 192, 218,   # 12-17h : solaire reduit midi, remontee
  242, 252, 232, 202, 173, 148    # 18-23h : pointe soir, puis decline
)

# ---------------------------------------------------------------------------
# Facteurs d'emission lifecycle IPCC par type de combustible (gCO2eq/kWh)
# Source : IPCC AR5 Annex II + mapping ENTSO-E
# ---------------------------------------------------------------------------
IPCC_EMISSION_FACTORS <- c(
  "Nuclear"                        = 12.0,
  "Wind Onshore"                   = 11.0,
  "Wind Offshore"                  = 12.0,
  "Solar"                          = 41.0,
  "Hydro Run-of-river and poundage" = 4.0,
  "Hydro Pumped Storage"           = 30.0,
  "Fossil Gas"                     = 490.0,
  "Fossil Oil"                     = 650.0,
  "Biomass"                        = 230.0,
  "Waste"                          = 350.0,
  "Energy Storage"                 = 0.0,
  "Other"                          = 300.0
)

# Constantes d'equivalence
CO2_CAR_KM_FACTOR  <- 120   # gCO2/km, EU WLTP 2024
CO2_TREE_KG_YEAR   <- 25    # kg CO2/arbre/an, FAO

ELIA_BASE_URL <- "https://opendata.elia.be/api/explore/v2.1/catalog/datasets"
ELIA_PAGE_SIZE <- 100
ELIA_TIMEOUT <- 12

# ---------------------------------------------------------------------------
# Charger les donnees CO2 : .rda package data -> CSV fallback
# ---------------------------------------------------------------------------
load_local_co2 <- function(data_dir = "data") {
  # Priorite 1 : objet package (lazy-loaded, instantane)
  if (exists("elia_co2", where = asNamespace("wisepocpac"), inherits = FALSE)) {
    return(get("elia_co2", envir = asNamespace("wisepocpac")))
  }
  if (exists("elia_co2", envir = .GlobalEnv)) {
    return(get("elia_co2", envir = .GlobalEnv))
  }

  # Priorite 2 : CSV locaux
  files <- list.files(data_dir, pattern = "elia_co2_.*\\.csv$", full.names = TRUE)
  if (length(files) == 0) return(NULL)

  dfs <- lapply(files, function(f) {
    df <- readr::read_csv(f, show_col_types = FALSE,
      col_types = readr::cols(datetime = readr::col_character()))
    names(df) <- c("datetime_raw", "co2_g_per_kwh")
    df$datetime_clean <- gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", df$datetime_raw))
    df$datetime <- lubridate::ymd_hms(df$datetime_clean, tz = "UTC")
    df <- df[!is.na(df$datetime), c("datetime", "co2_g_per_kwh")]
    df
  })

  df <- dplyr::bind_rows(dfs)
  df <- dplyr::distinct(df, datetime, .keep_all = TRUE)
  df <- dplyr::arrange(df, datetime)
  df
}

# ---------------------------------------------------------------------------
# Fetch principal : CSV local → ODS192 → ODS191 → ODS201 → fallback
# ---------------------------------------------------------------------------
#' Fetch hourly CO2 intensity for a date range
#'
#' Tries sources in priority order: local CSV cache, Elia ODS192
#' (historical), ODS191 (real-time), ODS201 (generation mix), then
#' falls back to a synthetic Belgian average profile.
#'
#' @param start_date Start date (Date or POSIXct)
#' @param end_date End date (Date or POSIXct)
#' @return A list with:
#'   \describe{
#'     \item{df}{Tibble with columns \code{datetime} (POSIXct UTC) and
#'       \code{co2_g_per_kwh} (numeric)}
#'     \item{source}{Character: \code{"local"}, \code{"api_historical"},
#'       \code{"api_realtime"}, \code{"api_generation_mix"}, or
#'       \code{"fallback"}}
#'   }
#' @export
fetch_co2_intensity <- function(start_date, end_date) {

  start_date <- as.POSIXct(paste0(as.Date(start_date), " 00:00:00"), tz = "UTC")
  end_date   <- as.POSIXct(paste0(as.Date(end_date),   " 23:59:59"), tz = "UTC")

  # 0. CSV locaux (instantane, pas de reseau)
  local <- load_local_co2()
  if (!is.null(local)) {
    local_filtered <- dplyr::filter(local, datetime >= start_date, datetime <= end_date)
    if (nrow(local_filtered) > 0) {
      coverage <- as.numeric(difftime(max(local_filtered$datetime),
        min(local_filtered$datetime), units = "days"))
      requested <- as.numeric(difftime(end_date, start_date, units = "days"))
      if (coverage >= requested * 0.9) {
        message(sprintf("[CO2] CSV local : %d points", nrow(local_filtered)))
        return(list(df = local_filtered, source = "local"))
      }
    }
  }

  # 1. Historique consumption-based (ODS192)
  df <- fetch_elia_co2_dataset("ods192", start_date, end_date)
  if (!is.null(df) && nrow(df) > 0) {
    message(sprintf("[CO2 Elia] ODS192 : %d enregistrements", nrow(df)))
    return(list(df = df, source = "api_historical"))
  }

  # 2. Temps reel consumption-based (ODS191)
  df <- fetch_elia_co2_dataset("ods191", start_date, end_date)
  if (!is.null(df) && nrow(df) > 0) {
    message(sprintf("[CO2 Elia] ODS191 : %d enregistrements", nrow(df)))
    return(list(df = df, source = "api_realtime"))
  }

  # 3. Production-based depuis mix de generation (ODS201)
  df <- fetch_co2_from_generation(start_date, end_date)
  if (!is.null(df) && nrow(df) > 0) {
    message(sprintf("[CO2 Elia] ODS201 (calcule) : %d enregistrements", nrow(df)))
    return(list(df = df, source = "api_generation_mix"))
  }

  # 4. Fallback synthetique
  message("[CO2 Elia] Fallback : profil synthetique belge")
  df <- build_fallback_co2(start_date, end_date)
  return(list(df = df, source = "fallback"))
}

# ---------------------------------------------------------------------------
# Fetch pagine depuis un dataset Elia (ODS192 ou ODS191)
# ---------------------------------------------------------------------------
fetch_elia_co2_dataset <- function(dataset_id, start_date, end_date) {
  tryCatch({
    start_str <- format(start_date, "%Y-%m-%dT%H:%M:%S")
    end_str   <- format(end_date,   "%Y-%m-%dT%H:%M:%S")
    url <- sprintf("%s/%s/records", ELIA_BASE_URL, dataset_id)

    all_records <- list()
    offset <- 0

    repeat {
      resp <- httr::GET(url,
        query = list(
          limit    = ELIA_PAGE_SIZE,
          offset   = offset,
          order_by = "datetime",
          where    = sprintf('datetime >= "%s" AND datetime <= "%s"', start_str, end_str),
          select   = "datetime,consumption"
        ),
        httr::timeout(ELIA_TIMEOUT)
      )

      if (httr::status_code(resp) != 200) return(NULL)

      data <- httr::content(resp, as = "parsed", simplifyVector = TRUE)
      records <- data$results
      if (is.null(records) || length(records) == 0 || nrow(records) == 0) break

      all_records[[length(all_records) + 1]] <- records
      total <- data$total_count %||% 0
      offset <- offset + nrow(records)
      if (offset >= total) break
    }

    if (length(all_records) == 0) return(NULL)

    df <- dplyr::bind_rows(all_records)
    df$datetime <- as.POSIXct(sub("[+-]\\d{2}:\\d{2}$", "", df$datetime),
                              format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    df$datetime <- lubridate::floor_date(df$datetime, "hour")
    df <- df %>%
      dplyr::rename(co2_g_per_kwh = consumption) %>%
      dplyr::select(datetime, co2_g_per_kwh) %>%
      dplyr::filter(!is.na(co2_g_per_kwh)) %>%
      dplyr::distinct(datetime, .keep_all = TRUE) %>%
      dplyr::arrange(datetime)

    if (nrow(df) == 0) return(NULL)
    df
  }, error = function(e) {
    message(sprintf("[CO2 Elia] Erreur %s : %s", dataset_id, e$message))
    NULL
  })
}

# ---------------------------------------------------------------------------
# Calcul production-based depuis le mix de generation (ODS201)
# ---------------------------------------------------------------------------
fetch_co2_from_generation <- function(start_date, end_date) {
  tryCatch({
    start_str <- format(start_date, "%Y-%m-%dT%H:%M:%S")
    end_str   <- format(end_date,   "%Y-%m-%dT%H:%M:%S")
    url <- sprintf("%s/ods201/records", ELIA_BASE_URL)

    where_clause <- sprintf(
      'datetime >= "%s" AND datetime <= "%s" AND resolutioncode = "PT15M"',
      start_str, end_str
    )

    all_records <- list()
    offset <- 0

    repeat {
      resp <- httr::GET(url,
        query = list(
          limit    = ELIA_PAGE_SIZE,
          offset   = offset,
          order_by = "datetime",
          where    = where_clause,
          select   = "datetime,fueltypeentsoe,generatedpower"
        ),
        httr::timeout(ELIA_TIMEOUT)
      )

      if (httr::status_code(resp) != 200) return(NULL)

      data <- httr::content(resp, as = "parsed", simplifyVector = TRUE)
      records <- data$results
      if (is.null(records) || length(records) == 0 || nrow(records) == 0) break

      all_records[[length(all_records) + 1]] <- records
      total <- data$total_count %||% 0
      offset <- offset + nrow(records)
      if (offset >= total) break
    }

    if (length(all_records) == 0) return(NULL)

    df <- dplyr::bind_rows(all_records)
    df$datetime <- as.POSIXct(sub("[+-]\\d{2}:\\d{2}$", "", df$datetime),
                              format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    df$datetime <- lubridate::floor_date(df$datetime, "hour")
    df$generatedpower <- as.numeric(df$generatedpower)
    df <- df %>% dplyr::filter(!is.na(generatedpower), generatedpower > 0)

    if (nrow(df) == 0) return(NULL)

    # Appliquer les facteurs d'emission IPCC
    df$ef <- IPCC_EMISSION_FACTORS[df$fueltypeentsoe]
    df$ef[is.na(df$ef)] <- 300.0  # facteur par defaut
    df$co2_g <- df$generatedpower * df$ef

    # Moyenne ponderee par heure
    hourly <- df %>%
      dplyr::group_by(datetime) %>%
      dplyr::summarise(
        co2_g_per_kwh = sum(co2_g) / sum(generatedpower),
        .groups = "drop"
      ) %>%
      dplyr::filter(!is.na(co2_g_per_kwh)) %>%
      dplyr::arrange(datetime)

    if (nrow(hourly) == 0) return(NULL)
    hourly
  }, error = function(e) {
    message(sprintf("[CO2 Elia] Erreur ODS201 : %s", e$message))
    NULL
  })
}

# ---------------------------------------------------------------------------
# Profil fallback synthetique
# ---------------------------------------------------------------------------
build_fallback_co2 <- function(start_date, end_date) {
  hours <- seq(
    from = lubridate::floor_date(start_date, "hour"),
    to   = lubridate::floor_date(end_date, "hour"),
    by   = "1 hour"
  )
  # Heure UTC pour indexer le profil
  h_utc <- as.integer(format(hours, "%H"))
  tibble::tibble(
    datetime      = hours,
    co2_g_per_kwh = FALLBACK_CO2_PROFILE[h_utc + 1]
  )
}

# ---------------------------------------------------------------------------
# Interpolation horaire → 15 min
# ---------------------------------------------------------------------------
#' Interpolate hourly CO2 intensity to 15-minute resolution
#'
#' Performs linear interpolation of hourly CO2 intensity data onto
#' 15-minute simulation timestamps. Handles timezone conversion
#' (UTC to Europe/Brussels) internally.
#'
#' @param co2_hourly Tibble with columns \code{datetime} (POSIXct, UTC)
#'   and \code{co2_g_per_kwh} (numeric)
#' @param ts_15min POSIXct vector of 15-minute timestamps (Europe/Brussels)
#' @return Numeric vector of interpolated CO2 intensity (gCO2/kWh),
#'   same length as \code{ts_15min}
#' @export
interpolate_co2_15min <- function(co2_hourly, ts_15min) {
  # Convertir en numerique pour approx()
  x_hourly <- as.numeric(co2_hourly$datetime)
  y_hourly <- co2_hourly$co2_g_per_kwh

  # Convertir timestamps 15min en UTC pour alignement
  x_target <- as.numeric(lubridate::with_tz(ts_15min, "UTC"))

  result <- approx(x_hourly, y_hourly, xout = x_target, rule = 2)$y

  # Remplacer NA par la mediane
  if (any(is.na(result))) {
    med <- median(y_hourly, na.rm = TRUE)
    result[is.na(result)] <- med
  }

  round(result, 1)
}

# ---------------------------------------------------------------------------
# Calcul d'impact CO2 : baseline vs optimise
# ---------------------------------------------------------------------------
#' Compute CO2 impact: baseline vs optimised
#'
#' Pure function (no Shiny dependency) that computes per-timestep and aggregate
#' CO2 impact metrics by comparing baseline and optimised grid offtake against
#' the grid carbon intensity signal.
#'
#' @param sim Dataframe with at least \code{offtake_kwh} (baseline) and
#'   \code{sim_offtake} (optimised) columns, one row per 15-min timestep
#' @param co2_15min Numeric vector of grid carbon intensity (gCO2eq/kWh),
#'   same length as \code{nrow(sim)}
#' @return A named list:
#'   \describe{
#'     \item{co2_saved_kg}{Total CO2 avoided (kg)}
#'     \item{co2_pct_reduction}{Intensity reduction (\%)}
#'     \item{intensity_before}{Consumption-weighted intensity baseline (gCO2/kWh)}
#'     \item{intensity_after}{Consumption-weighted intensity optimised (gCO2/kWh)}
#'     \item{equiv_car_km}{Car-km equivalent of CO2 saved}
#'     \item{equiv_trees_year}{Trees needed to absorb CO2 saved per year}
#'     \item{co2_baseline_g}{Per-timestep baseline emissions (g)}
#'     \item{co2_opti_g}{Per-timestep optimised emissions (g)}
#'     \item{co2_saved_g}{Per-timestep CO2 avoided (g)}
#'     \item{co2_saved_cumul_kg}{Cumulative CO2 avoided (kg)}
#'     \item{co2_intensity}{Input intensity vector (gCO2/kWh)}
#'   }
#' @export
compute_co2_impact <- function(sim, co2_15min) {

  # CO2 par quart d'heure (gCO2eq)
  co2_baseline_g <- sim$offtake_kwh * co2_15min
  co2_opti_g     <- sim$sim_offtake * co2_15min
  co2_saved_g    <- co2_baseline_g - co2_opti_g

  # Cumul en kg
  co2_saved_cumul_kg <- cumsum(co2_saved_g) / 1000

  # KPIs agreges
  total_baseline_kwh <- sum(sim$offtake_kwh, na.rm = TRUE)
  total_opti_kwh     <- sum(sim$sim_offtake, na.rm = TRUE)

  intensity_before <- if (total_baseline_kwh > 0) {
    sum(co2_baseline_g, na.rm = TRUE) / total_baseline_kwh
  } else 0

  intensity_after <- if (total_opti_kwh > 0) {
    sum(co2_opti_g, na.rm = TRUE) / total_opti_kwh
  } else 0

  co2_saved_kg <- sum(co2_saved_g, na.rm = TRUE) / 1000

  co2_pct_reduction <- if (intensity_before > 0) {
    (intensity_before - intensity_after) / intensity_before * 100
  } else 0

  # Equivalences
  equiv_car_km    <- co2_saved_kg * 1000 / CO2_CAR_KM_FACTOR
  equiv_trees_year <- co2_saved_kg / CO2_TREE_KG_YEAR

  list(
    co2_saved_kg       = co2_saved_kg,
    co2_pct_reduction  = co2_pct_reduction,
    intensity_before   = intensity_before,
    intensity_after    = intensity_after,
    equiv_car_km       = equiv_car_km,
    equiv_trees_year   = equiv_trees_year,
    co2_baseline_g     = co2_baseline_g,
    co2_opti_g         = co2_opti_g,
    co2_saved_g        = co2_saved_g,
    co2_saved_cumul_kg = co2_saved_cumul_kg,
    co2_intensity      = co2_15min
  )
}

#' Prepare hourly CO2 impact data for plotting
#'
#' Aggregates per-timestep CO2 impact to hourly resolution, computing
#' total CO2 saved and mean grid intensity per hour.
#'
#' @param sim Simulation dataframe with a \code{timestamp} column
#' @param impact Result from [compute_co2_impact()]
#' @return A dataframe with columns: \code{timestamp} (hourly),
#'   \code{co2_saved_g}, \code{co2_intensity}
#' @export
prepare_co2_hourly <- function(sim, impact) {
  sim %>%
    dplyr::mutate(
      co2_saved_g = impact$co2_saved_g,
      co2_intensity = impact$co2_intensity,
      .h = lubridate::floor_date(timestamp, "hour")
    ) %>%
    dplyr::group_by(.h) %>%
    dplyr::summarise(
      co2_saved_g = sum(co2_saved_g, na.rm = TRUE),
      co2_intensity = mean(co2_intensity, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::rename(timestamp = .h)
}

#' Prepare CO2 intensity heatmap matrix
#'
#' Pivots per-timestep CO2 intensity into a day x hour matrix suitable
#' for heatmap visualisation.
#'
#' @param sim Simulation dataframe with a \code{timestamp} column
#' @param impact Result from [compute_co2_impact()]
#' @return A named list with:
#'   \describe{
#'     \item{jours}{Date vector (rows)}
#'     \item{heures}{Integer vector of hours 0-23 (columns)}
#'     \item{z_mat}{Numeric matrix of mean CO2 intensity (gCO2/kWh)}
#'   }
#' @export
prepare_co2_heatmap <- function(sim, impact) {
  d <- sim %>%
    dplyr::mutate(
      co2_intensity = impact$co2_intensity,
      jour = as.Date(timestamp),
      h = lubridate::hour(timestamp)
    ) %>%
    dplyr::group_by(jour, h) %>%
    dplyr::summarise(co2 = mean(co2_intensity, na.rm = TRUE), .groups = "drop")

  mat <- d %>%
    tidyr::pivot_wider(names_from = h, values_from = co2) %>%
    dplyr::arrange(jour)

  list(
    jours = mat$jour,
    heures = as.integer(colnames(mat)[-1]),
    z_mat = as.matrix(mat[, -1])
  )
}
