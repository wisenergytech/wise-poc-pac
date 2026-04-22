#' Documentation UI Module
#'
#' Displays package vignettes as embedded HTML within the app.
#' Loads MathJax (LaTeX rendering) and Mermaid.js (diagrams) for rich content.
#'
#' @param id module id
#' @noRd
mod_documentation_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::tags$head(
      # MathJax v3 for LaTeX math rendering
      shiny::tags$script(
        src = "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js",
        async = "async"
      ),
      # Mermaid.js v10 for diagrams
      shiny::tags$script(
        src = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"
      ),
      shiny::tags$script(shiny::HTML(
        "document.addEventListener('DOMContentLoaded', function() {
          if (typeof mermaid !== 'undefined') {
            mermaid.initialize({startOnLoad: false, theme: 'dark'});
          }
        });"
      ))
    ),
    bslib::navset_pill(
      bslib::nav_panel(
        title = "Guide des reglages",
        icon = shiny::icon("sliders"),
        shiny::uiOutput(ns("vignette_installation"))
      ),
      bslib::nav_panel(
        title = "Optimizers",
        icon = shiny::icon("brain"),
        shiny::uiOutput(ns("vignette_optimizers"))
      ),
      bslib::nav_panel(
        title = "Hypotheses",
        icon = shiny::icon("flask"),
        shiny::uiOutput(ns("vignette_hypotheses"))
      )
    )
  )
}

#' Documentation Server Module
#'
#' Renders package vignettes to HTML fragments and displays them.
#' Uses pre-built vignettes from inst/doc/ (built at install time),
#' falling back to rendering from source in dev mode.
#' Triggers MathJax and Mermaid re-rendering after content insertion.
#'
#' @param id module id
#' @noRd
mod_documentation_server <- function(id) {
  moduleServer(id, function(input, output, session) {

    render_vignette <- function(vignette_name) {
      # Try pre-built HTML from installed package first
      html_path <- system.file("doc", paste0(vignette_name, ".html"),
                               package = "wisepocpac")

      # Fallback: dev mode, render from source
      if (!nzchar(html_path)) {
        rmd_path <- system.file("vignettes", paste0(vignette_name, ".Rmd"),
                                package = "wisepocpac")
        if (!nzchar(rmd_path)) {
          # Last resort: look in project root
          rmd_path <- file.path("vignettes", paste0(vignette_name, ".Rmd"))
        }
        if (!file.exists(rmd_path)) {
          return(shiny::tags$p("Vignette non disponible."))
        }
        tmp <- tempfile(fileext = ".html")
        rmarkdown::render(rmd_path, output_format = rmarkdown::html_fragment(),
                          output_file = tmp, quiet = TRUE)
        html_path <- tmp
      }

      # Extract body content from full HTML or use fragment directly
      html_content <- paste(readLines(html_path, warn = FALSE), collapse = "\n")

      # If it's a full HTML page (from html_vignette), extract the body
      if (grepl("<body>", html_content, fixed = TRUE)) {
        body <- sub(".*<body[^>]*>(.*)</body>.*", "\\1", html_content)
      } else {
        body <- html_content
      }

      shiny::tagList(
        shiny::tags$div(
          class = "vignette-content",
          style = sprintf(
            "padding:16px;font-size:.88rem;line-height:1.7;color:%s;max-width:900px;",
            cl$text
          ),
          shiny::HTML(body)
        ),
        # Trigger MathJax + Mermaid rendering after dynamic content insertion
        shiny::tags$script(shiny::HTML(
          "setTimeout(function() {
            if (typeof MathJax !== 'undefined' && MathJax.typesetPromise) {
              MathJax.typesetPromise();
            }
            if (typeof mermaid !== 'undefined' && mermaid.run) {
              mermaid.run({querySelector: '.mermaid:not([data-processed])'});
            }
          }, 200);"
        ))
      )
    }

    output$vignette_installation <- shiny::renderUI({
      render_vignette("comprendre-votre-installation")
    })

    output$vignette_optimizers <- shiny::renderUI({
      render_vignette("comprendre-les-optimizers")
    })

    output$vignette_hypotheses <- shiny::renderUI({
      render_vignette("hypotheses-et-perimetre")
    })
  })
}
