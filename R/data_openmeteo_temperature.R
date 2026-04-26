# =============================================================================
# MODULE OPEN-METEO — Temperatures historiques horaires
# =============================================================================
# Priorite : 1) CSV locaux (data/openmeteo_temperature_YYYY.csv)
#             2) API Open-Meteo Archive (gratuite, sans cle)
# =============================================================================

OPENMETEO_ARCHIVE_URL <- "https://archive-api.open-meteo.com/v1/archive"
OPENMETEO_TIMEOUT <- 30

# Coordonnees par defaut : Profondeville, Belgique
OPENMETEO_DEFAULT_LAT <- 50.38
OPENMETEO_DEFAULT_LON <- 4.86

#' Charge les temperatures historiques horaires (CSV local puis API fallback)
#'
#' @param start_date Date de debut (Date ou character YYYY-MM-DD)
#' @param end_date Date de fin (Date ou character YYYY-MM-DD)
#' @param data_dir Repertoire contenant les CSV
#' @param latitude Latitude du site (default Profondeville)
#' @param longitude Longitude du site (default Profondeville)
#' @return tibble avec colonnes: timestamp (POSIXct, Europe/Brussels), t_ext (°C)
load_openmeteo_temperature <- function(start_date, end_date, data_dir = "data",
                                       latitude = OPENMETEO_DEFAULT_LAT,
                                       longitude = OPENMETEO_DEFAULT_LON) {

  start_date <- as.Date(start_date)
  end_date <- as.Date(end_date)

  # Priorite 1 : objet package (lazy-loaded, instantane)
  pkg_data <- NULL
  if (exists("openmeteo_temperature", where = asNamespace("wisepocpac"), inherits = FALSE)) {
    pkg_data <- get("openmeteo_temperature", envir = asNamespace("wisepocpac"))
  } else if (exists("openmeteo_temperature", envir = .GlobalEnv)) {
    pkg_data <- get("openmeteo_temperature", envir = .GlobalEnv)
  }

  years <- seq(lubridate::year(start_date), lubridate::year(end_date))
  all_data <- list()

  for (yr in years) {
    # Check .rda coverage for this year
    if (!is.null(pkg_data)) {
      yr_data <- pkg_data[lubridate::year(pkg_data$timestamp) == yr, ]
      if (nrow(yr_data) > 0) {
        message(sprintf("[Open-Meteo] .rda : %d points pour %d", nrow(yr_data), yr))
        all_data[[as.character(yr)]] <- yr_data
        next
      }
    }

    # Priorite 2 : CSV local
    csv_file <- file.path(data_dir, sprintf("openmeteo_temperature_%d.csv", yr))
    if (file.exists(csv_file)) {
      message(sprintf("[Open-Meteo] Lecture %s", csv_file))
      df_year <- readr::read_csv(csv_file, show_col_types = FALSE)
      df_year$timestamp <- as.POSIXct(df_year$timestamp, tz = "Europe/Brussels")
      all_data[[as.character(yr)]] <- df_year
    } else {
      # Priorite 3 : API fallback
      message(sprintf("[Open-Meteo] Donnees manquantes pour %d, appel API...", yr))
      df_api <- fetch_openmeteo_year(yr, latitude, longitude)
      if (!is.null(df_api) && nrow(df_api) > 0) {
        all_data[[as.character(yr)]] <- df_api
      } else {
        warning(sprintf("[Open-Meteo] Aucune donnee pour %d", yr))
      }
    }
  }

  if (length(all_data) == 0) {
    warning("[Open-Meteo] Aucune donnee temperature trouvee")
    return(NULL)
  }

  df <- dplyr::bind_rows(all_data)
  df <- dplyr::filter(df,
    timestamp >= as.POSIXct(paste0(start_date, " 00:00:00"), tz = "Europe/Brussels"),
    timestamp <= as.POSIXct(paste0(end_date, " 23:59:59"), tz = "Europe/Brussels"))
  df <- dplyr::arrange(df, timestamp)

  message(sprintf("[Open-Meteo] %d enregistrements horaires charges (%s a %s)",
                  nrow(df), start_date, end_date))
  df
}

# ---------------------------------------------------------------------------
# Fetch depuis l'API Open-Meteo Archive (une annee)
# ---------------------------------------------------------------------------
fetch_openmeteo_year <- function(year, latitude, longitude) {
  # L'API archive a ~5 jours de retard ; limiter end_date a aujourd'hui - 5
  yr_start <- as.Date(sprintf("%d-01-01", year))
  yr_end <- as.Date(sprintf("%d-12-31", year))
  max_date <- Sys.Date() - 5
  yr_end <- min(yr_end, max_date)

  if (yr_start > max_date) {
    warning(sprintf("[Open-Meteo] %d pas encore disponible (archive ~5j de retard)", year))
    return(NULL)
  }

  tryCatch({
    resp <- httr::GET(
      OPENMETEO_ARCHIVE_URL,
      query = list(
        latitude = latitude,
        longitude = longitude,
        start_date = format(yr_start, "%Y-%m-%d"),
        end_date = format(yr_end, "%Y-%m-%d"),
        hourly = "temperature_2m",
        timezone = "Europe/Brussels"
      ),
      httr::timeout(OPENMETEO_TIMEOUT)
    )

    if (httr::status_code(resp) != 200) {
      warning(sprintf("[Open-Meteo] HTTP %d", httr::status_code(resp)))
      return(NULL)
    }

    data <- httr::content(resp, as = "parsed", simplifyVector = TRUE)

    if (is.null(data$hourly)) {
      warning("[Open-Meteo] Reponse sans donnees horaires")
      return(NULL)
    }

    df <- tibble::tibble(
      timestamp = as.POSIXct(data$hourly$time, format = "%Y-%m-%dT%H:%M", tz = "Europe/Brussels"),
      t_ext = as.numeric(data$hourly$temperature_2m)
    )
    df <- df[!is.na(df$timestamp) & !is.na(df$t_ext), ]

    message(sprintf("[Open-Meteo] API: %d points pour %d", nrow(df), year))
    df
  }, error = function(e) {
    warning(sprintf("[Open-Meteo] Erreur API: %s", e$message))
    NULL
  })
}

#' Interpole les temperatures horaires au pas de 15 min
#'
#' @param df_hourly tibble avec colonnes timestamp et t_ext (horaire)
#' @param ts_15min Vecteur de timestamps au pas de 15 min
#' @return Vecteur de temperatures interpolees (meme longueur que ts_15min)
interpolate_temperature_15min <- function(df_hourly, ts_15min) {
  x_hourly <- as.numeric(df_hourly$timestamp)
  y_hourly <- df_hourly$t_ext
  x_target <- as.numeric(ts_15min)

  result <- approx(x_hourly, y_hourly, xout = x_target, rule = 2)$y

  if (any(is.na(result))) {
    result[is.na(result)] <- median(y_hourly, na.rm = TRUE)
    warning(sprintf("[Open-Meteo] %d valeurs interpolees remplacees par la mediane",
                    sum(is.na(result))))
  }

  round(result, 1)
}
