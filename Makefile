# ── Wise R Shiny Project (Golem + R6) ─────────────────────────────────────────
SHELL := /bin/bash
-include .env
export

# GCP settings
IMAGE = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(SERVICE_NAME)/app

# Non-secret env vars to inject into Cloud Run.
ENV_VARS = ENTSO-E_API_KEY
# Secret names (stored in Google Secret Manager).
SECRET_NAMES =

# Auto-derive SECRETS (gcloud --set-secrets format) from SECRET_NAMES.
COMMA := ,
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
SECRETS := $(subst $(SPACE),$(COMMA),$(foreach s,$(SECRET_NAMES),$(s)=$(s):latest))

# Required variables (checked by make check-env).
REQUIRED_VARS = PROJECT_ID SERVICE_NAME REGION

# Makefile-only variables (not deployed to Cloud Run).
MAKEFILE_ONLY_VARS = PROJECT_ID SERVICE_NAME REGION WISE_STANDARDS_PATH PORT \
	OPENWEATHERMAP_API_KEY FUSIONSOLAR_URL FUSIONSOLAR_USERNAME FUSIONSOLAR_PASSWORD

PORT ?= 3838

# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help dev test snapshot lint document check-env \
	docker-build docker-run deploy setup-gcp secrets-create \
	check-deploy-coverage sync-standards

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Development ──────────────────────────────────────────────────────────────

dev: ## Run the app locally (default port 3838)
	Rscript -e "pkgload::load_all(export_all=FALSE,helpers=FALSE,attach_testthat=FALSE); options(shiny.port=$(PORT),shiny.launch.browser=TRUE); run_app()"

test: ## Run testthat tests
	Rscript -e "devtools::test()"

snapshot: ## Update renv.lock from current library
	Rscript -e "renv::snapshot(prompt=FALSE)"

lint: ## Run lintr on R/ directory
	Rscript -e "lintr::lint_package()"

document: ## Regenerate NAMESPACE and man/ via roxygen2
	Rscript -e "devtools::document()"

# ── Docker ───────────────────────────────────────────────────────────────────

docker-build: ## Build Docker image locally
	docker build -t wisepocpac .

docker-run: ## Run Docker container locally (port 3838)
	docker run --rm -p $(PORT):3838 --env-file .env wisepocpac

# ── GCP Deployment ───────────────────────────────────────────────────────────

check-env: ## Verify required GCP variables are set
	@missing=""; \
	for var in $(REQUIRED_VARS); do \
		val=$$(eval echo "\$$$$var"); \
		if [ -z "$$val" ]; then missing="$$missing $$var"; fi; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "Error: missing required variables in .env:$$missing"; exit 1; \
	fi; \
	echo "  ✓ All required variables are set"

check-deploy-coverage: ## Verify all .env app vars are covered by ENV_VARS or SECRET_NAMES
	@test -f .env || { echo "Error: .env not found"; exit 1; }
	@orphans=""; \
	for var in $$(grep -oE '^[A-Z_][A-Z0-9_-]*' .env 2>/dev/null | sort -u); do \
		if echo " $(MAKEFILE_ONLY_VARS) " | grep -q " $$var "; then continue; fi; \
		if ! echo " $(ENV_VARS) $(SECRET_NAMES) " | grep -q " $$var "; then \
			orphans="$$orphans $$var"; \
		fi; \
	done; \
	if [ -n "$$orphans" ]; then \
		echo "Warning: these .env vars are NOT in ENV_VARS or SECRET_NAMES:"; \
		for v in $$orphans; do echo "    - $$v"; done; \
		echo "   Add them to ENV_VARS or MAKEFILE_ONLY_VARS in Makefile."; \
		exit 1; \
	fi; \
	echo "  ✓ All app vars in .env are covered"

setup-gcp: ## Create Artifact Registry repo + enable APIs (run once)
	@test -n "$(PROJECT_ID)" || { echo "Error: PROJECT_ID not set"; exit 1; }
	gcloud services enable artifactregistry.googleapis.com run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com --project $(PROJECT_ID)
	gcloud artifacts repositories create $(SERVICE_NAME) \
		--repository-format=docker \
		--location=$(or $(REGION),europe-west1) \
		--project=$(PROJECT_ID) \
		--description="Docker images for $(SERVICE_NAME)" 2>/dev/null || echo "  Repository already exists"
	@echo "  ✓ GCP setup complete"

deploy: check-env ## Build on Cloud Build and deploy to Cloud Run
	@rm -f .env.yaml
	@for var in $(ENV_VARS); do \
		val=$$(eval echo "\$$$$var"); \
		if [ -n "$$val" ]; then echo "$$var: \"$$val\"" >> .env.yaml; fi; \
	done
	@echo "  ✓ .env.yaml generated"
	gcloud builds submit --tag $(IMAGE) --project $(PROJECT_ID)
	gcloud run deploy $(SERVICE_NAME) \
		--image $(IMAGE) \
		--region $(or $(REGION),europe-west1) \
		--project $(PROJECT_ID) \
		--port 3838 \
		$(if $(ENV_VARS),--env-vars-file .env.yaml) \
		$(if $(SECRETS),--set-secrets $(SECRETS)) \
		--allow-unauthenticated
	@rm -f .env.yaml

secrets-create: ## Push secrets from .env to Google Secret Manager
	@test -n "$(PROJECT_ID)" || { echo "Error: PROJECT_ID not set"; exit 1; }
	@test -n "$(SECRET_NAMES)" || { echo "No SECRET_NAMES defined"; exit 0; }
	@PROJECT_NUMBER=$$(gcloud projects describe $(PROJECT_ID) --format='value(projectNumber)'); \
	SA="$$PROJECT_NUMBER-compute@developer.gserviceaccount.com"; \
	for secret in $(SECRET_NAMES); do \
		val=$$(eval echo "\$$$$secret"); \
		if [ -z "$$val" ]; then echo "  ⚠ $$secret not set — skipped"; continue; fi; \
		printf '%s' "$$val" | gcloud secrets create "$$secret" --data-file=- --project=$(PROJECT_ID) 2>/dev/null \
			|| printf '%s' "$$val" | gcloud secrets versions add "$$secret" --data-file=- --project=$(PROJECT_ID); \
		gcloud secrets add-iam-policy-binding "$$secret" \
			--member="serviceAccount:$$SA" --role="roles/secretmanager.secretAccessor" \
			--project=$(PROJECT_ID) > /dev/null; \
		echo "  ✓ $$secret created/updated"; \
	done

# ── Standards ────────────────────────────────────────────────────────────────

sync-standards: ## Update Wise standards from wise-standards repo
	@test -n "$(WISE_STANDARDS_PATH)" || { echo "Error: WISE_STANDARDS_PATH not set"; exit 1; }
	$(WISE_STANDARDS_PATH)/sync.sh .
