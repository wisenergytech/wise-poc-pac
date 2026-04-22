# Quickstart: Wire R6 Classes into Shiny Modules

## Verification Steps

### 1. Before migration — capture reference values

```r
# Run the app, simulate with these parameters:
# PAC: 60 kW, PV: 33 kWc, Baseline: ingénieur, Optimizer: LP
# Date range: 2025-06-01 to 2025-07-31
# Note down: facture baseline, facture optimisée, gain EUR, autoconsommation %
```

### 2. After US1 (mod_sidebar.R rewired)

```r
# Same parameters as step 1
# Verify: facture, gain, autoconsommation within ±0.1% of reference
# Test all 4 optimizer modes: LP, MILP, QP, Smart
# Test all 5 baseline modes: réactif, programmateur, surplus_pv, ingénieur, proactif
# Test CSV upload path
# Test battery enabled
# Test curtailment enabled
```

### 3. After US2 (mod_dimensionnement.R rewired)

```r
# Open Dimensionnement tab
# Run automagic analysis
# Verify PV scenario chart renders correctly
# Verify battery scenario chart renders correctly
```

### 4. After US3 (fct_legacy.R deleted)

```bash
# Run tests
make test
# Expected: 95 pass, 0 fail

# Verify no legacy function references
grep -r "generer_demo\|prepare_df\|run_baseline\|run_simulation\|decider" R/mod_*.R
# Expected: 0 matches

# Start app
make dev
# Expected: app starts, all tabs work
```
