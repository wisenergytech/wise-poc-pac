# =============================================================================
# Analyse du bilan energetique BQ k0001 vs ORES
# =============================================================================
# Contexte :
#   Elec_consumption (table wise.k0001) = conso de TOUTE l'installation technique
#   (PAC + eclairage + auxiliaires), PAS seulement la PAC.
#   Le compteur ORES mesure le meme perimetre (soutirage/injection de l'installation).
#
# Ce script :
#   1. Verifie la synchronisation k0001 vs ORES (test nocturne)
#   2. Reconstitue le PV reel par bilan energetique (pv = pac_kwh - offtake + feedin)
#   3. Compare PV reel vs PV Elia (scaling)
#   4. Separe la conso PAC du talon par heuristique COP
#
# Resultats cles (mai 2026) :
#   - Pas de desynchronisation (ecart nocturne median = 0)
#   - PV reel ~ 7 500 kWh, presque entierement injecte (autocons ~ 0)
#   - PV Elia scale a 65 kWc surestime x2 ; equivalent reel ~ 30 kWc en avril
#   - Ratio PV reel/Elia varie de 0.08 (jan) a 0.65 (avr) : mise en service progressive
#   - PAC pure (COP>0 - talon) = 68% de Elec_consumption, talon ~ 2 kW
#   - Puissance PAC : mediane 3 kW, P95 12.8 kW, max 20 kW (confirme PAC 20 kW)
# =============================================================================

library(dplyr)
library(readr)

# --- Chargement ---
df <- read_csv("inst/extdata/bq_k0001_elia.csv", show_col_types = FALSE)
df$timestamp <- as.POSIXct(df$timestamp, tz = "Europe/Brussels")
df$hour <- as.integer(format(df$timestamp, "%H"))

cat("=== STRUCTURE ===\n")
cat(sprintf("Lignes: %d | Periode: %s -> %s\n", nrow(df),
  format(min(df$timestamp), "%Y-%m-%d"), format(max(df$timestamp), "%Y-%m-%d")))
cat(sprintf("Colonnes: %s\n\n", paste(names(df), collapse = ", ")))

# =============================================================================
# 1. TEST DE SYNCHRONISATION (nuit: PV = 0, donc pac_kwh devrait = offtake - feedin)
# =============================================================================
cat("=== 1. SYNCHRONISATION NOCTURNE (22h-5h) ===\n")
df$pv_reel_brut <- df$pac_kwh - df$offtake_kwh + df$feedin_kwh
night <- df %>% filter(hour >= 22 | hour <= 5)

cat(sprintf("Pas nocturnes: %d\n", nrow(night)))
cat(sprintf("Ecart (pac_kwh - offtake + feedin) devrait = 0 la nuit:\n"))
cat(sprintf("  median: %.4f kWh\n", median(night$pv_reel_brut, na.rm = TRUE)))
cat(sprintf("  mean:   %.4f kWh\n", mean(night$pv_reel_brut, na.rm = TRUE)))
cat(sprintf("  |ecart| > 0.01 kWh: %d / %d (%.1f%%)\n",
  sum(abs(night$pv_reel_brut) > 0.01, na.rm = TRUE), nrow(night),
  100 * sum(abs(night$pv_reel_brut) > 0.01, na.rm = TRUE) / nrow(night)))

# Cross-correlation a differents lags
night_clean <- night %>% filter(!is.na(pac_kwh) & !is.na(offtake_kwh))
cors <- sapply(-4:4, function(lag) {
  n <- nrow(night_clean)
  if (lag >= 0) {
    cor(night_clean$pac_kwh[1:(n - lag)], night_clean$offtake_kwh[(1 + lag):n], use = "complete.obs")
  } else {
    cor(night_clean$pac_kwh[(1 - lag):n], night_clean$offtake_kwh[1:(n + lag)], use = "complete.obs")
  }
})
names(cors) <- paste0("lag_", -4:4)
cat("\nCross-correlation pac_kwh vs offtake (nuit, lags en pas de 15 min):\n")
print(round(cors, 4))
cat(sprintf("Meilleur lag: %d\n\n", (-4:4)[which.max(cors)]))

# =============================================================================
# 2. PV REEL RECONSTITUE
# =============================================================================
cat("=== 2. PV REEL RECONSTITUE (bilan energetique) ===\n")

# Filtrer outliers ORES (spikes de compteur)
df_clean <- df %>% filter(offtake_kwh < 50 & feedin_kwh < 50)
cat(sprintf("Outliers ORES exclus: %d lignes\n", nrow(df) - nrow(df_clean)))

df_clean$pv_reel <- pmax(0, df_clean$pac_kwh - df_clean$offtake_kwh + df_clean$feedin_kwh)

cat(sprintf("\nPV reel total:       %.0f kWh\n", sum(df_clean$pv_reel, na.rm = TRUE)))
cat(sprintf("PV Elia total:       %.0f kWh\n", sum(df_clean$pv_kwh, na.rm = TRUE)))
cat(sprintf("Feedin total:        %.0f kWh\n", sum(df_clean$feedin_kwh, na.rm = TRUE)))
cat(sprintf("PV autocons (reel - feedin): %.1f kWh (~ 0%%!)\n\n",
  sum(df_clean$pv_reel, na.rm = TRUE) - sum(df_clean$feedin_kwh, na.rm = TRUE)))

# =============================================================================
# 3. COMPARAISON PV REEL vs ELIA PAR MOIS
# =============================================================================
cat("=== 3. RATIO PV REEL / PV ELIA PAR MOIS ===\n")
df_clean$month <- format(df_clean$timestamp, "%Y-%m")
monthly <- df_clean %>%
  group_by(month) %>%
  summarise(
    pv_reel = sum(pv_reel, na.rm = TRUE),
    pv_elia = sum(pv_kwh, na.rm = TRUE),
    feedin = sum(feedin_kwh, na.rm = TRUE),
    ratio = pv_reel / pv_elia,
    kwc_equiv = 65 * pv_reel / pv_elia,
    .groups = "drop"
  )
print(monthly)

n_days <- as.numeric(difftime(max(df_clean$timestamp), min(df_clean$timestamp), units = "days"))
cat(sprintf("\nPeriode: %.0f jours\n", n_days))
cat(sprintf("Ratio global: %.3f -> kWc effectif ~ %.0f (vs 65 utilise)\n",
  sum(df_clean$pv_reel) / sum(df_clean$pv_kwh),
  65 * sum(df_clean$pv_reel) / sum(df_clean$pv_kwh)))
cat("NB: ratio croissant = mise en service progressive des panneaux PV\n\n")

# =============================================================================
# 4. SEPARATION PAC / TALON PAR HEURISTIQUE COP
# =============================================================================
cat("=== 4. HEURISTIQUE COP : SEPARATION PAC vs TALON ===\n")

pac_off <- df_clean %>% filter(!is.na(cop) & cop == 0)
pac_on <- df_clean %>% filter(!is.na(cop) & cop > 0 & cop < 7)
cat(sprintf("Pas COP=0 (PAC off): %d (%.1f%%)\n", nrow(pac_off), 100 * nrow(pac_off) / nrow(df_clean)))
cat(sprintf("Pas COP>0 (PAC on):  %d (%.1f%%)\n\n", nrow(pac_on), 100 * nrow(pac_on) / nrow(df_clean)))

# Talon par tranche horaire
talon_by_hour <- pac_off %>%
  group_by(hour) %>%
  summarise(
    n = n(),
    median_kwh = median(pac_kwh, na.rm = TRUE),
    mean_kwh = mean(pac_kwh, na.rm = TRUE),
    .groups = "drop"
  )
cat("Talon (conso quand COP=0) par heure:\n")
print(talon_by_hour)

# Estimation conso PAC pure
talon_lookup <- pac_off %>%
  group_by(hour) %>%
  summarise(talon_kwh = median(pac_kwh, na.rm = TRUE), .groups = "drop")

df_est <- df_clean %>%
  left_join(talon_lookup, by = "hour") %>%
  mutate(
    pac_pure_kwh = ifelse(!is.na(cop) & cop > 0,
      pmax(0, pac_kwh - talon_kwh), 0)
  )

pac_pure_total <- sum(df_est$pac_pure_kwh, na.rm = TRUE)
elec_total <- sum(df_clean$pac_kwh, na.rm = TRUE)

cat(sprintf("\n--- Resultats ---\n"))
cat(sprintf("Conso totale installation: %.0f kWh\n", elec_total))
cat(sprintf("Conso PAC pure estimee:    %.0f kWh (%.1f%%)\n", pac_pure_total, 100 * pac_pure_total / elec_total))
cat(sprintf("Talon (hors PAC):          %.0f kWh (%.1f%%)\n",
  elec_total - pac_pure_total, 100 * (1 - pac_pure_total / elec_total)))
cat(sprintf("Talon moyen:               %.0f W\n", mean(talon_lookup$talon_kwh) * 4000))

# Puissance PAC
pac_pure_on <- df_est %>% filter(pac_pure_kwh > 0)
cat(sprintf("\nPuissance PAC pure (quand active):\n"))
cat(sprintf("  moyenne: %.1f kW\n", mean(pac_pure_on$pac_pure_kwh) * 4))
cat(sprintf("  mediane: %.1f kW\n", median(pac_pure_on$pac_pure_kwh) * 4))
cat(sprintf("  P95:     %.1f kW\n", quantile(pac_pure_on$pac_pure_kwh, 0.95) * 4))
cat(sprintf("  max:     %.1f kW\n", max(pac_pure_on$pac_pure_kwh) * 4))

# =============================================================================
# 5. PART PAC CORRIGEE
# =============================================================================
cat("\n=== 5. IMPACT SUR LE KPI 'PART PAC' ===\n")

# Ancien calcul (app actuelle)
ct_elia <- sum(df_clean$offtake_kwh) + sum(df_clean$pv_kwh) - sum(df_clean$feedin_kwh)
cat(sprintf("Ancien: part_pac = pac_kwh / (offtake + pv_elia - feedin) = %.0f / %.0f = %.1f%%\n",
  elec_total, ct_elia, 100 * elec_total / ct_elia))

# Avec PV reel (par construction = 100%)
ct_reel <- sum(df_clean$offtake_kwh) + sum(df_clean$pv_reel) - sum(df_clean$feedin_kwh)
cat(sprintf("Avec PV reel: conso_totale = %.0f kWh (= pac_kwh par construction)\n", ct_reel))

# Correct: PAC pure / conso totale
cat(sprintf("Correct: part_pac_pure / conso_totale = %.0f / %.0f = %.1f%%\n",
  pac_pure_total, elec_total, 100 * pac_pure_total / elec_total))

cat("\n=== DONE ===\n")
