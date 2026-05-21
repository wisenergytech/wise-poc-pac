# Flows Index

<!--
  Central index of all application flows, maintained by Speckit.
  Cross-feature flows have their own file in docs-internal/flows/.
  Feature-internal flows are referenced here with a link to the spec's flows.md.
-->

## Cross-feature flows

| Flow | File | Description |
|------|------|-------------|
| Global Request Flow | [request-flow.md](request-flow.md) | Sequence end-to-end : auth Supabase, server middleware, API externe |

## Feature flows

| Feature | Flow | Description | Source |
|---------|------|-------------|--------|
| 009-dual-pac-optimizer | Configuration PAC 2 | Activation et parametrage de la seconde PAC dans le sidebar | [flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-1) |
| 009-dual-pac-optimizer | Simulation et dispatch dual | MILP dual — 2 passes COP + guard anti-regression | [flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-2) |
| 009-dual-pac-optimizer | Lissage inverter | Validation contrainte de rampe pour PAC en mode inverter | [flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-3) |
| 009-dual-pac-optimizer | Ventilation PAC 1 / PAC 2 | Affichage KPIs et graphiques apres simulation duale | [flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-4) |
| 009-dual-pac-optimizer | Fallback bloc infaisable | Chemin d'erreur quand HiGHS ne trouve pas de solution | [flows.md](../../specs/009-dual-pac-optimizer/flows.md#flow-5) |
