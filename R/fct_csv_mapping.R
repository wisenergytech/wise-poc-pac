# =============================================================================
# CSV Column Mapping — Pure functions for column name matching
# =============================================================================
# No Shiny dependency. Used by mod_sidebar.R for CSV import mapping.
# =============================================================================

# Keyword patterns per target field (regex, case-insensitive)
# Order matters within each field: first match wins
COLUMN_PATTERNS <- list(
  timestamp   = "^timestamp$|^time$|^datetime$|^date$|^utc_datetime$",
  pv_kwh      = "pv|solar|photovoltaic",
  offtake_kwh = "offtake|soutirage|consumption_index|grid_import|^import$",
  feedin_kwh  = "feedin|feed_in|injection|grid_export|^export$|intake",
  pac1_kwh    = "gshp|geo|geothermal|pac_301|pac_3|pac_kwh|^pac$|heat_pump|heatpump",
  pac2_kwh    = "ashp|aero|aerothermal|pac_501|pac_5",
  t_ballon    = "t_ballon|t_tank|tank_top|buffer_temp|ballon",
  t_sol       = "t_sol|ground|borehole|soil|t_ground",
  t_ext       = "t_ext|outdoor|ambient|external|text$"
)

# PAC type detection: if the matched column name contains these keywords,
# pre-suggest the PAC type
PAC_TYPE_KEYWORDS <- list(
  gshp = "gshp|geo|geothermal|pac_301|pac_3|ground|sol",
  ashp = "ashp|aero|aerothermal|pac_501|pac_5|air"
)

#' Suggest column mapping based on CSV column names
#'
#' Pure function. Matches CSV column names to target fields using keyword
#' regex patterns. Returns a named list with suggested source columns.
#'
#' @param col_names Character vector of CSV column names
#' @return A named list with elements:
#'   \describe{
#'     \item{mapping}{Named list: target -> source column name (or NA)}
#'     \item{pac1_type}{Suggested PAC 1 type ("ashp" or "gshp") or NA}
#'     \item{pac2_type}{Suggested PAC 2 type ("ashp" or "gshp") or NA}
#'   }
#' @export
suggest_column_mapping <- function(col_names) {
  col_lower <- tolower(col_names)
  mapping <- setNames(rep(NA_character_, length(COLUMN_PATTERNS)), names(COLUMN_PATTERNS))
  used <- character(0)

  for (target in names(COLUMN_PATTERNS)) {
    pattern <- COLUMN_PATTERNS[[target]]
    for (i in seq_along(col_lower)) {
      if (col_names[i] %in% used) next
      if (grepl(pattern, col_lower[i])) {
        mapping[[target]] <- col_names[i]
        used <- c(used, col_names[i])
        break
      }
    }
  }

  # PAC type detection
  pac1_type <- NA_character_
  pac2_type <- NA_character_
  if (!is.na(mapping[["pac1_kwh"]])) {
    src <- tolower(mapping[["pac1_kwh"]])
    if (grepl(PAC_TYPE_KEYWORDS$gshp, src)) pac1_type <- "gshp"
    else if (grepl(PAC_TYPE_KEYWORDS$ashp, src)) pac1_type <- "ashp"
  }
  if (!is.na(mapping[["pac2_kwh"]])) {
    src <- tolower(mapping[["pac2_kwh"]])
    if (grepl(PAC_TYPE_KEYWORDS$gshp, src)) pac2_type <- "gshp"
    else if (grepl(PAC_TYPE_KEYWORDS$ashp, src)) pac2_type <- "ashp"
  }

  list(
    mapping = mapping,
    pac1_type = pac1_type,
    pac2_type = pac2_type
  )
}

#' Apply column mapping to rename a dataframe
#'
#' Pure function. Renames columns from source names to target names.
#' Unmapped columns are kept as-is.
#'
#' @param df A dataframe
#' @param mapping Named list from suggest_column_mapping()$mapping
#'   (target -> source column name)
#' @return The dataframe with renamed columns
#' @export
apply_column_mapping <- function(df, mapping) {
  # Build rename vector: old_name = new_name
  for (target in names(mapping)) {
    source <- mapping[[target]]
    if (!is.na(source) && source %in% names(df) && source != target) {
      names(df)[names(df) == source] <- target
    }
  }
  # Normalize feedin_kwh -> intake_kwh (app internal convention)
  if ("feedin_kwh" %in% names(df) && !"intake_kwh" %in% names(df)) {
    names(df)[names(df) == "feedin_kwh"] <- "intake_kwh"
  }
  df
}

#' Detect if CSV can be auto-mapped without user intervention
#'
#' Returns TRUE if all required fields have exact name matches
#' (i.e. the CSV already uses the standard column names).
#'
#' @param mapping Named list from suggest_column_mapping()$mapping
#' @param col_names Character vector of original CSV column names
#' @return Logical
#' @export
detect_auto_mappable <- function(mapping, col_names) {
  required <- c("timestamp", "pv_kwh", "offtake_kwh")
  feedin_ok <- !is.na(mapping[["feedin_kwh"]]) ||
    "intake_kwh" %in% col_names ||
    "feedin_kwh" %in% col_names

  all_required_exact <- all(vapply(required, function(field) {
    !is.na(mapping[[field]]) && mapping[[field]] == field
  }, logical(1)))

  all_required_exact && feedin_ok
}
