# Implementation Plan: CSV Column Mapping dynamique

**Branch**: `010-csv-column-mapping` | **Date**: 2026-05-26 | **Spec**: `specs/010-csv-column-mapping/spec.md`
**Input**: Feature specification from `specs/010-csv-column-mapping/spec.md`

## Summary

Replace the rigid CSV import (hardcoded column names) with a dynamic column mapping UI. Users select which CSV column maps to each field (timestamp, PV, offtake, feedin, PAC 1, PAC 2, temperatures). Pre-suggestion via keyword matching on column names. Data explorer dropdowns populated dynamically from actual CSV columns. Fully backward-compatible.

## Technical Context

**Language/Version**: R 4.5+ (Shiny)
**Primary Dependencies**: golem, shiny, bslib, dplyr, readr (all existing, no new deps)
**Storage**: N/A (in-memory, CSV files)
**Testing**: testthat (pure function tests for column matching logic)
**Target Platform**: Linux server (Docker, Cloud Run)
**Project Type**: Web application (Shiny)
**Performance Goals**: Mapping pre-fill < 2s for 10K-row CSV (SC-004)
**Constraints**: Retrocompatible with existing CSV format. Demo mode unchanged.
**Scale/Scope**: POC — UI refactor of CSV import flow

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Technology Stack | PASS (VII override) | R Shiny, no new deps |
| II. Server-Side Security | PASS | CSV loaded server-side, no secrets |
| III. Authentication Guard | PASS (IX override) | POC, no auth |
| IV. Observability | PASS | message() for import diagnostics (already exists) |
| V. Documentation Artifacts | IN PROGRESS | spec done, plan (this), research/tasks to follow |
| VI. Simplicity | PASS | Keyword matching is simple rules, no ML/NLP |
| VII-XI | PASS | No new packages, separation of concerns maintained |

No violations.

## Project Structure

### Documentation

```text
specs/010-csv-column-mapping/
├── spec.md
├── plan.md              # This file
├── research.md
├── data-model.md
├── quickstart.md
├── business-logic.md
└── tasks.md             # Via /speckit-tasks
```

### Source Code

```text
R/
├── fct_csv_mapping.R        # NEW — column matching logic (pure function, no Shiny)
├── mod_sidebar.R            # MODIFY — replace hardcoded CSV handling with mapping UI
├── mod_comparaison.R        # MODIFY — dynamic dropdown population from CSV columns
├── R6_data_generator.R      # MODIFY — apply column mapping before prepare_df
```

**Structure Decision**: One new pure function file + modifications to 3 existing files. Column matching logic isolated in `fct_csv_mapping.R` (testable without Shiny, per Constitution XI).
