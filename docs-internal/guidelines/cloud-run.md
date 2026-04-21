# Google Cloud Run (Streamlit) — Conventions Wise

## Image

- Base image: `python:3.11-slim`
- Single-stage build: install dependencies, copy app code.
- Final image runs `streamlit run app.py`.

## Dockerfile Pattern

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PORT=8080
EXPOSE 8080

CMD ["streamlit", "run", "app.py", \
     "--server.port=8080", \
     "--server.address=0.0.0.0", \
     "--server.headless=true", \
     "--browser.gatherUsageStats=false"]
```

## Deployment

- Deploy via `gcloud run deploy` or Cloud Build.
- Region: `europe-west1` (default Wise).
- Allow unauthenticated invocations (auth is handled by Supabase at the app level).
- Set minimum instances to 0 (scale to zero for cost efficiency on POCs).

## Environment Variables

Inject secrets as Cloud Run environment variables or via Secret Manager references:
Inject the same variables as defined in `.env.example`:
- `SUPABASE_URL`, `SUPABASE_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
- Project-specific API credentials (e.g., `WISE_API_CLIENT_ID`, `WISE_API_CLIENT_SECRET`)

Never bake secrets into the Docker image at build time.

## Health Check

Streamlit exposes `/_stcore/health` by default. Configure Cloud Run to use this endpoint for health checks.

## Logs

- Streamlit and Python logs go to stdout → Cloud Run forwards to Cloud Logging automatically.
- Use structured console output via Python `logging` module with contextual prefixes (e.g., `[api]`, `[auth]`).
- Use `logging.getLogger(__name__)` pattern in each module.
