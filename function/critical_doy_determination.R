################################################################################
# Critical DOY Determination Function for Phenological Analysis
################################################################################
#
# PURPOSE:
#   Determine the critical day-of-year (DOY) when a specific temperature sum 
#   quantile threshold is exceeded. Performs optimization across multiple 
#   quantile candidates to identify the thermal accumulation threshold that 
#   best predicts observed phenological dates. Includes outlier filtering,
#   accuracy assessment, and spatial export of validated predictions.
#
# AUTHORS:
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#
# DATA SOURCE:
#   Input: Thermal time summation data (from function effective_temperature_calculation())
#
# DEPENDENCIES:
#   - R >= 4.0.0
#   - sp (for spatial data handling)
#   - raster (for shapefile export)
#
# CITATION:
#   If you use this code in your research, please cite:
#   Möller, M. (2026). critical_doy_determination: Critical DOY determination tool for phenological analysis.
#   Available at: [repository URL - add when published]
#
# LICENSE:
#   This code is provided under the MIT License
#
################################################################################

# ==============================================================================
# FUNCTION: critical_doy_determination()
# ==============================================================================
#
# PURPOSE:
#   Identify the optimal temperature sum quantile threshold that minimizes
#   prediction error when forecasting phenological dates. Iteratively tests
#   quantile candidates between user-specified bounds (q1, q2), calculates
#   the corresponding critical DOY for each station, removes outliers, and
#   evaluates prediction accuracy using correlation, RMSE, and MAE metrics.
#
#   Returns quantile-specific accuracy statistics and filtered spatial data
#   for the best-performing model configuration.
#
# ARGUMENTS:
#
# pheno_data (SpatialPointsDataFrame, REQUIRED):
#   - Thermal time summation data with spatial attributes
#   - Required attributes (pheno_data@data):
#     * STATION: Meteorological station ID (numeric)
#     * YEAR: Reference/harvest year (numeric, calendar year)
#     * PLANT: Crop object ID using DWD codes
#     * PHASE: Phenological phase ID (numeric)
#     * DOY: Observed day of year for target phase (numeric, 1-366)
#     * DOY_START: Day of year for start phase reference (numeric)
#     * T_SUMS: Cumulative effective temperature (GDD) from DOY_START to DOY
#       - Units: °C × 10 (following DWD convention)
#     * T[DOY]: Daily temperature columns (T1, T2, ..., T366)
#       - Individual daily effective temperatures
#       - Column names extracted with pattern T[1-366]
#   - Output from effective_temperature_calculation() or equivalent
#   - CRS should be standardized (typically EPSG:4326 or projected)
#
# output_dir (character, REQUIRED):
#   - Full path to directory for output file storage
#   - Directory must exist and be writable
#   - Outputs:
#     1. CSV: OPT_[PLANT]-[PHASE]_[YEAR]_FSTD[f_std*10].csv
#        - Quantile-specific accuracy metrics
#     2. Shapefile: DOY_[PLANT]-[PHASE]_[YEAR]_FSTD[f_std*10].shp
#        - Filtered spatial predictions (best model)
#
# f_std (numeric, default = 1):
#   - Outlier removal threshold multiplier (standard deviation units)
#   - Stations retained if: |doy_phase - doy| <= f_std × sd(doy)
#   - Typical values:
#     * 1.0: Strict filtering (~68% of normal distribution retained)
#     * 1.5: Moderate filtering (~93% retained)
#     * 2.0: Lenient filtering (~95% retained)
#   - Lower values: More aggressive outlier removal, reduced sample size
#   - Higher values: More tolerant of prediction errors, larger sample
#
# q1 (numeric, REQUIRED):
#   - Lower bound of quantile search range (0 < q1 < q2 < 1)
#   - Defines minimum temperature sum percentile to test
#   - Example: q1 = 0.3 tests 30th percentile and above
#   - Crop-specific guidance:
#     * Early-season phases (emergence): 0.2-0.4
#     * Mid-season phases (flowering): 0.3-0.5
#     * Late-season phases (maturity): 0.4-0.6
#
# q2 (numeric, REQUIRED):
#   - Upper bound of quantile search range (q1 < q2 < 1)
#   - Defines maximum temperature sum percentile to test
#   - Example: q2 = 0.7 tests up to 70th percentile
#   - Search resolution: Quantiles tested in 0.05 increments
#   - Wider ranges (q2 - q1) increase computation time linearly
#
# RETURNS:
#   result (list with 2 elements):
#   
#   1. quantile_accuracy (data.frame):
#      - Accuracy metrics for each tested quantile
#      - Columns:
#        * Q: Quantile value tested (0-1 scale)
#        * RMSE: Root Mean Square Error (days)
#          - Formula: sqrt(mean((doy_observed - doy_predicted)^2))
#        * MAE: Mean Absolute Error (days)
#          - Formula: mean(|doy_observed - doy_predicted|)
#        * SN: Sample size (number of stations after outlier removal)
#        * COR: Pearson correlation coefficient
#          - Measures linear relationship between observed and predicted DOY
#        * YEAR: Reference year (from input data)
#        * STD: Outlier filter threshold used (f_std value)
#        * PLANT: Crop ID (from input data)
#        * PHASE: Phenological phase ID (from input data)
#      - Rows sorted by quantile value (ascending)
#   
#   2. pheno_data_filtered (SpatialPointsDataFrame):
#      - Spatial data for best-performing quantile model
#      - Same structure as input pheno_data with added column:
#        * DOY_PHASE: Predicted day of year for target phase
#          - Calculated first DOY when cumulative temperature exceeds
#            optimal quantile threshold
#      - Rows: Only stations passing outlier filter
#      - Retained spatial attributes and CRS from input
#
# SIDE EFFECTS:
#   1. Console messages: 
#      - Progress bar showing quantile optimization iterations
#      - Reports optimal quantile and corresponding MAE
#   
#   2. File outputs:
#      a. CSV export (accuracy metrics):
#         - Path: [output_dir]/OPT_[PLANT]-[PHASE]_[YEAR]_FSTD[f_std*10].csv
#         - Format: Semicolon-delimited text file with header
#         - Encoding: Standard (locale-dependent)
#         - Example filename: OPT_202-25_2024_FSTD10.csv
#      
#      b. Shapefile export (spatial predictions):
#         - Path: [output_dir]/DOY_[PLANT]-[PHASE]_[YEAR]_FSTD[f_std*10].shp
#         - Format: ESRI Shapefile with .shp, .dbf, .shx, .prj components
#         - CRS: Inherited from input pheno_data
#         - Example filename: DOY_202-25_2024_FSTD10.shp
#         - Overwrites existing files if present
#
# ALGORITHM OVERVIEW:
#   
#   1. CUMULATIVE TEMPERATURE CALCULATION:
#      - Input: Daily effective temperatures (columns T[doy_start] to T[doy])
#      - Process: Row-wise cumulative summation from start to observed DOY
#      - Output: Matrix of cumulative temperatures at each DOY for each station
#   
#   2. QUANTILE OPTIMIZATION LOOP:
#      For each quantile q in seq(q1, q2, by=0.05):
#        a. Calculate threshold: median = quantile(T_SUMS, q)
#        b. For each station:
#           - Find first DOY where cumulative temperature > median
#           - Store as predicted DOY (doy_phase)
#        c. Apply outlier filter: remove stations with |error| > f_std × sd
#        d. Calculate accuracy metrics: RMSE, MAE, COR, SN
#        e. Update best model if MAE improved
#   
#   3. EXPORT RESULTS:
#      - Save quantile-accuracy table to CSV
#      - Save best model predictions to shapefile
#      - Return both datasets as list
#
# QUANTILE SELECTION RATIONALE:
#   - Lower quantiles (e.g., 0.3): More conservative thresholds
#     * Earlier predicted DOY
#     * Suitable for risk-averse forecasting (e.g., frost protection)
#   - Higher quantiles (e.g., 0.7): More permissive thresholds
#     * Later predicted DOY
#     * Better for average-condition forecasting
#   - Optimal quantile often crop- and phase-specific:
#     * Reflects natural variability in temperature sensitivity
#     * Accounts for microclimatic differences across stations
#
# OUTLIER FILTERING LOGIC:
#   - Filters applied AFTER prediction for each quantile candidate
#   - Criterion: |doy_observed - doy_predicted| <= f_std × sd(doy_observed)
#   - Purpose:
#     * Remove stations with systematic bias (e.g., elevation effects)
#     * Exclude measurement errors or unusual microclimates
#     * Improve model accuracy metrics by focusing on typical stations
#   - Trade-off: Smaller sample size vs. better accuracy metrics
#
# ACCURACY METRICS INTERPRETATION:
#   
#   RMSE (Root Mean Square Error):
#   - Penalizes large errors more than small errors (quadratic)
#   - Units: Days
#   - Typical values: 3-7 days for well-calibrated models
#   - Use: Sensitive to outliers; emphasizes worst-case performance
#   
#   MAE (Mean Absolute Error):
#   - Equal weight to all errors (linear)
#   - Units: Days
#   - Typical values: 2-5 days for well-calibrated models
#   - Use: Robust to outliers; easier to interpret than RMSE
#   
#   COR (Pearson Correlation):
#   - Measures linear relationship strength
#   - Range: -1 to +1 (typically 0.6-0.9 for phenology)
#   - Use: Assesses model's ability to capture spatial/temporal patterns
#   
#   SN (Sample Size):
#   - Number of stations after outlier removal
#   - Trade-off: Higher accuracy vs. reduced spatial coverage
#   - Minimum recommended: 20-30 stations for robust statistics
#
# DATA QUALITY CONSIDERATIONS:
#   - Assumes input T_SUMS is pre-calculated (from effective_temperature_calculation)
#   - Assumes daily temperature columns (T1, T2, ...) are cumulative-ready
#   - No missing value handling (assumes complete thermal time data)
#   - Spatial consistency: All stations assumed to share same CRS
#
# COMPUTATIONAL COMPLEXITY:
#   - Quantile candidates: (q2 - q1) / 0.05 iterations
#   - Per iteration: O(n × m) where n = stations, m = DOY range
#   - Example: 50 stations, 100 DOY range, 8 quantiles → ~40,000 operations
#   - Memory: Cumulative temperature matrix requires n × m numeric storage
#
# ERRORS & WARNINGS:
#   - Error: Missing required columns in pheno_data@data
#   - Error: q1 >= q2 (invalid quantile range)
#   - Error: f_std <= 0 (invalid outlier threshold)
#   - Error: output_dir does not exist or is not writable
#   - Warning: If all quantiles yield same MAE (model insensitive)
#   - Warning: If SN drops below 10 stations (insufficient sample)
#
# ASSUMPTIONS & LIMITATIONS:
#   1. Phenological dates follow temperature-driven model (no other factors)
#   2. Quantile threshold is spatially uniform (no regional variation)
#   3. Outlier filter assumes normal distribution of errors
#   4. Optimal quantile stable across years (not validated for multi-year)
#   5. No cross-validation or independent test set (same data for calibration)
#   6. Fixed quantile resolution (0.05) may miss finer optima
#
# ==============================================================================

ensure_packages <- function(pkg_list) {
  # Loop through each package in the list
  for (pkg in pkg_list) {
    # Check if package is already installed and available
    if (!requireNamespace(pkg, quietly = TRUE)) {
      # If not, inform user and attempt installation
      message("Installing package: ", pkg)
      install.packages(pkg, quiet = TRUE)
    }
    # Load package into current session for use
    library(pkg, character.only = TRUE, quietly = TRUE)
  }
  # Confirm successful loading to user
  message("All required packages loaded successfully!")
}

# ==============================================================================
# DEPENDENCY LOADING
# ==============================================================================
ensure_packages(c("sp", "raster"))

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

critical_doy_determination <- function(pheno_data,
                                       output_dir,
                                       f_std = 1,
                                       q1,
                                       q2) {
  
  # ---------------------------------------------------------------------------
  # INPUT VALIDATION
  # ---------------------------------------------------------------------------
  
  message(
    "Determining critical DOY for temperature sum quantile threshold...\n",
    "Data source: ", class(pheno_data)[1], " with ",
    nrow(pheno_data), " observations"
  )
  
  # Check required attributes in spatial data
  required_attrs <- c("STATION", "YEAR", "PLANT", "PHASE", 
                      "DOY", "DOY_START", "T_SUMS")
  missing_attrs <- setdiff(required_attrs, names(pheno_data@data))
  
  if (length(missing_attrs) > 0) {
    stop(
      "Missing required attributes in pheno_data@data: ",
      paste(missing_attrs, collapse = ", "),
      "\nExpected from effective_temperature_calculation(): ",
      paste(required_attrs, collapse = ", ")
    )
  }
  
  # Validate quantile range
  if (q1 >= q2) {
    stop("Invalid quantile range: q1 (", q1, ") must be < q2 (", q2, ")")
  }
  
  if (q1 <= 0 || q2 >= 1) {
    stop("Quantile bounds must be in range (0, 1). Received: q1=", q1, ", q2=", q2)
  }
  
  # Validate outlier threshold
  if (f_std <= 0) {
    stop("Outlier threshold f_std must be > 0. Received: ", f_std)
  }
  
  # Verify output directory exists
  if (!dir.exists(output_dir)) {
    stop(
      "Output directory not found: ", output_dir,
      "\nPlease create directory before running function."
    )
  }
  
  # ---------------------------------------------------------------------------
  # EXTRACT METADATA
  # ---------------------------------------------------------------------------
  
  # Extract unique identifiers from input data
  year <- unique(pheno_data@data$YEAR)[1]
  plant <- unique(pheno_data@data$PLANT)[1]
  phase <- unique(pheno_data@data$PHASE)[1]
  
  message(
    "Phenological parameters: ",
    "Crop ID = ", plant, " | ",
    "Phase ID = ", phase, " | ",
    "Year = ", year
  )
  
  # ---------------------------------------------------------------------------
  # STEP 1: CALCULATE CUMULATIVE TEMPERATURE SUMS
  # ---------------------------------------------------------------------------
  
  message("Calculating cumulative temperature sums from DOY_START to DOY...")
  
  # Import thermal time data from effective_temperature_calculation
  pheno_data_temp <- pheno_data
  
  # Initialize cumulative sum matrix (copy of original data)
  cumsums_pheno <- pheno_data_temp
  
  # Row-wise cumulative summation across daily temperature columns
  for (i in 1:nrow(cumsums_pheno)) {
    
    # Identify column range: T[DOY_START] to T[DOY-1]
    # Note: Excludes T_SUMS column itself
    start_col <- which(
      names(cumsums_pheno) == paste0("T", cumsums_pheno$DOY_START[i])
    )
    end_col <- which(names(cumsums_pheno) == "T_SUMS") - 1
    
    # Apply cumulative sum across column range
    cols_to_cumsum <- start_col:end_col
    cumsums_pheno@data[i, cols_to_cumsum] <- cumsum(
      as.matrix(cumsums_pheno@data[i, cols_to_cumsum])
    )
  }
  
  message("Cumulative sums calculated for ", nrow(cumsums_pheno), " stations")
  
  # ---------------------------------------------------------------------------
  # STEP 2: INITIALIZE PREDICTION COLUMN
  # ---------------------------------------------------------------------------
  
  # Add predicted DOY column (initialized to 0)
  pheno_data_temp@data["DOY_PHASE"] <- 0
  
  # ---------------------------------------------------------------------------
  # STEP 3: QUANTILE OPTIMIZATION SETUP
  # ---------------------------------------------------------------------------
  
  message(
    "Optimizing quantile threshold in range [", q1, ", ", q2, "]",
    " with resolution 0.05"
  )
  
  # Initialize tracking variables
  mae_min <- 50  # Initial MAE (days) - will be updated during optimization
  q_min <- q1    # Best quantile found (initialized to lower bound)
  
  # Set up quantiles data frame for accuracy tracking
  quantiles <- data.frame(
    Q = seq(from = q1, to = q2, by = 0.05),
    RMSE = 0,
    MAE = 0,
    SN = 0,
    COR = 0
  )
  
  # ---------------------------------------------------------------------------
  # STEP 4: QUANTILE OPTIMIZATION LOOP (Core Algorithm)
  # ---------------------------------------------------------------------------
  
  message("Calculating quantile variants (", nrow(quantiles), " candidates)...")
  
  # Initialize progress bar for user feedback
  total <- nrow(quantiles)
  pq <- txtProgressBar(min = 0, max = total, style = 3)
  
  for (q in seq(1, nrow(quantiles))) {
    
    # Calculate temperature sum threshold for current quantile
    med <- quantile(pheno_data_temp$T_SUMS, quantiles$Q[q], na.rm = TRUE)
    
    # -------------------------------------------------------------------------
    # CRITICAL DOY DETERMINATION (Per Station)
    # -------------------------------------------------------------------------
    
    for (i in seq(1, nrow(pheno_data_temp))) {
      
      # Extract cumulative temperatures for current station
      # Range: T[DOY_START] to last daily column before T_SUMS
      start_col_name <- paste0("T", cumsums_pheno$DOY_START[i])
      start_idx <- which(names(cumsums_pheno) == start_col_name)
      end_idx <- which(names(cumsums_pheno) == "T_SUMS") - 1
      
      col <- cumsums_pheno[i, start_idx:end_idx]
      
      # Extract DOY values from column names (e.g., "T123" → 123)
      col.names <- as.numeric(substr(names(col), start = 2, stop = 7))
      
      # Find first DOY where cumulative temperature exceeds threshold
      exceeds_threshold <- which(col@data > med)
      
      if (length(exceeds_threshold) > 0) {
        doy_crit <- min(col.names[exceeds_threshold])
      } else {
        # If threshold never exceeded, assign NA
        doy_crit <- NA
      }
      
      # Store predicted DOY
      pheno_data_temp@data$DOY_PHASE[i] <- as.numeric(doy_crit)
    }
    
    # -------------------------------------------------------------------------
    # OUTLIER FILTERING (Per Quantile)
    # -------------------------------------------------------------------------
    
    # Copy predictions for current quantile candidate
    pheno_data_opt <- pheno_data_temp
    
    # Calculate prediction error standard deviation
    error_sd <- sd(pheno_data_opt$DOY, na.rm = TRUE)
    
    # Apply outlier filter: retain stations within f_std standard deviations
    # Criterion: |doy_predicted - doy_observed| <= f_std × sd(doy_observed)
    valid_stations <- which(
      abs(pheno_data_opt$DOY_PHASE - pheno_data_opt$DOY) <= 
        f_std * error_sd
    )
    
    pheno_data_opt <- pheno_data_opt[valid_stations, ]
    
    # -------------------------------------------------------------------------
    # ACCURACY METRICS CALCULATION (Per Quantile)
    # -------------------------------------------------------------------------
    
    # Pearson correlation: observed vs. predicted DOY
    quantiles$COR[q] <- cor(
      pheno_data_opt@data["DOY"],
      pheno_data_opt@data["DOY_PHASE"],
      method = "pearson"
    )
    
    # Root Mean Square Error (RMSE)
    quantiles$RMSE[q] <- sqrt(
      mean((pheno_data_opt$DOY - pheno_data_opt$DOY_PHASE)^2)
    )
    
    # Mean Absolute Error (MAE)
    quantiles$MAE[q] <- mean(
      abs(pheno_data_opt$DOY - pheno_data_opt$DOY_PHASE)
    )
    
    # Sample size after outlier removal
    quantiles$SN[q] <- nrow(pheno_data_opt)
    
    # -------------------------------------------------------------------------
    # UPDATE BEST MODEL (If MAE improved)
    # -------------------------------------------------------------------------
    
    if (quantiles$MAE[q] < mae_min) {
      pheno_data_final <- pheno_data_opt
      mae_min <- quantiles$MAE[q]
      q_min <- quantiles$Q[q]
    }
    
    # Update progress bar
    setTxtProgressBar(pq, q)
  }
  
  # Close progress bar
  close(pq)
  
  # ---------------------------------------------------------------------------
  # STEP 5: APPEND METADATA TO RESULTS
  # ---------------------------------------------------------------------------
  
  message(
    "\nOptimization complete. Best model: ",
    "Quantile = ", q_min, " | ",
    "MAE = ", round(mae_min, 2), " days"
  )
  
  # Add metadata columns to quantile accuracy table
  quantiles$YEAR <- year
  quantiles$STD <- f_std
  quantiles$PLANT <- plant
  quantiles$PHASE <- phase
  
  # ---------------------------------------------------------------------------
  # STEP 6: EXPORT RESULTS (Findability & Accessibility)
  # ---------------------------------------------------------------------------
  
  # Construct output file paths
  csv_filename <- paste0(
    "OPT_", plant, "-", phase, "_", year, "_FSTD", f_std * 10, ".csv"
  )
  shp_filename <- paste0(
    "DOY_", plant, "-", phase, "_", year, "_FSTD", f_std * 10, ".shp"
  )
  
  csv_path <- file.path(output_dir, csv_filename)
  shp_path <- file.path(output_dir, shp_filename)
  
  # Export quantile-specific accuracy results to CSV
  write.csv2(
    quantiles,
    row.names = FALSE,
    file = csv_path
  )
  
  message("Accuracy metrics exported to: ", csv_path)
  
  # Export filtered observation shapefile (best model)
  raster::shapefile(
    pheno_data_final,
    filename = shp_path,
    overwrite = TRUE
  )
  
  message("Spatial predictions exported to: ", shp_path)
  
  # ---------------------------------------------------------------------------
  # RETURN VALUE
  # ---------------------------------------------------------------------------
  
  message(
    "Critical DOY determination complete.\n",
    "Returning list with accuracy metrics and filtered predictions."
  )
  
  # Return list with both accuracy table and spatial predictions
  return(
    list(
      quantile_accuracy = quantiles,
      pheno_data_filtered = pheno_data_final
    )
  )
}

################################################################################
# USAGE EXAMPLES
# ==============================================================================
# EXAMPLE USAGE:
#
#   # Example 1: Winter Wheat (202) critical DOY optimization
#   # Workflow: download → couple → load → calculate GDD → find critical DOY
#
#   # Prerequisites (Steps 1-4 from previous functions)
#   pheno_data <- download_dwd_phenology(crop = 202, combine = TRUE)
#   stations <- couple_phenology_stations(
#     input_dir = "./data/",
#     station_shapefile = "PHENO_STATION_EPSG31467",
#     target_phase = 18,
#     crop = 202,
#     observation_year = 2024
#   )
#   temps <- load_gridded_temperature(
#     pheno_data = stations,
#     input_dir = "./data/",
#     parameter = "tmit_",
#     year = 2024
#   )
#   gdd_raw <- effective_temperature_calculation(
#     gridded_climate = temps,
#     pheno_data = stations,
#     use_base_temperature = TRUE
#   )
#
#   # Step 5: Determine critical DOY
#   result <- critical_doy_determination(
#     pheno_data = gdd_raw,
#     output_dir = "./output/",
#     f_std = 1,
#     q1 = 0.3,
#     q2 = 0.7
#   )
#
#   # Inspect quantile accuracy
#   head(result$quantile_accuracy)
#   best_quantile <- result$quantile_accuracy[
#     which.min(result$quantile_accuracy$RMSE), "Q"
#   ]
#   print(paste("Optimal quantile:", best_quantile))
#
#   # Visualize accuracy vs. quantile
#   plot(
#     result$quantile_accuracy$Q, 
#     result$quantile_accuracy$RMSE,
#     type = "b", 
#     xlab = "Quantile", 
#     ylab = "RMSE (days)",
#     main = "Model Accuracy vs. Temperature Sum Quantile"
#   )
#
################################################################################
# END OF FILE
################################################################################
