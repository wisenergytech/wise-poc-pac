# wisepocpac

Interactive R Shiny dashboard for simulating and optimizing heat pump (PAC) control strategies with PV self-consumption, battery storage, and dynamic/fixed electricity pricing.

## Features

- **5 baseline modes** — reactive thermostat, programmer, PV surplus, engineer (max self-consumption), proactive
- **3 optimizers** — LP (GLPK), MILP (HiGHS), QP (CVXR/CLARABEL) with overlapping blocks, iterative COP, terminal value
- **Smart optimizer** — selects the best result across all solvers with guard baseline (no negative savings)
- **Battery storage** — charge/discharge optimization with anti-simultaneity constraint
- **Curtailment** — configurable grid injection limiting
- **Synthetic data generation** — realistic PAC + PV profiles with real Belpex prices and Open-Meteo temperatures
- **Constraint verification** — 12 timeseries checks (T bounds, COP range, energy balance, etc.)
- **CO2 impact** — async Elia CO2 intensity data with equivalence metrics

## Architecture

Built with [Golem](https://thinkr-open.github.io/golem/) (production-grade Shiny framework) and [R6](https://r6.r-lib.org/) OOP for business logic separation.

```
app.R                         # Entry point: pkgload::load_all() + run_app()
R/
├── run_app.R                 # golem::with_golem_options()
├── app_ui.R / app_server.R   # Thin wrappers assembling 9 modules
├── mod_*.R                   # Shiny modules (UI only, no business logic)
├── R6_*.R                    # R6 classes (business logic, testable without Shiny)
├── data_*.R                  # Data fetching (Belpex, Open-Meteo, CO2 Elia)
├── optimizer_*.R             # Solver implementations (LP, MILP, QP)
└── fct_*.R                   # Shared utilities and UI theme
```

## Prerequisites

- R >= 4.1.0
- System libraries: `libcurl4-openssl-dev`, `libssl-dev`, `libxml2-dev`, `libglpk-dev`, `libuv1-dev`

## Getting started

```bash
# Install R dependencies
Rscript -e "renv::restore()"

# Create a .env file with API keys
cp .env.example .env  # then fill in your keys

# Run the app
make dev
```

## Make targets

| Target | Description |
|--------|-------------|
| `make dev` | Run the app locally (port 3838) |
| `make test` | Run testthat tests |
| `make snapshot` | Update renv.lock |
| `make document` | Regenerate NAMESPACE and man/ |
| `make docker-build` | Build Docker image |
| `make docker-run` | Run container locally |
| `make deploy` | Build + deploy to GCP Cloud Run |

Run `make help` for the full list.

## Docker

```bash
docker build -t wisepocpac .
docker run --rm -p 3838:3838 --env-file .env wisepocpac
```

## GCP Cloud Run deployment

```bash
# One-time setup
make setup-gcp
make secrets-create

# Deploy
make deploy
```

Requires `PROJECT_ID`, `SERVICE_NAME`, and `REGION` in `.env`.

## Tests

95 unit tests covering R6 business logic classes (thermal model, baselines, optimizers, KPIs, simulation orchestrator).

```bash
make test
```

## License

Proprietary
