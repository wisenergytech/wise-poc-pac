#' Auth Module - Supabase email/password login
#'
#' Gated by SUPABASE_AUTH_ENABLED env var. When disabled, the app
#' renders without authentication.
#' @name mod_auth
#' @noRd
NULL

#' Check if Supabase auth is enabled
#' @noRd
auth_enabled <- function() {

  tolower(Sys.getenv("SUPABASE_AUTH_ENABLED", "false")) == "true"
}

#' Auth UI - login form
#' @noRd
mod_auth_ui <- function(id) {
  ns <- shiny::NS(id)

  supabase_url <- Sys.getenv("SUPABASE_URL", "")
  supabase_key <- Sys.getenv("SUPABASE_KEY", "")

  shiny::tags$div(
    id = ns("login-page"),
    class = "auth-container",

    # Pass config to JS
    shiny::tags$script(shiny::HTML(sprintf(
      "window.__SUPABASE_URL__ = %s; window.__SUPABASE_KEY__ = %s; window.__AUTH_NS__ = %s;",
      jsonlite::toJSON(supabase_url, auto_unbox = TRUE),
      jsonlite::toJSON(supabase_key, auto_unbox = TRUE),
      jsonlite::toJSON(ns(""), auto_unbox = TRUE)
    ))),

    # Supabase JS SDK
    shiny::tags$script(src = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"),
    shiny::tags$script(src = "www/auth.js"),

    shiny::tags$div(
      class = "auth-card",
      shiny::tags$img(src = "www/logo-wise.svg", class = "auth-logo"),
      shiny::tags$h2(class = "auth-title", "Connexion"),

      shiny::tags$div(class = "auth-field",
        shiny::tags$label(`for` = ns("email"), "Email"),
        shiny::tags$input(
          id = ns("email"), type = "email",
          class = "form-control", placeholder = "nom@exemple.com"
        )
      ),

      shiny::tags$div(class = "auth-field",
        shiny::tags$label(`for` = ns("password"), "Mot de passe"),
        shiny::tags$input(
          id = ns("password"), type = "password",
          class = "form-control", placeholder = "Mot de passe"
        )
      ),

      shiny::tags$div(id = ns("error"), class = "auth-error"),

      shiny::tags$button(
        id = ns("login_btn"),
        class = "btn btn-primary auth-btn",
        onclick = sprintf("window.__wiseAuth.signIn('%s', '%s', '%s')",
                          ns("email"), ns("password"), ns("error")),
        "Se connecter"
      )
    )
  )
}

#' Auth Server - verify Supabase JWT
#' @return reactive TRUE when authenticated
#' @noRd
mod_auth_server <- function(id) {
  shiny::moduleServer(id, function(input, output, session) {

    authenticated <- shiny::reactiveVal(FALSE)

    shiny::observeEvent(input$access_token, {
      token <- input$access_token
      if (is.null(token) || nchar(token) == 0) return()

      # Verify token server-side with Supabase using service role key
      supabase_url <- Sys.getenv("SUPABASE_URL", "")
      service_role_key <- Sys.getenv("SUPABASE_SERVICE_ROLE_KEY", "")

      resp <- httr::GET(
        paste0(supabase_url, "/auth/v1/user"),
        httr::add_headers(
          Authorization = paste("Bearer", token),
          apikey = service_role_key
        )
      )

      if (httr::status_code(resp) == 200) {
        user <- httr::content(resp, "parsed")
        message("[AUTH] User authenticated: ", user$email)
        authenticated(TRUE)
      } else {
        message("[AUTH] Token verification failed: ", httr::status_code(resp))
        session$sendCustomMessage("auth-error",
          list(id = session$ns("error"), msg = "Session invalide. Reconnectez-vous."))
      }
    })

    authenticated
  })
}
