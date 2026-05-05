# Quickstart: Import à deux CSV

**Feature**: 006-dual-csv-import
**Branch**: `006-dual-csv-import`

## Prérequis

- R 4.5+ avec les packages existants (golem, shiny, bslib, dplyr, lubridate)
- Aucun nouveau package à installer

## Fichiers de test

Les CSV de test sont dans `inst/extdata/` :
- `bq_k0001_raw.csv` — CSV installation (monitoring PAC Profondeville, 5-min)
- `bq_k0001_ores_raw.csv` — CSV ORES (compteur réseau Profondeville, 5-min)

## Tester manuellement

```r
# Lancer l'app
golem::run_app()

# Dans le sidebar :
# 1. Uploader bq_k0001_raw.csv dans "Données installation"
# 2. Uploader bq_k0001_ores_raw.csv dans "Données compteur ORES"
# 3. Vérifier le rapport d'import :
#    - ~13 000 quarts d'heure
#    - PAC détectée par heuristique COP (P95 ~13 kW, talon ~2 kW)
#    - PV instable (mise en service progressive)
#    - Diagnostic périmètre : OK
```

## Tester les fonctions unitairement

```r
# Parser installation
source("R/fct_csv_parser.R")
df_install <- parse_installation_csv("inst/extdata/bq_k0001_raw.csv")

# Parser ORES
df_ores <- parse_ores_csv("inst/extdata/bq_k0001_ores_raw.csv")

# Jointure
df_joined <- join_sources(df_install, df_ores)

# Détection PAC
source("R/fct_pac_detection.R")
result <- detect_pac_consumption(df_joined)
# result$pac_kwh, result$method, result$p95_kw, result$talon_w

# PV reconstitué
source("R/fct_pv_reconstruction.R")
pv <- reconstruct_pv(df_joined)
stability <- assess_pv_stability(pv$pv_reel, pv$timestamp)
```

## Résultats attendus (Profondeville)

| Métrique | Valeur attendue |
|----------|-----------------|
| Points joints | ~13 000 qt |
| Période | 2025-11-20 → 2026-04-30 |
| Méthode PAC | Heuristique COP (cas c) |
| P95 PAC | ~12-13 kW |
| Talon | ~2 kW (~500 W médiane) |
| PV total reconstitué | ~7 500 kWh |
| PV stable ? | Non (CV ~80%) |
| Autoconsommation PV | ~0% |

## Architecture

```
mod_sidebar.R (UI wiring)
    ↓ appelle
fct_csv_parser.R (parse + join)
    ↓ puis
fct_pac_detection.R (cascade détection)
    ↓ puis
fct_pv_reconstruction.R (bilan + stabilité)
    ↓ puis
fct_data_diagnostic.R (validation, déjà existant)
    ↓ produit
Dataframe simulation-ready → pipeline existant
```
