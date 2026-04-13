# Streamlit Charts (Plotly) — Conventions Wise

## Package

- Primary: `plotly` (interactive charts via `st.plotly_chart`)
- Fallback: `st.line_chart`, `st.bar_chart` for quick prototypes only

```
plotly
```

## Usage Pattern

```python
import plotly.express as px
import streamlit as st

fig = px.line(
    df,
    x="timestamp",
    y="value",
    color="metric",
    title="Metrics Over Time",
)
fig.update_layout(
    xaxis_title="Time",
    yaxis_title="Value",
    template="plotly_dark" if st.session_state.get("dark_mode") else "plotly_white",
)
st.plotly_chart(fig, use_container_width=True)
```

## Conventions

- **Time series**: Always use datetime x-axis. Parse timestamps to `datetime` before plotting.
- **Dark mode**: Support dark/light theme via Plotly templates (`plotly_dark` / `plotly_white`).
- **Responsive**: Always pass `use_container_width=True` to `st.plotly_chart`.
- **Interactive**: Enable hover tooltips and zoom by default (Plotly default behavior).
- **Multiple series**: Use the `color` parameter for series differentiation. Let Plotly handle color assignment.
- **Performance**: For large datasets (>10,000 points), consider downsampling server-side before rendering.

## Chart Types Used

| Use case | Plotly function |
|---|---|
| Time series metrics | `px.line` |
| Power/energy comparison | `px.bar` |
| Distribution / composition | `px.pie` or `px.sunburst` |
| Real-time gauge | `plotly.graph_objects.Indicator` |
| Geospatial | `px.scatter_mapbox` |

## Error State

When no data is available, show a message via `st.info("No data available")` instead of rendering an empty chart. Guard with:

```python
if df.empty:
    st.info("No data available for the selected period.")
else:
    st.plotly_chart(fig, use_container_width=True)
```
