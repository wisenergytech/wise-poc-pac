#' Detect PAC consumption from joined installation data
#'
#' Applies a cascade of detection methods:
#' (a) GSHP_power + ASHP_power if non-zero
#' (b) COP-based heuristic (talon subtraction)
#' (c) Fallback: use total Elec_consumption
#'
#' @param df Joined dataframe with at least: elec_kwh. Optional: gshp_kw, ashp_kw, cop.
#' @return List with: pac_kwh (numeric vector), method (character), p95_kw (numeric or NA), talon_w (numeric or NA)
#' @noRd
detect_pac_consumption <- function(df) {
  n <- nrow(df)

  # --- Cascade level (a): GSHP_power + ASHP_power ---
  has_gshp <- "gshp_kw" %in% names(df) && any(df$gshp_kw > 0, na.rm = TRUE)
  has_ashp <- "ashp_kw" %in% names(df) && any(df$ashp_kw > 0, na.rm = TRUE)

  if (has_gshp || has_ashp) {
    gshp <- if ("gshp_kw" %in% names(df)) df$gshp_kw else rep(0, n)
    ashp <- if ("ashp_kw" %in% names(df)) df$ashp_kw else rep(0, n)
    pac_kwh <- (gshp + ashp) * 0.25  # 15-min energy from power
    p95_kw <- stats::quantile(gshp + ashp, 0.95, na.rm = TRUE)
    return(list(
      pac_kwh = pac_kwh,
      method = "sous-compteur (GSHP + ASHP)",
      p95_kw = as.numeric(p95_kw),
      talon_w = NA_real_
    ))
  }

  # --- Cascade level (c): COP heuristic ---
  if ("cop" %in% names(df) && !all(is.na(df$cop))) {
    cop_zero <- !is.na(df$cop) & df$cop == 0
    cop_on <- !is.na(df$cop) & df$cop > 0 & df$cop < 7

    if (sum(cop_zero) > 20 && sum(cop_on) > 20) {
      talon_kwh <- stats::median(df$elec_kwh[cop_zero], na.rm = TRUE)
      pac_kwh <- ifelse(cop_on, pmax(0, df$elec_kwh - talon_kwh), 0)
      p95_kw <- stats::quantile(pac_kwh[cop_on], 0.95, na.rm = TRUE) * 4
      return(list(
        pac_kwh = pac_kwh,
        method = "heuristique COP",
        p95_kw = as.numeric(p95_kw),
        talon_w = talon_kwh * 4000
      ))
    }
  }

  # --- Cascade level (d): Fallback ---
  list(
    pac_kwh = df$elec_kwh,
    method = "fallback (total installation, s\u00e9paration impossible)",
    p95_kw = NA_real_,
    talon_w = NA_real_
  )
}
