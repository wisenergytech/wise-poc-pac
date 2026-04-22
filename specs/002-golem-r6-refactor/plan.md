# Implementation Plan: Golem + R6 OOP Architecture

**Branch**: `002-golem-r6-refactor` | **Date**: 2026-04-19 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-golem-r6-refactor/spec.md`

## Summary

Refactoring de l'application Shiny monolithique (app.R, 3130 lignes) en architecture Golem avec classes R6 pour la logique metier. Migration incrementale domaine par domaine, en gardant l'app fonctionnelle a chaque etape. L'ancien app.R coexiste avec le nouveau code jusqu'a validation complete.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem >= 0.4.0, R6 >= 2.5.0, shiny, bslib, dplyr, plotly, DT, ompr, ompr.roi, ROI.plugin.glpk, CVXR, lubridate, httr
**Storage**: N/A (in-memory simulation, CSV data files)
**Testing**: testthat (classes R6 metier uniquement)
**Target Platform**: Linux server (Google Cloud Run, rocker/shiny)
**Project Type**: web-app (Shiny interactive dashboard)
**Performance Goals**: Temps de demarrage < 10s, simulation LP 92j < 5min
**Constraints**: Parite fonctionnelle a +-0.1% avec la version actuelle, migration incrementale
**Scale/Scope**: 1 utilisateur simultane (POC), ~5000 lignes de code total

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|---|---|---|
| I. Technology Stack | OVERRIDE (VII) | R Shiny, pas Streamlit. Justifie dans constitution Part 2. |
| II. Server-Side Security | PASS | Pas de secrets dans le code. Env vars via Sys.getenv(). |
| III. Authentication Guard | OVERRIDE (IX) | POC interne, pas d'auth requise. |
| IV. Observability | PASS | message() pour logs console. |
| V. Documentation Artifacts | PASS | spec.md, plan.md, research.md generes par Speckit. |
| VI. Simplicity | PASS | Pas d'abstraction speculative. Heritage R6 justifie par 4 optimiseurs partageant une interface commune. |
| VII. R Shiny Stack | REQUIRES UPDATE | Golem et R6 ajoutent des dependances. Justifie par la separation des concerns. |
| VIII. Project Structure | REQUIRES UPDATE | Structure Golem remplace la structure actuelle. |
| IX. Security R Shiny | PASS | Inchange. |
| X. R Dependency Management | PASS | renv.lock sera mis a jour. DESCRIPTION sera cree par Golem. |

**Violations requiring justification:**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Ajout de golem comme dependance | Structure standardisee, modules, deploiement | Structure manuelle sans golem = reinventer la roue |
| Ajout de R6 comme dependance | Encapsulation etat, testabilite, heritage optimiseurs | Listes R = pas d'heritage, pas d'encapsulation, pas de methodes |
| Structure Golem vs app.R monolithique | 3130 lignes ingerable, pas de separation concerns | Garder app.R = maintenabilite impossible a terme |

## Project Structure

### Documentation (this feature)

```text
specs/002-golem-r6-refactor/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (by /speckit.tasks)
```

### Source Code (repository root)

```text
# Structure Golem cible
R/
├── app_config.R          # Configuration Golem (golem options)
├── app_server.R          # Server principal (orchestre les modules)
├── app_ui.R              # UI principal (assemble les modules)
├── run_app.R             # Point d'entree golem::run_app()
│
├── mod_sidebar.R         # Module : sidebar parametres
├── mod_energie.R         # Module : onglet Energie
├── mod_finances.R        # Module : onglet Finances
├── mod_details.R         # Module : onglet Details
├── mod_contraintes.R     # Module : onglet Contraintes
├── mod_dimensionnement.R # Module : onglet Dimensionnement
├── mod_status_bar.R      # Module : barre de statut
│
├── R6_simulation.R       # Classe R6 : orchestration simulation
├── R6_params.R           # Classe R6 : parametres simulation
├── R6_thermal_model.R    # Classe R6 : modele thermique (COP, pertes, ECS)
├── R6_baseline.R         # Classe R6 : 5 modes de baseline
├── R6_optimizer.R        # Classe R6 : BaseOptimizer + 4 sous-classes
├── R6_data_generator.R   # Classe R6 : donnees synthetiques
├── R6_data_provider.R    # Classe R6 : Belpex, Open-Meteo, CO2
├── R6_kpi.R              # Classe R6 : calcul KPI et metriques
│
├── fct_helpers.R         # Fonctions utilitaires (calc_cop, pl_layout, etc.)
└── fct_ui_theme.R        # Constantes couleurs, CSS, theme bslib

inst/
├── app/
│   └── www/
│       └── custom.css    # Styles CSS centralises
└── golem-config.yml      # Configuration Golem

tests/
└── testthat/
    ├── test-R6_simulation.R
    ├── test-R6_baseline.R
    ├── test-R6_optimizer.R
    ├── test-R6_kpi.R
    └── test-R6_thermal_model.R

DESCRIPTION               # Package metadata + dependances
NAMESPACE                 # Exports (genere par roxygen2)
app.R                     # LEGACY — garde pendant migration, supprime a la fin
```

**Structure Decision**: Structure Golem standard avec prefixe `mod_` pour les modules Shiny et `R6_` pour les classes metier. Les fonctions utilitaires partagees sont dans `fct_*`. Cette convention est le standard Golem (`golem::add_module()`, `golem::add_fct()`).
