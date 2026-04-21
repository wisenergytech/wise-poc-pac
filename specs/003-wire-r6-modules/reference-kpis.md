# Reference KPIs (pre-migration)

Reference values captured from the R6 parity validation (scripts/verify_parity.R).
These serve as the baseline for validating post-migration results.

## Reference (from tests/testthat/fixtures/reference_values.rds)

The R6 classes have already been validated at 0.0% parity deviation against these values
during the 002-golem-r6-refactor. Since we are only changing the wiring (which calls to
use), not the underlying logic, the same parity should hold.

## Validation Approach

Post-migration, run the app with:
- PAC: 60 kW, PV: 33 kWc, Ballon: auto (36100L)
- Baseline: ingenieur
- Optimizer: LP (bloc 24h)
- Date: 2025-06-01 to 2025-08-31
- Contrat: dynamique

Verify facture, gain, and autoconsommation match within ±0.1%.
