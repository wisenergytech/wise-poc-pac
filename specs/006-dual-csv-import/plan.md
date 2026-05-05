# Implementation Plan: Import à deux CSV avec détection automatique PAC et PV reconstitué

**Branch**: `006-dual-csv-import` | **Date**: 2026-05-05 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/006-dual-csv-import/spec.md`

## Summary

Remplacer l'upload single-CSV par deux uploads séparés (Installation monitoring + Compteur ORES). L'app joint les sources, détecte automatiquement la consommation PAC (via sous-compteurs ou heuristique COP/talon), et reconstitue le PV réel par bilan énergétique. Le diagnostic énergétique (déjà implémenté) valide la cohérence des données.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem, R6, shiny, bslib, dplyr, lubridate, plotly (existants — aucune nouvelle dépendance)
**Storage**: N/A (fichiers CSV uploadés en mémoire, pas de persistance)
**Testing**: testthat (existant, 127 tests)
**Target Platform**: Linux server (Cloud Run)
**Project Type**: Web application (Shiny)
**Performance Goals**: < 10 secondes pour parser et joindre 50 000 lignes par fichier
**Constraints**: Pas de rétrocompatibilité avec l'ancien format single-CSV. Mode Démo inchangé.
**Scale/Scope**: 1 utilisateur à la fois (POC), fichiers de 10k-100k lignes

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Technology Stack | PASS (override VII) | R Shiny, pas de nouvelle dépendance |
| II. Server-Side Security | PASS | Pas de secrets, données uploadées localement |
| III. Authentication Guard | N/A | POC interne (IX) |
| IV. Observability | PASS | Messages de diagnostic dans le rapport d'import |
| V. Documentation Artifacts | PASS | spec.md, plan.md, research.md, data-model.md, tasks.md |
| VI. Simplicity | PASS | Cascade de détection PAC = logique directe, pas d'abstraction superflue |
| VII. Stack Override | PASS | R Shiny confirmé |
| VIII. Project Structure | PASS | R6 classes pour la logique, mod_sidebar pour le wiring |
| IX. Security Adaptations | PASS | Pas de secrets impliqués |
| X. R Dependency Management | PASS | Aucune nouvelle dépendance |
| XI. Separation of Concerns | PASS | Parsing/jointure/détection dans fct_*.R ou R6, mod_sidebar = wiring UI uniquement |

No violations. No Complexity Tracking needed.

## Project Structure

### Documentation (this feature)

```text
specs/006-dual-csv-import/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (speckit-tasks)
```

### Source Code (repository root)

```text
R/
├── fct_csv_parser.R          # NEW: parse_installation_csv(), parse_ores_csv(), join_sources()
├── fct_pac_detection.R       # NEW: detect_pac_consumption() (cascade GSHP/ASHP → sous-compteur → COP/talon)
├── fct_pv_reconstruction.R   # NEW: reconstruct_pv(), assess_pv_stability()
├── fct_data_diagnostic.R     # EXISTING: diagnose_energy_perimeter() (already implemented)
├── R6_data_generator.R       # MODIFIED: adapt prepare_df() to new dual-CSV input
├── mod_sidebar.R             # MODIFIED: two fileInputs, new import pipeline, PV source selector

tests/testthat/
├── test-fct_csv_parser.R     # NEW: unit tests for parsing and joining
├── test-fct_pac_detection.R  # NEW: unit tests for PAC detection cascade
├── test-fct_pv_reconstruction.R # NEW: unit tests for PV reconstruction

inst/extdata/
├── bq_k0001_raw.csv          # EXISTING: test data (installation)
├── bq_k0001_ores_raw.csv     # EXISTING: test data (ORES)
```

**Structure Decision**: Three new `fct_*.R` files for business logic (Principle XI), modifications to `mod_sidebar.R` for UI wiring, and `R6_data_generator.R` for integration with the simulation pipeline. No new R6 class needed — the parsing is stateless and fits pure functions.
