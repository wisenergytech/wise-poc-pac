#!/usr/bin/env Rscript
# ============================================================
# Script de correction des CSV Belpex historiques
# ============================================================
# Probleme : le CSV 2024 contient des dates avec suffixe +00:00.
# read_csv() auto-parse ces dates et les convertit en heure locale,
# ce qui decale les timestamps d'1h en hiver (CET) et 2h en ete (CEST).
#
# Solution :
# 1. Lire la colonne datetime en texte brut (col_character)
# 2. Supprimer le suffixe timezone (+00:00 ou -00:00)
# 3. Parser en UTC avec ymd_hms()
# 4. Ecrire en format propre sans suffixe timezone
#
# Usage : Rscript scripts/correct_belpex_csv.R
# Entree : data/entsoe_prices_*.csv
# Sortie : ecrase les fichiers originaux avec la version corrigee
# ============================================================

library(readr)
library(dplyr)
library(lubridate)

correct_belpex_csv <- function(input_file) {
  cat("Processing:", input_file, "\n")

  # Lire datetime en texte brut pour eviter l'auto-parsing
  df <- read_csv(input_file, show_col_types = FALSE,
                 col_types = cols(datetime = col_character()))
  names(df) <- c("datetime_raw", "price_eur_mwh")
  cat("  Rows lues:", nrow(df), "\n")

  # Nettoyer le suffixe timezone (+00:00, -01:00, etc.)
  df <- df %>%
    mutate(
      datetime_clean = gsub("[+-]\\d{2}:\\d{2}$", "", datetime_raw),
      datetime = ymd_hms(datetime_clean, tz = "UTC")
    ) %>%
    filter(!is.na(datetime)) %>%
    select(datetime, price_eur_mwh) %>%
    distinct(datetime, .keep_all = TRUE) %>%
    arrange(datetime)

  cat("  Rows valides:", nrow(df), "\n")
  cat("  Range:", format(min(df$datetime)), "->", format(max(df$datetime)), "\n")

  # Ecrire en format propre (ISO 8601 sans timezone suffix)
  write_csv(df, input_file)
  cat("  Ecrit:", input_file, "\n\n")

  invisible(df)
}

# Trouver et corriger tous les CSV Belpex
files <- list.files("data", pattern = "entsoe_prices_.*\\.csv$", full.names = TRUE)
if (length(files) == 0) stop("Aucun fichier entsoe_prices_*.csv trouve dans data/")

cat("=== Correction des CSV Belpex ===\n\n")
dfs <- lapply(files, correct_belpex_csv)

# Verification finale
combined <- bind_rows(dfs) %>%
  distinct(datetime, .keep_all = TRUE) %>%
  arrange(datetime)

cat("=== RESULTAT FINAL ===\n")
cat("Total rows:", nrow(combined), "\n")
cat("Range:", format(min(combined$datetime)), "->", format(max(combined$datetime)), "\n")
cat("NAs:", sum(is.na(combined$datetime)), "\n")

# Verifier les trous > 1.5h
diffs <- diff(as.numeric(combined$datetime))
gaps <- which(diffs > 3600 * 1.5)
cat("Gaps > 1.5h:", length(gaps), "\n")
if (length(gaps) > 0 && length(gaps) <= 20) {
  for (g in gaps) {
    cat("  ", format(combined$datetime[g]), "->", format(combined$datetime[g + 1]),
        "(", round(diffs[g] / 3600, 1), "h)\n")
  }
}
cat("\nDone.\n")
