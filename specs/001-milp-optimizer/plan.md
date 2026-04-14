# Implementation Plan: MILP Optimizer Mode

**Branch**: `001-milp-optimizer` | **Date**: 2026-04-14 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-milp-optimizer/spec.md`

## Summary

Ajouter un mode d'optimisation MILP (Mixed Integer Linear Programming) base sur ompr + GLPK en complement des algorithmes rule-based existants. L'utilisateur choisit entre deux approches (Rule-based vs Optimiseur) via un selecteur de premier niveau dans le sidebar. L'optimiseur resout jour par jour un probleme MILP qui minimise le cout net en respectant les contraintes physiques et de confort. Les resultats sont affiches dans les memes graphiques et KPIs que les modes rule-based pour comparaison directe.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: ompr 1.0.4, ompr.roi 1.0.2, ROI.plugin.glpk 1.0-0 (nouveaux) + stack existante (shiny, bslib, dplyr, plotly, DT)
**Storage**: N/A (in-memory simulation)
**Testing**: Tests manuels via l'app + script de validation automatique
**Target Platform**: Desktop browser (localhost)
**Project Type**: R Shiny single-file app (POC)
**Performance Goals**: Resolution MILP < 30s pour 180 jours (17 280 qt)
**Constraints**: Solveur GLPK (open-source), resolution jour par jour pour performance
**Scale/Scope**: 1 utilisateur simultane (POC local)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Technology Stack | PASS | R Shiny autorise par Principe VII (Part 2). ompr/ROI sont des packages R CRAN standard. |
| II. Server-Side Security | PASS | Pas de secrets dans l'optimiseur. Prix Belpex charges depuis .env existant. |
| III. Authentication Guard | PASS (waived) | POC interne, pas d'auth (Principe IX). |
| IV. Observability | PASS | Messages console pour debug (existant). Temps de solve loggue. |
| V. Documentation Artifacts | PASS | spec.md, plan.md, research.md, data-model.md generes par speckit. |
| VI. Simplicity | PASS | Un seul nouveau fichier R (optimizer.R). Pas d'abstraction prematuree. |
| VII. Stack Override | PASS | ompr s'integre naturellement dans l'ecosysteme R. |
| X. Dependency Management | PENDING | renv::snapshot() requis apres installation des 3 nouveaux packages. |

## Project Structure

### Documentation (this feature)

```text
specs/001-milp-optimizer/
├── spec.md              # Specification
├── plan.md              # This file
├── research.md          # Phase 0: solver choice, performance, formulation
├── data-model.md        # Phase 1: OptimizationResult, OptimizationDay
├── quickstart.md        # Phase 1: how to use the optimizer
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2: implementation tasks (next step)
```

### Source Code (repository root)

```text
app.R                         # Modified: UI (approach selector), server (optimizer dispatch)
R/
├── belpex.R                  # Existing (no changes)
└── optimizer.R               # NEW: run_optimization_milp() function
```

**Structure Decision**: Un seul nouveau fichier `R/optimizer.R` contient toute la logique MILP. L'integration dans `app.R` se fait par modification du sidebar (ajout selecteur d'approche) et du server (dispatch vers `run_optimization_milp()` quand "Optimiseur" est selectionne). Pas de refactoring des modes rule-based existants.

## Complexity Tracking

> No violations. All principles satisfied.
