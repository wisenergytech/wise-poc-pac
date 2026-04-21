# =============================================================================
# Module Belpex — Prix Day-Ahead via ENTSO-E Transparency Platform
# =============================================================================
# Priorite : 1) CSV locaux  2) API ENTSO-E  3) Fallback simulation
# =============================================================================

library(httr)
library(xml2)
library(dplyr)
library(readr)
library(lubridate)

ENTSOE_BASE_URL <- "https://web-api.tp.entsoe.eu/api"
ENTSOE_DOMAIN_BE <- "10YBE----------2"

# -----------------------------------------------------------------------------
# 1. Charger les prix depuis les CSV historiques locaux
# -----------------------------------------------------------------------------
load_local_belpex <- function(data_dir = "data") {
  files <- list.files(data_dir, pattern = "belpex_historical_.*\\.csv$", full.names = TRUE)
  if (length(files) == 0) return(NULL)

  dfs <- lapply(files, function(f) {
    # Lire datetime en texte brut pour eviter l'auto-parsing de readr
    df <- read_csv(f, show_col_types = FALSE, col_types = cols(datetime = col_character()))
    names(df) <- c("datetime_raw", "price_eur_mwh")
    df %>% mutate(
      # Supprimer le suffixe timezone (+00:00) avant parsing
      datetime_clean = gsub("Z$", "", gsub("[+-]\\d{2}:\\d{2}$", "", datetime_raw)),
      datetime = ymd_hms(datetime_clean, tz = "UTC")
    ) %>%
    select(datetime, price_eur_mwh) %>%
    filter(!is.na(datetime))
  })

  bind_rows(dfs) %>%
    distinct(datetime, .keep_all = TRUE) %>%
    arrange(datetime)
}

# -----------------------------------------------------------------------------
# 2. Appeler l'API ENTSO-E pour une periode donnee (max 365 jours)
# -----------------------------------------------------------------------------
fetch_entsoe_prices <- function(api_key, start_date, end_date) {
  if (is.null(api_key) || nchar(api_key) == 0) return(NULL)

  # Format YYYYMMDDHHMM
  fmt <- function(d) format(d, "%Y%m%d%H%M")

  resp <- tryCatch({
    GET(
      ENTSOE_BASE_URL,
      query = list(
        securityToken = api_key,
        documentType = "A44",
        in_Domain = ENTSOE_DOMAIN_BE,
        out_Domain = ENTSOE_DOMAIN_BE,
        periodStart = fmt(start_date),
        periodEnd = fmt(end_date)
      ),
      timeout(30)
    )
  }, error = function(e) {
    message("[ENTSO-E] Erreur de connexion : ", e$message)
    return(NULL)
  })

  if (is.null(resp)) return(NULL)
  if (status_code(resp) != 200) {
    message("[ENTSO-E] Erreur HTTP ", status_code(resp))
    return(NULL)
  }

  parse_entsoe_xml(content(resp, as = "text", encoding = "UTF-8"))
}

# -----------------------------------------------------------------------------
# 3. Parser le XML ENTSO-E
# -----------------------------------------------------------------------------
parse_entsoe_xml <- function(xml_text) {
  doc <- tryCatch(read_xml(xml_text), error = function(e) NULL)
  if (is.null(doc)) return(NULL)

  ns <- xml_ns(doc)
  # Le namespace principal est generalement le premier
  ns_prefix <- names(ns)[1]

  time_series <- xml_find_all(doc, paste0(".//", ns_prefix, ":TimeSeries"))
  if (length(time_series) == 0) return(NULL)

  rows <- list()
  for (ts in time_series) {
    periods <- xml_find_all(ts, paste0(".//", ns_prefix, ":Period"))
    for (period in periods) {
      start_node <- xml_find_first(period, paste0(".//", ns_prefix, ":timeInterval/", ns_prefix, ":start"))
      resolution_node <- xml_find_first(period, paste0(".//", ns_prefix, ":resolution"))

      if (is.na(start_node) || is.na(resolution_node)) next

      start_time <- ymd_hms(xml_text(start_node), tz = "UTC")
      resolution <- xml_text(resolution_node)

      # Determiner le pas de temps
      step_minutes <- if (resolution == "PT15M") 15L else 60L

      points <- xml_find_all(period, paste0(".//", ns_prefix, ":Point"))
      for (pt in points) {
        pos <- as.integer(xml_text(xml_find_first(pt, paste0(ns_prefix, ":position"))))
        price <- as.numeric(xml_text(xml_find_first(pt, paste0(ns_prefix, ":price.amount"))))
        dt <- start_time + minutes((pos - 1L) * step_minutes)
        rows <- c(rows, list(tibble(datetime = dt, price_eur_mwh = price)))
      }
    }
  }

  if (length(rows) == 0) return(NULL)
  bind_rows(rows) %>% distinct(datetime, .keep_all = TRUE) %>% arrange(datetime)
}

# -----------------------------------------------------------------------------
# 4. Fetch avec chunking (max 365 jours par requete)
# -----------------------------------------------------------------------------
fetch_entsoe_chunked <- function(api_key, start_date, end_date) {
  chunks <- list()
  current <- start_date
  while (current < end_date) {
    chunk_end <- min(current + days(364), end_date)
    message(sprintf("[ENTSO-E] Fetch %s -> %s", format(current, "%Y-%m-%d"), format(chunk_end, "%Y-%m-%d")))
    chunk <- fetch_entsoe_prices(api_key, current, chunk_end)
    if (!is.null(chunk)) chunks <- c(chunks, list(chunk))
    current <- chunk_end
    Sys.sleep(0.5)  # Rate limiting
  }

  if (length(chunks) == 0) return(NULL)
  bind_rows(chunks) %>% distinct(datetime, .keep_all = TRUE) %>% arrange(datetime)
}

# -----------------------------------------------------------------------------
# 5. Convertir les prix horaires en quart-horaires (repeter 4x si horaire)
# -----------------------------------------------------------------------------
to_quarter_hourly <- function(df) {
  if (is.null(df) || nrow(df) < 2) return(df)

  # Detecter la resolution
  median_diff <- median(diff(as.numeric(df$datetime)), na.rm = TRUE)

  if (median_diff > 1800) {
    # Donnees horaires -> repeter 4x
    df_qt <- df %>%
      rowwise() %>%
      do({
        row <- .
        tibble(
          datetime = row$datetime + minutes(c(0, 15, 30, 45)),
          price_eur_mwh = rep(row$price_eur_mwh, 4)
        )
      }) %>%
      ungroup()
    return(df_qt)
  }

  # Deja quart-horaire
  df
}

# -----------------------------------------------------------------------------
# 6. Fonction principale : charger les prix Belpex
# -----------------------------------------------------------------------------
load_belpex_prices <- function(start_date, end_date, api_key = NULL, data_dir = "data") {
  source_used <- "none"
  local_filtered <- NULL

  # 1) Essayer les CSV locaux
  local <- load_local_belpex(data_dir)
  if (!is.null(local)) {
    local_filtered <- local %>% filter(datetime >= start_date, datetime <= end_date)
    if (nrow(local_filtered) > 0) {
      source_used <- "local"
      message(sprintf("[Belpex] %d points charges depuis les CSV locaux", nrow(local_filtered)))

      # Verifier si on couvre toute la periode
      coverage <- as.numeric(difftime(max(local_filtered$datetime), min(local_filtered$datetime), units = "days"))
      requested <- as.numeric(difftime(end_date, start_date, units = "days"))

      if (coverage >= requested * 0.9) {
        result <- to_quarter_hourly(local_filtered)
        return(list(data = result, source = source_used))
      }
    }
  }

  # 2) Completer avec l'API
  if (!is.null(api_key) && nchar(api_key) > 0) {
    api_data <- fetch_entsoe_chunked(api_key, start_date, end_date)
    if (!is.null(api_data) && nrow(api_data) > 0) {
      source_used <- if (source_used == "local") "local+api" else "api"
      message(sprintf("[Belpex] %d points charges depuis l'API ENTSO-E", nrow(api_data)))

      combined <- bind_rows(if (!is.null(local_filtered)) local_filtered else tibble(), api_data) %>%
        distinct(datetime, .keep_all = TRUE) %>%
        arrange(datetime) %>%
        filter(datetime >= start_date, datetime <= end_date)

      result <- to_quarter_hourly(combined)
      return(list(data = result, source = source_used))
    }
  }

  # 3) Retourner ce qu'on a (local partiel ou NULL)
  if (!is.null(local_filtered) && nrow(local_filtered) > 0) {
    result <- to_quarter_hourly(local_filtered)
    return(list(data = result, source = source_used))
  }

  list(data = NULL, source = "none")
}

# Operateur null-coalesce
`%||%` <- function(x, y) if (is.null(x)) y else x
