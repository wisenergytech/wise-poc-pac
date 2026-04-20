# CLAUDE.md

## Project context

This is a Wise project. All development must follow the Wise constitution and guidelines.

## Key files to read before any work

- `.specify/memory/constitution.md` — **Read this first**. Contains non-negotiable principles (security, auth, architecture, documentation).
- `docs/guidelines/` — Stack-specific conventions (framework, deployment, auth patterns, charts).

## Architecture rules

- All external API calls go through server-side code (never from the browser).
- Authentication uses Supabase Auth with dual verification (client + server).
- API secrets must never be exposed to the browser, logged, or hardcoded.
- HTTPS is mandatory for all external calls.

## Workflow

Use Speckit for all feature development:
1. `/speckit-specify` — generate spec + business logic
2. `/speckit-plan` — generate plan + flows + ADRs
3. `/speckit-tasks` — generate tasks
4. `/speckit-implement` — implement

## Dependencies

- When adding a new npm package, run `npm install <package>` (updates `package.json` automatically).
- When adding a new Python package, add it to `requirements.txt`.
- Never add unused dependencies.

## Environment

- All env vars are in `.env` (loaded automatically by the Makefile).
- Nuxt projects: use `NUXT_*` / `NUXT_PUBLIC_*` prefixes for runtimeConfig vars. Never use quotes in `.env` values.
- Run `make help` to see available targets.
- Run `make check-env` to verify all required variables are set.

## Deployment

First-time setup (run once per project):
```
make setup-gcp        # enable GCP APIs + create Artifact Registry repo
make secrets-create   # push secrets from .env to Secret Manager
```

Then deploy:
```
make deploy           # check-env → build (Cloud Build) → deploy (Cloud Run)
```

Images are stored in Artifact Registry (`<region>-docker.pkg.dev/<project>/<service>/app`).
Secrets are read from `.env` by `make secrets-create` — no interactive prompts.

## Standards sync

This project was initialized from `wise-standards`. To update standards:
```
make sync-standards
```
This updates guidelines, templates, CSS theme, CLAUDE.md, and constitution base (Part 1) without touching project code or constitution Part 2. Requires `WISE_STANDARDS_PATH` in `.env`.

## Active Technologies
- R 4.5+ (Shiny) + ompr 1.0.4, ompr.roi 1.0.2, ROI.plugin.glpk 1.0-0 (nouveaux) + stack existante (shiny, bslib, dplyr, plotly, DT) (001-milp-optimizer)
- N/A (in-memory simulation) (001-milp-optimizer)
- R 4.5+ (Shiny) + golem >= 0.4.0, R6 >= 2.5.0, shiny, bslib, dplyr, plotly, DT, ompr, ompr.roi, ROI.plugin.glpk, CVXR, lubridate, httr (002-golem-r6-refactor)
- N/A (in-memory simulation, CSV data files) (002-golem-r6-refactor)

## Recent Changes
- 001-milp-optimizer: Added R 4.5+ (Shiny) + ompr 1.0.4, ompr.roi 1.0.2, ROI.plugin.glpk 1.0-0 (nouveaux) + stack existante (shiny, bslib, dplyr, plotly, DT)
