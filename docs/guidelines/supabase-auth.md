# Supabase Auth (Streamlit) — Conventions Wise

## Architecture

Authentication uses two layers, matching the Nuxt pattern:

1. **Client-side (browser)**: Login form rendered by Streamlit. The user submits credentials, and Streamlit calls Supabase Auth via `supabase-py` to obtain a session token. The token is stored in `st.session_state`.
2. **Server-side (Streamlit process)**: All API calls and data access verify the JWT token using the Supabase **service role key** before processing requests. The service role key MUST NEVER be exposed to the browser.

## Dependencies

```
supabase
```

The `supabase` Python package provides `create_client` for both public and service-role operations.

## Auth Module (`lib/auth.py`)

Create a centralized auth module:

```python
import streamlit as st
from supabase import create_client, Client

def get_supabase_client() -> Client | None:
    """Public client using anon key (for auth operations)."""
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        return None  # Local dev without Supabase
    return create_client(url, key)

def get_supabase_admin() -> Client | None:
    """Admin client using service role key (for server-side verification)."""
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        return None  # Local dev without Supabase
    return create_client(url, key)
```

## Auth Guard (equivalent to middleware)

Every page MUST call the auth guard at the top:

```python
from lib.auth import require_auth

def require_auth():
    """Redirect to login if not authenticated. Skip if Supabase is not configured."""
    client = get_supabase_admin()
    if client is None:
        return  # Local dev: skip auth

    if "access_token" not in st.session_state:
        st.switch_page("pages/Login.py")
        st.stop()

    # Verify token is still valid
    user = client.auth.get_user(st.session_state["access_token"])
    if not user:
        del st.session_state["access_token"]
        st.switch_page("pages/Login.py")
        st.stop()
```

## Login Page (`pages/Login.py`)

- Supports email/password login via `supabase.auth.sign_in_with_password()`.
- On success, stores `access_token` and `refresh_token` in `st.session_state`.
- Redirects to the main page after successful login.
- No self-registration (users are created by admin in Supabase dashboard).

```python
import streamlit as st
from lib.auth import get_supabase_client

st.set_page_config(page_title="Login")

client = get_supabase_client()
if client is None:
    st.warning("Supabase not configured — auth disabled")
    st.stop()

email = st.text_input("Email")
password = st.text_input("Password", type="password")

if st.button("Login"):
    try:
        response = client.auth.sign_in_with_password({
            "email": email,
            "password": password,
        })
        st.session_state["access_token"] = response.session.access_token
        st.session_state["refresh_token"] = response.session.refresh_token
        st.session_state["user"] = response.user
        st.switch_page("app.py")
    except Exception as e:
        st.error("Invalid credentials")
```

## Local Development

When `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are not set, the auth guard skips authentication entirely. This allows local development without a Supabase project.

## Security Rules (same as Nuxt)

- `SERVICE_ROLE_KEY` MUST NEVER be exposed to the browser or stored in `st.session_state`.
- JWT tokens MUST NOT appear in log output, error messages, or version-controlled files.
- API secrets MUST be supplied via environment variables or a secrets manager.
- All external API calls requiring authentication MUST include the token server-side only.
