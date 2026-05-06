################################################################################
# Filter Variant Assessment with Adaptive Exponents
################################################################################
# Optimizes phenological observation filtering using year-specific adaptive
# exponents that automatically adjust based on sample number decline patterns.
#
# AUTHOR : Markus Möller; ORCID: https://orcid.org/0000-0002-1918-7747
# Affil. : Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#
# CHANGES (2026-04-29 patch):
#   1. New parameter `subfolders = TRUE` routes outputs into:
#        <out_dir>/shapefiles/      → DOY_<plant>-<phase>_<year>.shp
#        <out_dir>/opt_scores/      → OPT_ALL_*, OPT_MAX_*, EXPONENTS_*
#        <out_dir>/opt_scores/diagnostics/ → diagnostic PDFs
#      Pass `subfolders = FALSE` for the flat layout used by the previous
#      version.
#   2. `out_dir` now defaults to `in_dir` (the prior version errored if
#      out_dir was omitted from the call).
#   3. All file writes use `file.path()` instead of `paste0(out_dir, ...)`,
#      which silently produced wrong paths when `out_dir` lacked a trailing
#      slash.
#   4. New column `N_RATIO = SN / max(SN per phase)` is added to the OPT_ALL,
#      OPT_MAX and ALL_PHASES tables. This is the sample-retention metric
#      consumed by the Hook A RO-Crate publisher.
#   5. `export_diagnostic_plots()` now takes the PDF output directory as an
#      explicit `out_pdf_dir` argument instead of relying on lexical scoping
#      of the caller's `out_dir`.
################################################################################

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================
filter_variant_selector <- function(
    in_dir,
    out_dir            = in_dir,
    plant,
    phases,
    years,
    sn_exponent_start  = 1.0,
    sn_exponent_end    = 1.5,
    exponent_method    = "decline_based",
    min_cor            = 0.5,
    min_obs            = 50,
    verbose            = TRUE,
    export_diagnostics = TRUE,
    subfolders         = TRUE
) {

  # Validate exponent parameters
  if (sn_exponent_end < sn_exponent_start) {
    stop("sn_exponent_end (", sn_exponent_end,
         ") must be >= sn_exponent_start (", sn_exponent_start, ")")
  }

  # Load required packages
  if (!requireNamespace("gtools", quietly = TRUE)) {
    if (verbose) warning("Package 'gtools' not found. Using base sort.")
    mixedsort <- sort
  } else {
    mixedsort <- gtools::mixedsort
  }

  # ----------------------------------------------------------------------------
  # Output directory layout
  # ----------------------------------------------------------------------------
  if (subfolders) {
    out_shp <- file.path(out_dir, "shapefiles")
    out_csv <- file.path(out_dir, "opt_scores")
    out_pdf <- file.path(out_dir, "opt_scores", "diagnostics")
  } else {
    out_shp <- out_dir
    out_csv <- out_dir
    out_pdf <- out_dir
  }
  for (d in unique(c(out_shp, out_csv, out_pdf)))
    dir.create(d, recursive = TRUE, showWarnings = FALSE)

  # Store original working directory and switch to in_dir for input reads
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(file.path(in_dir))

  # Initialize storage for results
  all_results          <- list()
  all_exponent_params  <- list()
  all_diagnostics      <- list()

  if (verbose) {
    cat("\n")
    cat("================================================================================\n")
    cat("ADAPTIVE EXPONENT OPTIMIZATION\n")
    cat("================================================================================\n")
    cat("Configuration:\n")
    cat("  - SN exponent range:", sn_exponent_start, "→", sn_exponent_end, "\n")
    cat("  - Exponent method:", exponent_method, "\n")
    cat("  - Min correlation:", min_cor, "\n")
    cat("  - Min observations (SN):", min_obs, "\n")
    cat("  - Phases:", paste(phases, collapse = ", "), "\n")
    cat("  - Years:", min(years), "-", max(years), "\n")
    cat("  - Formula: OPT = SN^x(year) × COR\n")
    cat("  - Output layout:",
        if (subfolders) "subfolders (shapefiles/, opt_scores/)"
        else            "flat (single directory)", "\n")
    cat("================================================================================\n\n")
  }

  # ============================================================================
  # MAIN LOOP: Process each phase
  # ============================================================================
  for (phase in phases) {

    if (verbose) cat("Processing PHASE", phase, "...\n")

    # --- STEP 1: Read and combine accuracy files for current phase ---------
    files_cv      <- list.files(pattern = "\\.csv$")
    pattern_phase <- paste0("OPT_", plant, "-", phase)
    files_phase   <- mixedsort(grep(pattern_phase, files_cv, value = TRUE))

    if (length(files_phase) == 0) {
      warning("No accuracy files found for PLANT = ", plant,
              ", PHASE = ", phase, " in directory: ", in_dir)
      next
    }

    df_cv <- utils::read.csv2(files_phase[1], stringsAsFactors = FALSE)
    if (length(files_phase) > 1) {
      for (i in 2:length(files_phase)) {
        df_tmp <- utils::read.csv2(files_phase[i], stringsAsFactors = FALSE)
        df_cv  <- rbind(df_cv, df_tmp)
      }
    }

    required_cols <- c("SN", "COR", "YEAR")
    if (!all(required_cols %in% names(df_cv))) {
      stop("Expected columns ", paste(required_cols, collapse = ", "),
           " not all present in accuracy table for phase ", phase)
    }

    df_cv <- df_cv[df_cv$YEAR %in% years, ]
    if (nrow(df_cv) == 0) {
      warning("No data for phase ", phase, " in years ",
              min(years), "-", max(years))
      next
    }

    # --- STEP 2: Calculate year-specific adaptive exponents ---------------
    exponent_analysis <- calculate_exponents(
      df              = df_cv,
      phase           = phase,
      exponent_start  = sn_exponent_start,
      exponent_end    = sn_exponent_end,
      exponent_method = exponent_method,
      verbose         = verbose
    )
    year_params <- exponent_analysis$year_params
    all_exponent_params[[as.character(phase)]] <- year_params

    df_cv <- merge(df_cv, year_params[, c("YEAR", "sn_exponent")],
                   by = "YEAR", all.x = TRUE)

    # --- STEP 3: Compute optimization metric ------------------------------
    df_cv$OPT <- with(df_cv, (SN ^ sn_exponent) * COR)
    df_cv$OPT[df_cv$COR < min_cor]  <- -Inf
    df_cv$OPT[df_cv$SN  < min_obs]  <- -Inf

    df_cv$OPT_normalized <- with(df_cv, {
      sn_max <- max(SN, na.rm = TRUE)
      ((SN / sn_max) ^ sn_exponent) * COR
    })

    # NEW: sample-retention ratio consumed as a quality element by Hook A
    sn_max_phase <- max(df_cv$SN, na.rm = TRUE)
    df_cv$N_RATIO <- df_cv$SN / sn_max_phase

    # --- STEP 4: Export all variants ---------------------------------------
    out_all_name <- paste0("OPT_ALL_", plant, "-", phase, ".csv")
    utils::write.csv2(df_cv,
                      file = file.path(out_csv, out_all_name),
                      row.names = FALSE)
    if (verbose) cat("  - Wrote all variants:", out_all_name, "\n")

    # --- STEP 5: Select optimal variant per year ---------------------------
    df_cv_max <- data.frame(matrix(nrow = 0, ncol = ncol(df_cv)))
    colnames(df_cv_max) <- colnames(df_cv)

    for (yr in years) {
      df_year <- df_cv[df_cv$YEAR == yr, , drop = FALSE]
      df_year <- stats::na.omit(df_year)
      if (nrow(df_year) == 0) next

      valid_opts <- df_year$OPT[is.finite(df_year$OPT)]
      if (length(valid_opts) == 0) {
        warning("No valid OPT values for year ", yr, ", phase ", phase,
                " (min_cor or min_obs constraints not met)")
        next
      }

      idx_best     <- which(df_year$OPT == max(df_year$OPT, na.rm = TRUE))[1]
      df_year_best <- df_year[idx_best, , drop = FALSE]
      df_cv_max    <- rbind(df_cv_max, df_year_best)

      # Export optimal shapefile (sf available + source file exists)
      if (requireNamespace("sf", quietly = TRUE)) {
        shp_file <- paste0("DOY_", df_year_best$PLANT, "-",
                            df_year_best$PHASE, "_", df_year_best$YEAR,
                            "_FSTD", df_year_best$STD * 10, ".shp")
        if (file.exists(shp_file)) {
          opt_shp <- sf::st_read(shp_file, quiet = TRUE)
          out_shp_name <- paste0("DOY_", df_year_best$PLANT, "-",
                                  df_year_best$PHASE, "_",
                                  df_year_best$YEAR, ".shp")
          sf::st_write(opt_shp,
                       file.path(out_shp, out_shp_name),
                       delete_layer = TRUE, quiet = TRUE)
        }
      }
    }

    # --- STEP 6: Export best-per-year table -------------------------------
    out_max_name <- paste0("OPT_MAX_", plant, "-", phase, ".csv")
    utils::write.csv2(df_cv_max,
                      file = file.path(out_csv, out_max_name),
                      row.names = FALSE)
    if (verbose) {
      cat("  - Wrote optimal variants:", out_max_name, "\n")
      cat("  - Selected", nrow(df_cv_max), "optimal variants\n")
    }

    # --- STEP 7: Diagnostics -----------------------------------------------
    diagnostics <- generate_diagnostics(
      df_all = df_cv, df_best = df_cv_max,
      year_params = year_params, phase = phase, verbose = verbose
    )
    all_diagnostics[[as.character(phase)]] <- diagnostics

    if (export_diagnostics && requireNamespace("ggplot2", quietly = TRUE)) {
      export_diagnostic_plots(
        df_all = df_cv, df_best = df_cv_max,
        year_params = year_params, diagnostics = diagnostics,
        phase = phase, plant = plant, out_pdf_dir = out_pdf
      )
    }

    all_results[[as.character(phase)]] <- list(
      all_variants  = df_cv,
      best_variants = df_cv_max
    )

    if (verbose) cat("  - Phase", phase, "complete.\n\n")
  }

  # ============================================================================
  # FINAL OUTPUT
  # ============================================================================
  if (length(all_results) == 0) {
    warning("No valid variants were found across any phase/year based on your criteria.")
    return(invisible(NULL))
  }

  df_all_combined  <- do.call(rbind, lapply(all_results, function(x) x$all_variants))
  df_best_combined <- do.call(rbind, lapply(all_results, function(x) x$best_variants))
  df_params_combined <- do.call(rbind, lapply(names(all_exponent_params), function(p) {
    df <- all_exponent_params[[p]]
    df$PHASE <- as.numeric(p)
    df
  }))

  utils::write.csv2(df_all_combined,
                    file = file.path(out_csv,
                                     paste0("OPT_ALL_", plant, "_ALL_PHASES.csv")),
                    row.names = FALSE)
  utils::write.csv2(df_best_combined,
                    file = file.path(out_csv,
                                     paste0("OPT_MAX_", plant, "_ALL_PHASES.csv")),
                    row.names = FALSE)
  utils::write.csv2(df_params_combined,
                    file = file.path(out_csv,
                                     paste0("OPT_", plant,
                                             "_EXPONENTS_ALL_PHASES.csv")),
                    row.names = FALSE)

  if (verbose) {
    cat("================================================================================\n")
    cat("OPTIMIZATION COMPLETE\n")
    cat("================================================================================\n")
    cat("Outputs:\n")
    cat("  Shapefiles  -> ", out_shp, "\n", sep = "")
    cat("  OPT scores  -> ", out_csv, "\n", sep = "")
    cat("  Diagnostics -> ", out_pdf, "\n", sep = "")
    cat("================================================================================\n\n")
  }

  invisible(list(
    all_variants        = df_all_combined,
    best_variants       = df_best_combined,
    exponent_parameters = df_params_combined,
    diagnostics         = all_diagnostics,
    config = list(
      sn_exponent_start = sn_exponent_start,
      sn_exponent_end   = sn_exponent_end,
      exponent_method   = exponent_method,
      min_cor           = min_cor,
      min_obs           = min_obs,
      subfolders        = subfolders
    )
  ))
}


################################################################################
# HELPER FUNCTIONS (unchanged signatures except export_diagnostic_plots)
################################################################################

calculate_exponents <- function(df, phase, exponent_start, exponent_end,
                                exponent_method = "decline_based",
                                verbose = TRUE) {
  year_stats <- aggregate(
    cbind(SN, COR) ~ YEAR, data = df,
    FUN = function(x) c(mean = mean(x, na.rm = TRUE),
                        median = median(x, na.rm = TRUE),
                        sd = sd(x, na.rm = TRUE))
  )
  year_stats <- data.frame(
    YEAR      = year_stats$YEAR,
    SN_mean   = year_stats$SN[, "mean"],
    SN_median = year_stats$SN[, "median"],
    SN_sd     = year_stats$SN[, "sd"],
    COR_mean  = year_stats$COR[, "mean"]
  )

  if (exponent_method == "decline_based") {
    sn_max <- max(year_stats$SN_mean, na.rm = TRUE)
    sn_min <- min(year_stats$SN_mean, na.rm = TRUE)
    decline <- (sn_max - year_stats$SN_mean) / (sn_max - sn_min)
    decline[is.nan(decline)] <- 0
    year_stats$sn_exponent <- exponent_start +
                              decline * (exponent_end - exponent_start)
  } else if (exponent_method == "linear_time") {
    yr_min <- min(year_stats$YEAR); yr_max <- max(year_stats$YEAR)
    progress <- (year_stats$YEAR - yr_min) / (yr_max - yr_min)
    progress[is.nan(progress)] <- 0
    year_stats$sn_exponent <- exponent_start +
                              progress * (exponent_end - exponent_start)
  } else {
    stop("Unknown exponent_method: ", exponent_method)
  }

  list(year_params = year_stats)
}


generate_diagnostics <- function(df_all, df_best, year_params, phase,
                                 verbose = TRUE) {
  metrics <- df_best[, c("SN", "COR", "MAE", "sn_exponent")]
  summary_stats <- data.frame(
    Metric = c("SN", "COR", "MAE", "sn_exponent"),
    Mean   = sapply(metrics, mean, na.rm = TRUE),
    SD     = sapply(metrics, sd,   na.rm = TRUE),
    Min    = sapply(metrics, min,  na.rm = TRUE),
    Max    = sapply(metrics, max,  na.rm = TRUE)
  )
  threshold_dist <- table(df_best$STD)
  exponent_stats <- data.frame(
    SN_Decline_Pct = ((max(year_params$SN_mean, na.rm = TRUE) -
                       min(year_params$SN_mean, na.rm = TRUE)) /
                       max(year_params$SN_mean, na.rm = TRUE)) * 100,
    Exponent_Range = paste0(round(min(year_params$sn_exponent), 2), " – ",
                            round(max(year_params$sn_exponent), 2))
  )

  if (verbose) {
    cat("  - Diagnostic summary:\n")
    cat("    * Mean SN:", round(summary_stats$Mean[1], 1), "\n")
    cat("    * Mean COR:", round(summary_stats$Mean[2], 4), "\n")
    cat("    * Mean MAE:", round(summary_stats$Mean[3], 3), "\n")
    cat("    * Mean exponent:", round(summary_stats$Mean[4], 3), "\n")
    cat("    * SN decline:", round(exponent_stats$SN_Decline_Pct, 1), "%\n")
    cat("    * Most common STD threshold:",
        names(which.max(threshold_dist)), "\n")
  }

  list(summary_stats = summary_stats,
       threshold_dist = threshold_dist,
       exponent_stats = exponent_stats)
}


#' Export diagnostic plots to PDF for adaptive optimization.
#' @param out_pdf_dir Directory in which to write the PDF (NEW).
export_diagnostic_plots <- function(df_all, df_best, year_params,
                                    diagnostics, phase, plant,
                                    out_pdf_dir) {

  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    warning("ggplot2 not available. Skipping diagnostic plots.")
    return(invisible(NULL))
  }
  library(ggplot2)

  pdf_name <- paste0("OPT_", plant, "-", phase, "_DIAGNOSTICS.pdf")
  grDevices::pdf(file.path(out_pdf_dir, pdf_name), width = 11, height = 8.5)
  on.exit(grDevices::dev.off(), add = TRUE)

  print(ggplot(year_params, aes(x = YEAR, y = sn_exponent)) +
    geom_line(color = "darkgreen", size = 1.2) +
    geom_point(size = 3, color = "darkgreen") +
    geom_hline(yintercept = 1.0, linetype = "dashed", color = "gray50", alpha = 0.7) +
    labs(title = paste("Adaptive Exponents Over Time - Phase", phase),
         subtitle = "Exponent-based optimization (no temporal weighting)",
         x = "Year", y = "SN Exponent (x)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot(year_params, aes(x = YEAR)) +
    geom_col(aes(y = SN_mean / max(SN_mean) * max(sn_exponent)),
             fill = "steelblue", alpha = 0.5) +
    geom_line(aes(y = sn_exponent), color = "darkgreen", size = 1.2) +
    geom_point(aes(y = sn_exponent), color = "darkgreen", size = 3) +
    labs(title = paste("Sample Numbers vs Adaptive Exponents - Phase", phase),
         subtitle = "Bars = normalized SN, Line = adaptive exponent",
         x = "Year", y = "Value (normalized scale)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot(year_params, aes(x = SN_mean, y = sn_exponent)) +
    geom_point(size = 3, color = "darkgreen") +
    geom_smooth(method = "loess", se = TRUE, color = "darkgreen", fill = "green", alpha = 0.2) +
    labs(title = paste("Exponent Response to Sample Decline - Phase", phase),
         subtitle = "Lower SN → Higher exponent (stronger emphasis)",
         x = "Mean Sample Number (SN)", y = "Adaptive Exponent (x)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot() +
    geom_point(data = df_all,  aes(x = YEAR, y = SN), alpha = 0.2, color = "gray50") +
    geom_line( data = df_best, aes(x = YEAR, y = SN), color = "red", size = 1.2) +
    geom_point(data = df_best, aes(x = YEAR, y = SN), color = "red", size = 3) +
    geom_smooth(data = df_best, aes(x = YEAR, y = SN), method = "loess", se = TRUE, color = "darkred") +
    labs(title = paste("Sample Numbers Over Time - Phase", phase),
         subtitle = "Gray points = all variants, Red line = optimal selections",
         x = "Year", y = "Sample Number (SN)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot() +
    geom_point(data = df_all,  aes(x = YEAR, y = COR), alpha = 0.2, color = "gray50") +
    geom_line( data = df_best, aes(x = YEAR, y = COR), color = "blue", size = 1.2) +
    geom_point(data = df_best, aes(x = YEAR, y = COR), color = "blue", size = 3) +
    geom_hline(yintercept = 0.70, linetype = "dashed", color = "red") +
    labs(title = paste("Correlation Quality Over Time - Phase", phase),
         subtitle = "Gray points = all variants, Blue line = optimal selections",
         x = "Year", y = "Correlation (COR)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot() +
    geom_point(data = df_all, aes(x = SN, y = COR, color = OPT), alpha = 0.5, size = 2) +
    geom_point(data = df_best, aes(x = SN, y = COR), color = "red", size = 4, shape = 1, stroke = 2) +
    scale_color_viridis_c(name = "OPT\nScore") +
    labs(title = paste("Sample-Correlation Trade-off - Phase", phase),
         subtitle = "Red circles = optimal selections (adaptive exponents)",
         x = "Sample Number (SN)", y = "Correlation (COR)") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  threshold_df <- as.data.frame(diagnostics$threshold_dist)
  colnames(threshold_df) <- c("STD", "Count")
  print(ggplot(threshold_df, aes(x = STD, y = Count)) +
    geom_col(fill = "steelblue", alpha = 0.8) +
    geom_text(aes(label = Count), vjust = -0.5, size = 4) +
    labs(title = paste("Selected STD Thresholds - Phase", phase),
         subtitle = "Frequency of optimal threshold selections across years",
         x = "STD Threshold", y = "Count") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold")))

  print(ggplot(df_best, aes(x = factor(YEAR), y = OPT)) +
    geom_col(fill = "steelblue", alpha = 0.8) +
    labs(title = paste("OPT Scores by Year - Phase", phase),
         subtitle = "Formula: SN^x(year) × COR",
         x = "Year", y = "OPT Score") +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"),
          axis.text.x = element_text(angle = 45, hjust = 1)))

  invisible(pdf_name)
}

################################################################################
# END OF FILE
################################################################################
