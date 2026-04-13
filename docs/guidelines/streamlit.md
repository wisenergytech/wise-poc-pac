# Streamlit — Conventions Wise

## Version

Python 3.11+, Streamlit latest stable.

## Project Setup

- Use `uv` or `pip` for dependency management.
- Pin all dependencies in `requirements.txt` (or `pyproject.toml`).
- Use a single `app.py` as the entry point.
- Enable wide layout by default via `st.set_page_config(layout="wide")`.

## Project Structure

```
app.py                    # Streamlit entry point
pages/                    # Multi-page app (Streamlit native)
├── 1_Dashboard.py
├── 2_Settings.py
lib/                      # Shared business logic
├── auth.py               # Supabase auth helpers
├── api_client.py         # External API client (server-side proxy logic)
├── charts.py             # Chart helpers
└── config.py             # Configuration / env var loading
tests/                    # Unit tests
requirements.txt          # Pinned dependencies
Dockerfile
```

## Multi-Page Apps

- Use Streamlit's native `pages/` directory convention.
- File names are prefixed with a number for ordering: `1_Page.py`, `2_Page.py`.
- Shared state across pages uses `st.session_state`.

## Environment Variables

- Load via `os.environ` or `st.secrets` (for Streamlit Cloud, not used on Cloud Run).
- Prefix convention: `WISE_` for app-specific variables.
- Secrets (`SUPABASE_SERVICE_ROLE_KEY`, API keys) MUST only be read server-side in `lib/` modules. They MUST NOT appear in `st.session_state` or be displayed in the UI.

## State Management

- Use `st.session_state` for user session data (auth tokens, selected filters, cached results).
- Initialize state at the top of each page with `if "key" not in st.session_state:` guards.
- Never store secrets in `st.session_state`.

## HTTP Client

- Use `httpx` for all external API calls.
- Centralize API clients in `lib/api_client.py`.
- All external API calls happen server-side (Streamlit runs entirely on the server, so this is inherent to the architecture).
- HTTPS MUST be enforced for all external calls.

## Error Handling

- Wrap API calls in try/except blocks.
- Display user-friendly messages via `st.error()` or `st.warning()`.
- Log technical details to stdout with structured prefixes (e.g., `[auth]`, `[api]`).
