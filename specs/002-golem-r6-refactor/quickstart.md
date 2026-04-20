# Quickstart: Golem + R6 Architecture

## Lancer l'application

```r
# Apres migration complete
golem::run_app()

# Pendant la migration (fallback)
shiny::runApp("app.R")
```

## Utiliser la logique metier sans Shiny

```r
# Charger les classes R6 (pas besoin de library(shiny))
devtools::load_all()

# Creer les parametres
params <- SimulationParams$new(
  p_pac_kw = 60, cop_nominal = 3.5,
  volume_ballon_l = 36100,
  type_contrat = "dynamique",
  baseline_mode = "ingenieur"
)

# Creer et lancer une simulation
sim <- Simulation$new(params)
sim$load_data("demo", date_start = "2025-06-01", date_end = "2025-08-31")
sim$run_baseline()
sim$run_optimization("lp")

# Lire les resultats
sim$get_kpi()
# $facture_baseline  [1] 2118.3
# $facture_opti      [1] 1746.7
# $gain_eur          [1] 371.6
# $autoconso_opti    [1] 79.7

# Exporter
sim$export_csv("results.csv")
```

## Lancer les tests

```r
devtools::test()
# ou
testthat::test_dir("tests/testthat")
```

## Structure des fichiers R6

| Fichier | Classe | Role |
|---|---|---|
| R6_params.R | SimulationParams | Parametres d'entree |
| R6_thermal_model.R | ThermalModel | COP, dynamique thermique |
| R6_baseline.R | Baseline | 5 modes de baseline |
| R6_optimizer.R | BaseOptimizer, Smart/MILP/LP/QPOptimizer | 4 modes d'optimisation |
| R6_data_generator.R | DataGenerator | Donnees synthetiques |
| R6_data_provider.R | DataProvider | Belpex, Open-Meteo, CO2 |
| R6_kpi.R | KPICalculator | Metriques et KPI |
| R6_simulation.R | Simulation | Orchestration workflow |

## Ajouter un nouvel onglet

```r
# 1. Creer le module
golem::add_module(name = "mon_onglet")

# 2. Editer R/mod_mon_onglet.R
mod_mon_onglet_ui <- function(id) {
  ns <- NS(id)
  tagList(plotlyOutput(ns("mon_plot")))
}

mod_mon_onglet_server <- function(id, sim_state) {
  moduleServer(id, function(input, output, session) {
    output$mon_plot <- renderPlotly({
      req(sim_state())
      sim <- sim_state()
      # Utiliser sim$get_results(), sim$get_kpi(), etc.
    })
  })
}

# 3. Ajouter dans app_ui.R et app_server.R
# Pas besoin de modifier les classes R6
```
