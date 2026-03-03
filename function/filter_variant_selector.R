################################################################################
# Filter Variant Assessment with Adaptive Exponents
################################################################################
# Optimizes phenological observation filtering using year-specific adaptive
# exponents that automatically adjust based on sample number decline patterns.

# AUTHOR:
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/

# ARGUMENTS:
# in_dir  - Character. Directory containing accuracy CSV files.
# plant   - Integer. Plant identifier (e.g., 202).
# phases  - Integer vector. Phenological phases to process.
# years   - Integer vector. Years to include in analysis.
#
# sn_exponent_start - Numeric. Starting exponent for highest-SN year (default 1.0).
#   * Applied to year with highest sample numbers.
#   * 1.0 = balanced emphasis (recommended for abundant samples).
#
# sn_exponent_end   - Numeric. Ending exponent for lowest-SN year (default 1.5).
#   * Applied to year with lowest sample numbers.
#   * 1.5 = strong SN emphasis (recommended for declining samples).
#   * Must be >= sn_exponent_start.
#
# exponent_method   - Character. Method for calculating year-specific exponents:
#   * "decline_based" = based on actual SN decline (default, recommended).
#   * "linear_time"   = linear interpolation over time.
#
# min_cor           - Numeric. Minimum acceptable correlation threshold
#                     (default 0.65).
# verbose           - Logical. Print progress and diagnostic information
#                     (default TRUE).
# export_diagnostics - Logical. Export diagnostic plots and tables
#                      (default TRUE).
#
# RETURNS:
# List with components:
#   - all_variants : Data frame with all filtering variants and OPT scores.
#   - best_variants: Data frame with optimal variant per year per phase.
#   - exponents    : Data frame with computed year-specific exponents.
#   - diagnostics  : List with diagnostic information.
################################################################################

# ==============================================================================
# MAIN FUNCTION:
# ==============================================================================
filter_variant_selector <- function(
    in_dir,
    plant,
    phases,
    years,
    sn_exponent_start = 1.0,
    sn_exponent_end = 1.5,
    exponent_method = "decline_based",
    min_cor = 0.5,
    verbose = TRUE,
    export_diagnostics = TRUE
) {
  
  # Validate exponent parameters
  if (sn_exponent_end < sn_exponent_start) {
    stop("sn_exponent_end (", sn_exponent_end, ") must be >= sn_exponent_start (", 
         sn_exponent_start, ")")
  }
  
  # Load required packages
  if (!requireNamespace("gtools", quietly = TRUE)) {
    if (verbose) warning("Package 'gtools' not found. Using base sort.")
    mixedsort <- sort
  } else {
    mixedsort <- gtools::mixedsort
  }
  
  # Store original working directory
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(file.path(in_dir))
  
  # Initialize storage for results
  all_results <- list()
  all_exponent_params <- list()
  all_diagnostics <- list()
  
  if (verbose) {
    cat("\n")
    cat("================================================================================\n")
    cat("ADAPTIVE EXPONENT OPTIMIZATION\n")
    cat("================================================================================\n")
    cat("Configuration:\n")
    cat("  - SN exponent range:", sn_exponent_start, "→", sn_exponent_end, "\n")
    cat("  - Exponent method:", exponent_method, "\n")
    cat("  - Min correlation:", min_cor, "\n")
    cat("  - Phases:", paste(phases, collapse = ", "), "\n")
    cat("  - Years:", min(years), "-", max(years), "\n")
    cat("  - Formula: OPT = SN^x(year) × COR\n")
    cat("================================================================================\n\n")
  }
  
  # ============================================================================
  # MAIN LOOP: Process each phase
  # ============================================================================
  
  for (phase in phases) {
    
    if (verbose) {
      cat("Processing PHASE", phase, "...\n")
    }
    
    # --------------------------------------------------------------------------
    # STEP 1: Read and combine accuracy files for current phase
    # --------------------------------------------------------------------------
    
    files_cv <- list.files(pattern = "\\.csv$")
    pattern_phase <- paste0("OPT_", plant, "-", phase)
    files_phase <- mixedsort(grep(pattern_phase, files_cv, value = TRUE))
    
    if (length(files_phase) == 0) {
      warning(
        "No accuracy files found for PLANT = ", plant,
        ", PHASE = ", phase,
        " in directory: ", in_dir
      )
      next
    }
    
    # Read and combine all accuracy tables
    df_cv <- utils::read.csv2(files_phase[1], stringsAsFactors = FALSE)
    if (length(files_phase) > 1) {
      for (i in 2:length(files_phase)) {
        df_tmp <- utils::read.csv2(files_phase[i], stringsAsFactors = FALSE)
        df_cv <- rbind(df_cv, df_tmp)
      }
    }
    
    # Validate required columns
    required_cols <- c("SN", "COR", "YEAR")
    if (!all(required_cols %in% names(df_cv))) {
      stop("Expected columns ", paste(required_cols, collapse = ", "), 
           " not all present in accuracy table for phase ", phase)
    }
    
    # Filter to requested years
    df_cv <- df_cv[df_cv$YEAR %in% years, ]
    
    if (nrow(df_cv) == 0) {
      warning("No data for phase ", phase, " in years ", 
              min(years), "-", max(years))
      next
    }
    
    # --------------------------------------------------------------------------
    # STEP 2: Calculate year-specific adaptive exponents
    # --------------------------------------------------------------------------
    
    exponent_analysis <- calculate_exponents(
      df = df_cv,
      phase = phase,
      exponent_start = sn_exponent_start,
      exponent_end = sn_exponent_end,
      exponent_method = exponent_method,
      verbose = verbose
    )
    
    # Extract results
    year_params <- exponent_analysis$year_params
    
    # Store for output
    all_exponent_params[[as.character(phase)]] <- year_params
    
    # Merge year-specific exponents into data
    df_cv <- merge(df_cv, year_params[, c("YEAR", "sn_exponent")], 
                   by = "YEAR", all.x = TRUE)
    
    # --------------------------------------------------------------------------
    # STEP 3: Calculate optimization metric with year-specific exponents
    # --------------------------------------------------------------------------
    
    # Metric: SN^x(year) × COR (year-specific exponent only)
    df_cv$OPT <- with(df_cv, (SN ^ sn_exponent) * COR)
    
    # Apply minimum correlation constraint
    df_cv$OPT[df_cv$COR < min_cor] <- -Inf
    
    # Add normalized version for comparison
    df_cv$OPT_normalized <- with(df_cv, {
      sn_max <- max(SN, na.rm = TRUE)
      ((SN / sn_max) ^ sn_exponent) * COR
    })
    
    # --------------------------------------------------------------------------
    # STEP 4: Export all variants with OPT scores
    # --------------------------------------------------------------------------
    
    out_all_name <- paste0("OPT_ALL_", plant, "-", phase, ".csv")
    utils::write.csv2(
      df_cv,
      file = out_all_name,
      row.names = FALSE
    )
    
    if (verbose) {
      cat("  - Wrote all variants:", out_all_name, "\n")
    }
    
    # --------------------------------------------------------------------------
    # STEP 5: Select optimal variant per year
    # --------------------------------------------------------------------------
    
    df_cv_max <- data.frame(
      matrix(nrow = 0, ncol = ncol(df_cv))
    )
    colnames(df_cv_max) <- colnames(df_cv)
    
    for (yr in years) {
      df_year <- df_cv[df_cv$YEAR == yr, , drop = FALSE]
      df_year <- stats::na.omit(df_year)
      
      if (nrow(df_year) == 0) {
        next
      }
      
      # Select row with maximum OPT
      valid_opts <- df_year$OPT[is.finite(df_year$OPT)]
      if (length(valid_opts) == 0) {
        warning("No valid OPT values for year ", yr, ", phase ", phase)
        next
      }
      
      idx_best <- which(df_year$OPT == max(df_year$OPT, na.rm = TRUE))[1]
      df_year_best <- df_year[idx_best, , drop = FALSE]
      df_cv_max <- rbind(df_cv_max, df_year_best)
      
      # Export optimal shapefile (if sf available and file exists)
      if (requireNamespace("sf", quietly = TRUE)) {
        shp_file <- paste0(
          "DOY_", df_year_best$PLANT, "-", df_year_best$PHASE,
          "_", df_year_best$YEAR, "_FSTD", df_year_best$STD * 10, ".shp"
        )
        
        if (file.exists(shp_file)) {
          opt_shp <- sf::st_read(shp_file, quiet = TRUE)
          out_shp <- paste0(
            "DOY_", df_year_best$PLANT, "-", df_year_best$PHASE,
            "_", df_year_best$YEAR, ".shp"
          )
          sf::st_write(opt_shp, out_shp, delete_layer = TRUE, quiet = TRUE)
        }
      }
    }
    
    # --------------------------------------------------------------------------
    # STEP 6: Export best-per-year table
    # --------------------------------------------------------------------------
    
    out_max_name <- paste0("OPT_MAX_", plant, "-", phase, ".csv")
    utils::write.csv2(
      df_cv_max,
      file = out_max_name,
      row.names = FALSE
    )
    
    if (verbose) {
      cat("  - Wrote optimal variants:", out_max_name, "\n")
      cat("  - Selected", nrow(df_cv_max), "optimal variants\n")
    }
    
    # --------------------------------------------------------------------------
    # STEP 7: Generate diagnostics
    # --------------------------------------------------------------------------
    
    diagnostics <- generate_diagnostics(
      df_all = df_cv,
      df_best = df_cv_max,
      year_params = year_params,
      phase = phase,
      verbose = verbose
    )
    
    # Store diagnostics
    all_diagnostics[[as.character(phase)]] <- diagnostics
    
    # Export diagnostic plots if requested
    if (export_diagnostics && requireNamespace("ggplot2", quietly = TRUE)) {
      export_diagnostic_plots(
        df_all = df_cv,
        df_best = df_cv_max,
        year_params = year_params,
        diagnostics = diagnostics,
        phase = phase,
        plant = plant
      )
    }
    
    # Store results
    all_results[[as.character(phase)]] <- list(
      all_variants = df_cv,
      best_variants = df_cv_max
    )
    
    if (verbose) {
      cat("  - Phase", phase, "complete.\n\n")
    }
  }
  
  # ============================================================================
  # FINAL OUTPUT
  # ============================================================================
  
  # Combine all phases
  df_all_combined <- do.call(rbind, lapply(all_results, function(x) x$all_variants))
  df_best_combined <- do.call(rbind, lapply(all_results, function(x) x$best_variants))
  df_params_combined <- do.call(rbind, lapply(names(all_exponent_params), function(p) {
    df <- all_exponent_params[[p]]
    df$PHASE <- as.numeric(p)
    df
  }))
  
  # Export combined tables
  utils::write.csv2(
    df_all_combined,
    file = paste0("OPT_ALL_", plant, "_ALL_PHASES.csv"),
    row.names = FALSE
  )
  
  utils::write.csv2(
    df_best_combined,
    file = paste0("OPT_MAX_", plant, "_ALL_PHASES.csv"),
    row.names = FALSE
  )
  
  utils::write.csv2(
    df_params_combined,
    file = paste0("OPT_", plant, "_EXPONENTS_ALL_PHASES.csv"),
    row.names = FALSE
  )
  
  if (verbose) {
    cat("================================================================================\n")
    cat("OPTIMIZATION COMPLETE\n")
    cat("================================================================================\n")
    cat("Output files:\n")
    cat("  - Individual phase OPT_ALL files: OPT_ALL_", plant,"-",phase,".csv\n", sep = "")
    cat("  - Individual phase OPT_MAX files: OPT_MAX_", plant,"-",phase,".csv\n", sep = "")
    cat("  - Combined all phases: OPT_ALL_", plant, "_ALL_PHASES.csv\n", sep = "")
    cat("  - Combined best variants: OPT_MAX_", plant, "_ALL_PHASES.csv\n", sep = "")
    cat("  - Exponent parameters: OPT_", plant, "_EXPONENTS_ALL_PHASES.csv\n", sep = "")
    if (export_diagnostics) {
      cat("  - Diagnostic plots: OPT_",plant,"-",phase,"_DIAGNOSTICS.pdf\n",sep="")
    }
    cat("================================================================================\n\n")
  }
  
  # Return comprehensive results
  invisible(
    list(
      all_variants = df_all_combined,
      best_variants = df_best_combined,
      exponent_parameters = df_params_combined,
      diagnostics = all_diagnostics,
      config = list(
        sn_exponent_start = sn_exponent_start,
        sn_exponent_end = sn_exponent_end,
        exponent_method = exponent_method,
        min_cor = min_cor
      )
    )
  )
}


################################################################################
# HELPER FUNCTION: Calculate Adaptive Exponents
################################################################################

#' Calculate year-specific adaptive exponents (no temporal weighting)
#' 
#' @param df Data frame with SN, COR, YEAR columns
#' @param phase Integer. Current phenological phase
#' @param exponent_start Numeric. Starting exponent value
#' @param exponent_end Numeric. Ending exponent value
#' @param exponent_method Character. Method for exponent calculation
#' @param verbose Logical. Print diagnostic info
#' 
#' @return List with year_params data frame and analysis info
calculate_exponents <- function(df, phase, exponent_start, exponent_end,
                                              exponent_method = "decline_based",
                                              verbose = TRUE) {
  
  # Calculate year-level statistics
  year_stats <- aggregate(
    cbind(SN, COR) ~ YEAR,
    data = df,
    FUN = function(x) c(mean = mean(x, na.rm = TRUE), 
                        median = median(x, na.rm = TRUE),
                        sd = sd(x, na.rm = TRUE))
  )
  
  # Flatten the aggregated structure
  year_stats <- data.frame(
    YEAR = year_stats$YEAR,
    SN_mean = year_stats$SN[, "mean"],
    SN_median = year_stats$SN[, "median"],
    SN_sd = year_stats$SN[, "sd"],
    COR_mean = year_stats$COR[, "mean"],
    COR_median = year_stats$COR[, "median"],
    COR_sd = year_stats$COR[, "sd"]
  )
  
  # Detect trend in sample numbers
  if (nrow(year_stats) >= 3) {
    sn_trend <- stats::lm(SN_mean ~ YEAR, data = year_stats)
    sn_slope <- stats::coef(sn_trend)[2]
    sn_pvalue <- summary(sn_trend)$coefficients[2, 4]
    trend_detected <- (sn_pvalue < 0.05) && (sn_slope < 0)
  } else {
    sn_slope <- 0
    sn_pvalue <- 1
    trend_detected <- FALSE
  }
  
  # --------------------------------------------------------------------------
  # CALCULATE YEAR-SPECIFIC EXPONENTS
  # --------------------------------------------------------------------------
  
  if (exponent_method == "decline_based") {
    # Method 1: Based on actual sample number decline
    # Exponent increases as sample numbers decrease
    
    sn_max <- max(year_stats$SN_mean, na.rm = TRUE)
    sn_min <- min(year_stats$SN_mean, na.rm = TRUE)
    sn_range <- sn_max - sn_min
    
    if (sn_range > 0) {
      # Normalized decline: 0 (highest SN) to 1 (lowest SN)
      year_stats$sn_decline <- (sn_max - year_stats$SN_mean) / sn_range
      
      # Map decline to exponent range
      # High SN → exponent_start (e.g., 1.0)
      # Low SN → exponent_end (e.g., 1.5)
      year_stats$sn_exponent <- exponent_start + 
        (exponent_end - exponent_start) * year_stats$sn_decline
    } else {
      # No variation in SN: use midpoint
      year_stats$sn_decline <- 0
      year_stats$sn_exponent <- (exponent_start + exponent_end) / 2
    }
    
    method_desc <- "decline-based (high SN → low exponent, low SN → high exponent)"
    
  } else if (exponent_method == "linear_time") {
    # Method 2: Linear interpolation over time
    # Exponent increases linearly from earliest to latest year
    
    year_min <- min(year_stats$YEAR)
    year_max <- max(year_stats$YEAR)
    year_range <- year_max - year_min
    
    if (year_range > 0) {
      # Normalized time: 0 (earliest year) to 1 (latest year)
      year_stats$time_progress <- (year_stats$YEAR - year_min) / year_range
      
      # Map time to exponent range
      year_stats$sn_exponent <- exponent_start + 
        (exponent_end - exponent_start) * year_stats$time_progress
      
      year_stats$sn_decline <- year_stats$time_progress  # For consistency
    } else {
      # Single year: use midpoint
      year_stats$time_progress <- 0
      year_stats$sn_decline <- 0
      year_stats$sn_exponent <- (exponent_start + exponent_end) / 2
    }
    
    method_desc <- "linear-time (old years → low exponent, recent years → high exponent)"
    
  } else {
    stop("Unknown exponent_method: ", exponent_method)
  }
  
  # Print diagnostics
  if (verbose) {
    cat("  - Adaptive exponent analysis:\n")
    cat("    * Years analyzed:", nrow(year_stats), "\n")
    cat("    * SN trend slope:", round(sn_slope, 2), "(p =", round(sn_pvalue, 4), ")\n")
    cat("    * Trend detected:", trend_detected, "\n")
    cat("    * Exponent method:", method_desc, "\n")
    cat("    * Exponent range:", round(min(year_stats$sn_exponent), 3), "→", 
        round(max(year_stats$sn_exponent), 3), "\n")
    cat("    * SN range:", round(min(year_stats$SN_mean), 1), "→", 
        round(max(year_stats$SN_mean), 1), "\n")
  }
  
  # Return results
  list(
    year_params = year_stats,
    trend_slope = sn_slope,
    trend_pvalue = sn_pvalue,
    trend_detected = trend_detected,
    exponent_method = exponent_method
  )
}


################################################################################
# HELPER FUNCTION: Generate Diagnostics
################################################################################

#' Generate diagnostic statistics for optimization
#' 
#' @param df_all Data frame with all variants
#' @param df_best Data frame with best variants per year
#' @param year_params Data frame with year-specific parameters
#' @param phase Integer. Current phase
#' @param verbose Logical. Print diagnostics
#' 
#' @return List with diagnostic information
generate_diagnostics <- function(df_all, df_best, year_params, 
                                      phase, verbose = TRUE) {
  
  # Summary statistics for optimal selections
  summary_stats <- data.frame(
    Metric = c("Sample Number (SN)", "Correlation (COR)", "MAE", "Exponent"),
    Mean = c(
      mean(df_best$SN, na.rm = TRUE),
      mean(df_best$COR, na.rm = TRUE),
      mean(df_best$MAE, na.rm = TRUE),
      mean(df_best$sn_exponent, na.rm = TRUE)
    ),
    Median = c(
      median(df_best$SN, na.rm = TRUE),
      median(df_best$COR, na.rm = TRUE),
      median(df_best$MAE, na.rm = TRUE),
      median(df_best$sn_exponent, na.rm = TRUE)
    ),
    SD = c(
      sd(df_best$SN, na.rm = TRUE),
      sd(df_best$COR, na.rm = TRUE),
      sd(df_best$MAE, na.rm = TRUE),
      sd(df_best$sn_exponent, na.rm = TRUE)
    ),
    Min = c(
      min(df_best$SN, na.rm = TRUE),
      min(df_best$COR, na.rm = TRUE),
      min(df_best$MAE, na.rm = TRUE),
      min(df_best$sn_exponent, na.rm = TRUE)
    ),
    Max = c(
      max(df_best$SN, na.rm = TRUE),
      max(df_best$COR, na.rm = TRUE),
      max(df_best$MAE, na.rm = TRUE),
      max(df_best$sn_exponent, na.rm = TRUE)
    )
  )
  
  # Threshold distribution
  threshold_dist <- table(df_best$STD)
  
  # Exponent statistics
  exponent_stats <- data.frame(
    Min_Exponent = min(year_params$sn_exponent),
    Max_Exponent = max(year_params$sn_exponent),
    Mean_Exponent = mean(year_params$sn_exponent),
    SD_Exponent = sd(year_params$sn_exponent),
    Min_SN = min(year_params$SN_mean),
    Max_SN = max(year_params$SN_mean),
    SN_Decline_Pct = 100 * (1 - min(year_params$SN_mean) / max(year_params$SN_mean))
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
  
  list(
    summary_stats = summary_stats,
    threshold_dist = threshold_dist,
    exponent_stats = exponent_stats
  )
}


################################################################################
# HELPER FUNCTION: Export Diagnostic Plots
################################################################################

#' Export diagnostic plots to PDF for adaptive optimization
#' 
#' @param df_all Data frame with all variants
#' @param df_best Data frame with best variants
#' @param year_params Data frame with year-specific parameters
#' @param diagnostics List with diagnostic info
#' @param phase Integer. Current phase
#' @param plant Integer. Plant identifier
export_diagnostic_plots <- function(df_all, df_best, year_params, 
                                         diagnostics, phase, plant) {
  
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    warning("ggplot2 not available. Skipping diagnostic plots.")
    return(invisible(NULL))
  }
  
  library(ggplot2)
  
  # Create PDF device
  pdf_name <- paste0("OPT_", plant, "-", phase, "_DIAGNOSTICS.pdf")
  grDevices::pdf(pdf_name, width = 11, height = 8.5)
  
  # Plot 1: Adaptive exponents over time
  p1 <- ggplot(year_params, aes(x = YEAR, y = sn_exponent)) +
    geom_line(color = "darkgreen", size = 1.2) +
    geom_point(size = 3, color = "darkgreen") +
    geom_hline(yintercept = 1.0, linetype = "dashed", color = "gray50", alpha = 0.7) +
    labs(
      title = paste("Adaptive Exponents Over Time - Phase", phase),
      subtitle = "Exponent-based optimization (no temporal weighting)",
      x = "Year",
      y = "SN Exponent (x)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p1)
  
  # Plot 2: Sample numbers and exponents (dual visualization)
  p2 <- ggplot(year_params, aes(x = YEAR)) +
    geom_col(aes(y = SN_mean / max(SN_mean) * max(sn_exponent)), 
             fill = "steelblue", alpha = 0.5) +
    geom_line(aes(y = sn_exponent), color = "darkgreen", size = 1.2) +
    geom_point(aes(y = sn_exponent), color = "darkgreen", size = 3) +
    labs(
      title = paste("Sample Numbers vs Adaptive Exponents - Phase", phase),
      subtitle = "Bars = normalized SN, Line = adaptive exponent",
      x = "Year",
      y = "Value (normalized scale)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p2)
  
  # Plot 3: Exponent vs SN decline relationship
  p3 <- ggplot(year_params, aes(x = SN_mean, y = sn_exponent)) +
    geom_point(size = 3, color = "darkgreen") +
    geom_smooth(method = "loess", se = TRUE, color = "darkgreen", fill = "green", alpha = 0.2) +
    labs(
      title = paste("Exponent Response to Sample Decline - Phase", phase),
      subtitle = "Lower SN → Higher exponent (stronger emphasis)",
      x = "Mean Sample Number (SN)",
      y = "Adaptive Exponent (x)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p3)
  
  # Plot 4: Sample numbers over time (all variants + optimal)
  p4 <- ggplot() +
    geom_point(data = df_all, aes(x = YEAR, y = SN), 
               alpha = 0.2, color = "gray50") +
    geom_line(data = df_best, aes(x = YEAR, y = SN), 
              color = "red", size = 1.2) +
    geom_point(data = df_best, aes(x = YEAR, y = SN), 
               color = "red", size = 3) +
    geom_smooth(data = df_best, aes(x = YEAR, y = SN), 
                method = "loess", se = TRUE, color = "darkred") +
    labs(
      title = paste("Sample Numbers Over Time - Phase", phase),
      subtitle = "Gray points = all variants, Red line = optimal selections",
      x = "Year",
      y = "Sample Number (SN)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p4)
  
  # Plot 5: Correlation over time
  p5 <- ggplot() +
    geom_point(data = df_all, aes(x = YEAR, y = COR), 
               alpha = 0.2, color = "gray50") +
    geom_line(data = df_best, aes(x = YEAR, y = COR), 
              color = "blue", size = 1.2) +
    geom_point(data = df_best, aes(x = YEAR, y = COR), 
               color = "blue", size = 3) +
    geom_hline(yintercept = 0.70, linetype = "dashed", color = "red") +
    labs(
      title = paste("Correlation Quality Over Time - Phase", phase),
      subtitle = "Gray points = all variants, Blue line = optimal selections",
      x = "Year",
      y = "Correlation (COR)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p5)
  
  # Plot 6: SN vs COR trade-off
  p6 <- ggplot() +
    geom_point(data = df_all, aes(x = SN, y = COR, color = OPT), 
               alpha = 0.5, size = 2) +
    geom_point(data = df_best, aes(x = SN, y = COR), 
               color = "red", size = 4, shape = 1, stroke = 2) +
    scale_color_viridis_c(name = "OPT\nScore") +
    labs(
      title = paste("Sample-Correlation Trade-off - Phase", phase),
      subtitle = "Red circles = optimal selections (adaptive exponents)",
      x = "Sample Number (SN)",
      y = "Correlation (COR)"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p6)
  
  # Plot 7: Threshold distribution
  threshold_df <- as.data.frame(diagnostics$threshold_dist)
  colnames(threshold_df) <- c("STD", "Count")
  
  p7 <- ggplot(threshold_df, aes(x = STD, y = Count)) +
    geom_col(fill = "steelblue", alpha = 0.8) +
    geom_text(aes(label = Count), vjust = -0.5, size = 4) +
    labs(
      title = paste("Selected STD Thresholds - Phase", phase),
      subtitle = "Frequency of optimal threshold selections across years",
      x = "STD Threshold",
      y = "Count"
    ) +
    theme_minimal(base_size = 12) +
    theme(plot.title = element_text(face = "bold"))
  
  print(p7)
  
  # Plot 8: OPT distribution by year
  p8 <- ggplot(df_best, aes(x = factor(YEAR), y = OPT)) +
    geom_col(fill = "steelblue", alpha = 0.8) +
    labs(
      title = paste("OPT Scores by Year - Phase", phase),
      subtitle = "Formula: SN^x(year) × COR",
      x = "Year",
      y = "OPT Score"
    ) +
    theme_minimal(base_size = 12) +
    theme(
      plot.title = element_text(face = "bold"),
      axis.text.x = element_text(angle = 45, hjust = 1)
    )
  
  print(p8)
  
  # Close PDF device
  grDevices::dev.off()
  
  invisible(pdf_name)
}
################################################################################
# USAGE EXAMPLE
# ==============================================================================
#
## Basic usage with defaults
# results <- filter_variant_selector(
#   in_dir = "./output/",
#   plant = 202,
#   phases = c(10, 12, 15, 18, 19, 21, 24),
#   years = 1993:2022
# )
# 
## Custom exponent range
# results <- filter_variant_selector(
#   in_dir = "./output/",
#   plant = 202,
#   phases = 24,
#   years = 1993:2024,
#   sn_exponent_start = 0.9,
#   sn_exponent_end = 1.8
# )


################################################################################
# END OF FILE
################################################################################
