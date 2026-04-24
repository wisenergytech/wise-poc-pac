#' Documentation UI Module
#'
#' Displays all package vignettes as embedded HTML within the app.
#' Automatically discovers vignettes from the package.
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
            mermaid.initialize({startOnLoad: false, theme: 'default', securityLevel: 'loose'});
          }
        });"
      ))
    ),
    shiny::uiOutput(ns("vignette_tabs"))
  )
}

#' Documentation Server Module
#'
#' Renders all package vignettes to HTML fragments and displays them.
#' Automatically discovers vignettes at runtime.
#' Uses pre-built vignettes from inst/doc/ (built at install time),
#' falling back to rendering from source in dev mode.
#' Triggers MathJax and Mermaid re-rendering after content insertion.
#'
#' @param id module id
#' @noRd
mod_documentation_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # Icon mapping for known vignettes (fallback: book icon)
    vignette_icons <- list(
      "comprendre-votre-installation" = "sliders",
      "comprendre-les-optimizers" = "brain",
      "donnees-baseline-autoconsommation" = "chart-line",
      "hypotheses-et-perimetre" = "flask",
      "demarrage-rapide" = "rocket",
      "lire-les-resultats" = "magnifying-glass-chart",
      "cas-usage-faq" = "comments"
    )

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
            if (typeof mermaid !== 'undefined') {
              // Find unprocessed mermaid elements, decode HTML entities, render
              var nodes = document.querySelectorAll('.mermaid:not([data-processed=\"true\"])');
              nodes.forEach(function(el) {
                // textContent is already decoded by the browser, but we
                // reassign to ensure innerHTML matches (Mermaid reads innerHTML)
                el.innerHTML = el.textContent;
              });
              if (nodes.length > 0) {
                try { mermaid.run({nodes: Array.from(nodes)}); }
                catch(e) { console.warn('Mermaid render error:', e); }
              }
            }
          }, 500);"
        ))
      )
    }

    # Extract title from Rmd YAML front matter
    extract_vignette_title <- function(rmd_path) {
      lines <- readLines(rmd_path, n = 20, warn = FALSE)
      title_line <- grep("^title:", lines, value = TRUE)
      if (length(title_line) > 0) {
        title <- sub("^title:\\s*[\"']?(.+?)[\"']?\\s*$", "\\1", title_line[1])
        return(title)
      }
      # Fallback: humanize filename
      name <- tools::file_path_sans_ext(basename(rmd_path))
      gsub("-", " ", name)
    }

    # Discover all vignettes
    discover_vignettes <- function() {
      # Try installed package first
      rmd_files <- list.files(
        system.file("vignettes", package = "wisepocpac"),
        pattern = "\\.Rmd$", full.names = TRUE
      )
      # Fallback: dev mode, look in project root
      if (length(rmd_files) == 0) {
        rmd_files <- list.files("vignettes", pattern = "\\.Rmd$", full.names = TRUE)
      }

      vignettes <- lapply(rmd_files, function(f) {
        name <- tools::file_path_sans_ext(basename(f))
        title <- extract_vignette_title(f)
        icon <- vignette_icons[[name]] %||% "book"
        list(name = name, title = title, icon = icon)
      })

      vignettes
    }

    output$vignette_tabs <- shiny::renderUI({
      vignettes <- discover_vignettes()
      if (length(vignettes) == 0) {
        return(shiny::tags$p("Aucune vignette disponible."))
      }

      # Create nav_panel for each vignette
      panels <- lapply(vignettes, function(v) {
        output_id <- paste0("vignette_", gsub("-", "_", v$name))
        output[[output_id]] <- shiny::renderUI({
          render_vignette(v$name)
        })
        bslib::nav_panel(
          title = v$title,
          icon = shiny::icon(v$icon),
          shiny::uiOutput(ns(output_id))
        )
      })

      do.call(bslib::navset_pill, panels)
    })

    shiny::outputOptions(output, "vignette_tabs", suspendWhenHidden = FALSE)
  })
}
