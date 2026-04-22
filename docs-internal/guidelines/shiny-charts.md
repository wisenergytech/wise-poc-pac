# Shiny Charts (Plotly) — Conventions Wise

## Package

- Primary: `plotly` (interactive charts via `plotlyOutput` / `renderPlotly`)
- No ggplot2 — all visualizations use Plotly directly

## Chart Type Selection Rules

The chart type must match the **nature of the variable**, not be a blanket choice:

| Variable nature | Chart type | Examples |
|---|---|---|
| Volume / quantity per period (summable) | `add_bars` | kWh soutiré, kWh injecté, kWh PV, kWh autoconso, facture par période |
| Continuous / instantaneous measure (averaged) | `add_trace` (scatter+lines) | Température, COP, SoC batterie, prix spot, intensité CO2 |
| Cumulative value | `add_trace` (lines + `fill = "tozeroy"`) | Facture cumulée, CO2 évité cumulé |
| Constraint violations | `add_trace` (markers) | Points hors bornes température, charge/décharge simultanée |
| Period × hour profile | `heatmap` | Intensité CO2, surplus PV, température ballon |

**Rule**: if a variable is aggregated by `sum()`, it is a volume → use bars. If aggregated by `mean()`, it is continuous → use lines.

This rule applies everywhere, including the comparison tool which dynamically selects chart type based on the `summable` list.

## Summable Variables (bars)

```r
summable <- c("pv_kwh", "offtake_kwh", "sim_offtake", "intake_kwh", "sim_intake",
  "conso_hors_pac", "soutirage_estime_kwh", "sim_pac_on",
  "autoconso_baseline", "autoconso_opti",
  "facture_baseline", "facture_opti")
```

All other variables are continuous → lines.

## Adaptive Aggregation

Temporal resolution adapts to the displayed period length:

| Period | Resolution | Aggregation |
|---|---|---|
| ≤ 14 days | 15 min (raw) | None |
| 14–60 days | Hourly | sum (volumes) / mean (continuous) |
| 60–180 days | Daily | sum / mean |
| > 180 days | Weekly | sum / mean |

## Styling

All plots use `pl_layout()` for consistent dark theme:
- Transparent background (`paper_bgcolor`, `plot_bgcolor`)
- Font: JetBrains Mono
- Legend: horizontal, below chart
- Grid: subtle (`cl$grid`)

## Color Palette

| Variable | Color ref |
|---|---|
| Baseline (réel) | `cl$reel` (orange) |
| Optimisé | `cl$opti` (cyan) |
| PV production | `cl$pv` (yellow) |
| Success / gains | `cl$success` (green) |
| Danger / violations | `cl$danger` (red) |
| PAC | `cl$pac` (emerald) |

## Dual Y-Axes

When comparing variables with different units, use `yaxis2` on the right. Color axis ticks/title to match the trace color for readability.
