################################################################################
# Spatial Interpolation of Phenological Day of Year (DOY) Observations
################################################################################

# PURPOSE:
# Interpolate phenological Day of Year (DOY) observations to gridded spatial
# predictions using kriging, thin-plate spline, or GAM (mgcv::bam) methods.
# Supports validation using training/test splits and computes accuracy metrics
# (RMSE, MAE, MSE, R²).

# AUTHORS:
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/

# DEPENDENCIES:
# Original: sf, raster, automap, fields, caret, MLmetrics, mgcv

# VERSION HISTORY:
# v1.0 (2026-01-14): Original version

# CITATION:
# If you use this code in your research, please cite:
# Möller, M. & Gerstmann, H, (2026). spatial_interpolation:  Spatial 
# Interpolation of Phenological Day of Year (DOY) Observations. Available at: 
# [repository URL - add when published]

# LICENSE:
# This code is provided under the MIT License

################################################################################
# ==============================================================================
# FUNCTION: ensure_packages()
# ==============================================================================
# PURPOSE:
# Automatically check for required packages and install them if missing.
# Ensures reproducibility by guaranteeing all dependencies are available.

# ARGUMENTS:
# pkg_list (character vector): Vector of package names to check/install

# RETURNS:
# Invisibly returns TRUE; primarily used for side effects (loading packages)

ensure_packages <- function(pkg_list) {
  for (pkg in pkg_list) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      message("Installing package: ", pkg)
      install.packages(pkg, quiet = TRUE)
    }
    library(pkg, character.only = TRUE, quietly = TRUE)
  }
  message("All required packages loaded successfully!")
  invisible(TRUE)
}

# Load dependencies
ensure_packages(c("sf", "raster", "automap", "fields", "caret", "MLmetrics", "mgcv"))

################################################################################
# ==============================================================================
# MAIN FUNCTION:
# ==============================================================================
# PURPOSE:
# Perform spatial interpolation of phenological DOY observations to a regular
# grid using kriging, thin-plate spline, or GAM methods. Generate uncertainty
# estimates and optional validation metrics.

# ARGUMENTS:
# plant (numeric or character, REQUIRED):
# - DWD crop identifier (PLANT).

# phase (numeric or character, REQUIRED):
# - Phenological phase ID.

# year (numeric, REQUIRED):
# - Year for which to interpolate.

# shp_dir (character, REQUIRED):
# - Directory containing input shapefile: DOY_<plant>-<phase>_<year>.shp
# - Must use sf-compatible format .

# shp_epsg (numeric, REQUIRED):
# - EPSG code for input shapefile CRS (e.g., 31467 for DHDN/Gauss-Krüger).
# - Used if shapefile CRS is missing or needs correction.

# dem_dir (character, REQUIRED):
# - Directory containing DEM grid file.

# dem_grid (character, REQUIRED):
# - Filename of DEM raster (e.g., "DGM1000_EPSG25832.asc").
# - Expected to be readable by raster::raster().

# dem_epsg (numeric, REQUIRED):
# - EPSG code for DEM CRS.

# output_dir (character, REQUIRED):
# - Directory where interpolated grids and metrics will be written.
# - Must be writable. Created if not present.

# method (character, default = "krige"):
# - Interpolation method: "krige", "spline", or "bam"
# - Only one method is applied per function call.

# validation (logical, default = TRUE):
# - If TRUE: Split observations into training (75%) and test (25%).
#   Fit on training, evaluate on test; compute accuracy metrics.
# - If FALSE: Use all observations for fitting; no test-set validation.

# uncertainty (logical, default = FALSE):
# - If TRUE: Output uncertainty surfaces:
#   * For kriging: KSV_<plant>-<phase>_<year>.tif (kriging std variance)
#   * For spline: SSE_<plant>-<phase>_<year>.tif (spline std error)
#   * For bam: BSE_<plant>-<phase>_<year>.tif (BAM std error)
# - If FALSE: Omit uncertainty surfaces (faster).

# bam_k (numeric or NULL, default = NULL):
# - Basis dimension for mgcv::bam spatial smooth s(X,Y).
# - If NULL (recommended): Automatically determined based on sample size using:
#   * n < 100: k = max(30, min(50, floor(n * 0.6)))
#   * 100 <= n < 300: k = max(50, min(150, floor(n * 0.5)))
#   * 300 <= n < 600: k = max(150, min(250, floor(n * 0.45)))
#   * n >= 600: k = min(400, floor(n * 0.4))
# - Manual override: Set specific value (e.g., bam_k = 200)
# - Higher k allows more flexibility but increases computation time

# INPUT EXPECTATIONS:
# - Shapefile must contain at minimum:
#   * Geometry column (sf POINT geometry)
#   * DOY (day of year, numeric)
#   * Potentially other attributes (STATION, YEAR, PLANT, PHASE)

# - DEM grid must:
#   * Cover entire region of shapefile observations
#   * Be in a projected coordinate system (not geographic/lat-lon)
#   * Have regular grid spacing

# RETURNS:
# - Invisibly returns a list with:
#   $interpolation: raster of interpolated DOY values
#   $uncertainty: raster of uncertainty (if uncertainty = TRUE)
#   $validation_metrics: data.frame of accuracy metrics (if validation = TRUE)
#   $n_observations: count of observations used
#   $method_used: method name
#   $bam_k_used: k value used (only for bam method)

# SIDE EFFECTS:
# - Writes GeoTIFF outputs to output_dir:
#   1. DOY_<plant>-<phase>_<year>.tif (interpolated DOY)
#   2. Uncertainty surface (if uncertainty = TRUE)

# - Writes CSV metrics to output_dir:
#   3. VAM_<plant>-<phase>_<year>.csv (validation accuracy metrics)
#      Columns: PLANT, PHASE, YEAR, TN, ON, METHOD, RMSE, MAE, MSE, R2
#   4. GEM_<plant>-<phase>_<year>.csv (global error metrics)
#      Columns: Quantile, Value (quantiles of uncertainty surface)
#   5. CAL_<plant>-<phase>_<year>.csv (validation accuracy metrics: 
#     only for 'bam' method)
# - Writes shapefile subsets (if validation = TRUE):
#   6. TRAIN_<plant>-<phase>_<year>.shp (training subset)
#   7. TEST_<plant>-<phase>_<year>.shp (test subset)

################################################################################

spatial_interpolation <- function(
    plant,
    phase,
    year,
    shp_dir,
    shp_epsg,
    dem_dir,
    dem_grid,
    dem_epsg,
    output_dir,
    method = "krige",
    validation = TRUE,
    uncertainty = FALSE,
    bam_k = NULL
) {
  
  # =========================================================================
  # INPUT VALIDATION & SETUP
  # =========================================================================
  
  message(
    "Spatial interpolation of DOY for PLANT = ", plant,
    ", PHASE = ", phase, ", YEAR = ", year
  )
  
  # Validate method argument
  valid_methods <- c("krige", "spline", "bam")
  if (!method %in% valid_methods) {
    stop(
      "Invalid method: '", method, "'. ",
      "Must be one of: ", paste(valid_methods, collapse = ", ")
    )
  }
  
  # Verify directories exist
  if (!dir.exists(shp_dir)) {
    stop("Shapefile directory not found: ", shp_dir)
  }
  if (!dir.exists(dem_dir)) {
    stop("DEM directory not found: ", dem_dir)
  }
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    message("Created output directory: ", output_dir)
  }
  
  # =========================================================================
  # STEP 1: Load and prepare spatial data
  # =========================================================================
  
  message("\n--- STEP 1: Loading spatial data ---")
  
  # Load DEM grid
  dem_path <- file.path(dem_dir, dem_grid)
  if (!file.exists(dem_path)) {
    stop("DEM file not found: ", dem_path)
  }
  
  dem_raster <- raster::raster(dem_path)
  raster::projection(dem_raster) <- sp::CRS(paste0("+init=epsg:", dem_epsg))
  names(dem_raster) <- "DEM"
  message("DEM loaded: ", nrow(dem_raster), " x ", ncol(dem_raster), " cells")
  
  # Load phenological observations
  shp_path <- file.path(
    shp_dir,
    paste0("DOY_", plant, "-", phase, "_", year, ".shp")
  )
  
  if (!file.exists(shp_path)) {
    stop(
      "Shapefile not found: ", shp_path, "\n",
      "Verify filter_variant_assessment has run and produced optimal shapefiles."
    )
  }
  
  obs_sf <- sf::st_read(shp_path, quiet = TRUE)
  sf::st_crs(obs_sf) <- shp_epsg
  message("Observations loaded: ", nrow(obs_sf), " stations")
  
  # =========================================================================
  # STEP 2: Reproject observations to DEM grid CRS and extract DEM values
  # =========================================================================
  
  message("\n--- STEP 2: Projecting and extracting DEM values ---")
  
  # Reproject observations to DEM CRS
  obs_sf <- sf::st_transform(obs_sf, sf::st_crs(dem_raster))
  
  # Extract DEM values at observation locations
  dem_spatial <- methods::as(dem_raster, "SpatialPixelsDataFrame")
  obs_spatial <- sf::as_Spatial(obs_sf)
  dem_at_obs <- sp::over(obs_spatial, dem_spatial)
  
  # Attach DEM values to observations
  obs_sf$DEM <- dem_at_obs$DEM
  obs_sf <- obs_sf[!is.na(obs_sf$DEM), ]
  
  # Extract coordinates for bam method
  coords <- sf::st_coordinates(obs_sf)
  obs_sf$X <- coords[, 1]
  obs_sf$Y <- coords[, 2]
  
  message("Observations with valid DEM: ", nrow(obs_sf))
  
  # =========================================================================
  # STEP 3: Optional validation split
  # =========================================================================
  
  if (validation) {
    message("\n--- STEP 3: Creating training/test split ---")
    
    # Stratified split: 75% training, 25% test
    set.seed(202401) # Reproducible seed
    idx_train <- caret::createDataPartition(
      y = obs_sf$DOY,
      p = 0.75,
      list = FALSE
    )
    
    obs_train <- obs_sf[idx_train, ]
    obs_test <- obs_sf[-idx_train, ]
    
    # Remove rows with NA in critical columns
    obs_train <- stats::na.omit(obs_train)
    obs_test <- stats::na.omit(obs_test)
    
    message(
      "Training set: ", nrow(obs_train), " observations\n",
      "Test set: ", nrow(obs_test), " observations"
    )
    
    # Export training/test shapefiles
    sf::st_write(
      obs_train,
      file.path(output_dir, paste0("TRAIN_", plant, "-", phase, "_", year, ".shp")),
      delete_layer = TRUE,
      quiet = TRUE
    )
    
    sf::st_write(
      obs_test,
      file.path(output_dir, paste0("TEST_", plant, "-", phase, "_", year, ".shp")),
      delete_layer = TRUE,
      quiet = TRUE
    )
    
  } else {
    obs_train <- obs_sf
    obs_test <- NULL
    message("Validation disabled; using all observations for fitting")
  }
  
  # =========================================================================
  # STEP 4: Spatial interpolation
  # =========================================================================
  
  message("\n--- STEP 4: Spatial interpolation (", method, ") ---")
  
  # --- KRIGING ---
  if (method == "krige") {
    
    message("Fitting autoKrige model with formula: DOY ~ 1 + DEM")
    krige_result <- automap::autoKrige(
      as.formula("DOY ~ 1 + DEM"),
      input_data = sf::as_Spatial(obs_train),
      new_data = dem_spatial,
      verbose = FALSE,
      debug.level = -1,
      nmax = Inf
    )
    
    pred_raster <- raster::raster(krige_result$krige_output)
    var_raster <- raster::raster(krige_result$krige_output, layer = 3)
    
    message("Kriging complete. Prediction range: ",
            round(raster::cellStats(pred_raster, min), 1), " to ",
            round(raster::cellStats(pred_raster, max), 1), " DOY")
    
    bam_k_used <- NA
    
    # --- TPS ---
  } else if (method == "spline") {
    
    message("Fitting thin-plate spline model")
    
    coords_tps <- sf::st_coordinates(obs_train)
    dem_values <- obs_train$DEM
    doy_values <- obs_train$DOY
    xyz <- data.frame(coords_tps[, 1], coords_tps[, 2], dem_values)
    colnames(xyz) <- c("x", "y", "dem")
    
    tps_fit <- fields::Tps(xyz, doy_values)
    
    pred_raster <- raster::interpolate(dem_raster, tps_fit, xyOnly = FALSE)
    pred_raster <- raster::mask(pred_raster, dem_raster)
    
    if (uncertainty) {
      var_raster <- raster::interpolate(
        dem_raster,
        tps_fit,
        xyOnly = FALSE,
        fun = fields::predictSE
      )
      var_raster <- raster::mask(var_raster, dem_raster)
    } else {
      var_raster <- NULL
    }
    
    message("Spline fit complete. Prediction range: ",
            round(raster::cellStats(pred_raster, min), 1), " to ",
            round(raster::cellStats(pred_raster, max), 1), " DOY")
    
    bam_k_used <- NA
    
    # --- mgcv::bam ---
  } else if (method == "bam") {
    
    # Determine k automatically if not specified
    n_obs <- nrow(obs_train)
    
    if (is.null(bam_k)) {
      # Automatic k selection based on sample size
      # Rules based on mgcv recommendations and practical experience:
      # - k should be large enough to capture spatial variation
      # - k should be small enough for computational efficiency
      # - k sets upper limit on EDF (effective degrees of freedom)
      # - Typical EDF is much less than k due to penalization
      
      if (n_obs < 100) {
        # Very small samples: conservative k
        bam_k <- max(30, min(50, floor(n_obs * 0.6)))
      } else if (n_obs < 300) {
        # Small to medium samples
        bam_k <- max(50, min(150, floor(n_obs * 0.5)))
      } else if (n_obs < 600) {
        # Medium to large samples
        bam_k <- max(150, min(250, floor(n_obs * 0.45)))
      } else {
        # Large samples
        bam_k <- min(400, floor(n_obs * 0.4))
      }
      
      message("Automatic k selection: n = ", n_obs, " → k = ", bam_k)
    } else {
      message("Using manual k specification: k = ", bam_k)
    }
    
    bam_k_used <- bam_k
    
    message("Fitting mgcv::bam with spatial smooth s(X,Y,bs='tp',k=", bam_k, ") + s(DEM)")
    
    # Prepare training data frame
    train_df <- as.data.frame(obs_train)
    train_df <- train_df[, c("DOY", "X", "Y", "DEM")]
    train_df <- stats::na.omit(train_df)
    
    # Fit BAM model with spatial smooth + DEM covariate
    # bs='tp' = thin plate regression spline (low-rank isotropic)
    # method='fREML' = fast REML for large datasets
    bam_fit <- mgcv::bam(
      DOY ~ s(X, Y, bs = "tp", k = bam_k) + s(DEM, bs = "tp", k = 10),
      data = train_df,
      method = "fREML",
      discrete = TRUE,  # Faster for large grids
      nthreads = 2      # Parallel computation
    )
    
    message("BAM model summary:")
    message("  - Effective degrees of freedom: ", 
            round(sum(bam_fit$edf), 1))
    message("  - R-squared (adjusted): ", 
            round(summary(bam_fit)$r.sq, 4))
    message("  - Deviance explained: ",
            round(summary(bam_fit)$dev.expl * 100, 1), "%")
    
    # Calibration metrics
    cal <- data.frame(
      PLANT = plant,
      PHASE = phase,
      YEAR = year,
      ON = nrow(obs_sf),
      METHOD = method,
      R2 =  round(summary(bam_fit)$r.sq, 4),
      DevEx = round(summary(bam_fit)$dev.expl * 100, 1),
      stringsAsFactors = FALSE)
    
    
    cal_path <- file.path(
      output_dir,
      paste0("CAL_", plant, "-", phase, "_", year, ".csv"))
    
    utils::write.csv2(cal, file = cal_path, row.names = FALSE)
    message("Calibration metrics written: ", cal_path)
    
    # Prepare prediction grid
    pred_grid <- as.data.frame(raster::rasterToPoints(dem_raster))
    colnames(pred_grid) <- c("X", "Y", "DEM")
    pred_grid <- stats::na.omit(pred_grid)
    
    # Predict to grid (mean predictions)
    message("Predicting to ", nrow(pred_grid), " grid cells...")
    pred_values <- mgcv::predict.bam(bam_fit, newdata = pred_grid, type = "response")
    
    # Create prediction raster
    pred_df <- data.frame(
      x = pred_grid$X,
      y = pred_grid$Y,
      pred = pred_values
    )
    pred_raster <- raster::rasterFromXYZ(pred_df, crs = raster::projection(dem_raster))
    pred_raster <- raster::mask(pred_raster, dem_raster)
    
    # Compute uncertainty if requested
    if (uncertainty) {
      message("Computing posterior standard errors (uncertainty)...")
      pred_se <- mgcv::predict.bam(bam_fit, newdata = pred_grid, se.fit = TRUE)
      
      se_df <- data.frame(
        x = pred_grid$X,
        y = pred_grid$Y,
        se = pred_se$se.fit
      )
      var_raster <- raster::rasterFromXYZ(se_df, crs = raster::projection(dem_raster))
      var_raster <- raster::mask(var_raster, dem_raster)
    } else {
      var_raster <- NULL
    }
    
    message("BAM fit complete. Prediction range: ",
            round(raster::cellStats(pred_raster, min), 1), " to ",
            round(raster::cellStats(pred_raster, max), 1), " DOY")
  }
  
  # =========================================================================
  # STEP 5: Output writing
  # =========================================================================
  
  message("\n--- STEP 5: Writing outputs ---")
  
  # Write interpolated DOY grid
  doy_path <- file.path(
    output_dir,
    paste0("DOY_", plant, "-", phase, "_", year, ".tif")
  )
  
  raster::writeRaster(pred_raster, doy_path, overwrite = TRUE)
  message("Interpolated DOY written: ", doy_path)
  
  # Write uncertainty surface if requested
  if (uncertainty && !is.null(var_raster)) {
    
    # Determine uncertainty file suffix based on method
    unc_suffix <- switch(
      method,
      "krige" = "KSV",  # Kriging Standard Variance
      "spline" = "SSE", # Spline Standard Error
      "bam" = "BSE"     # BAM Standard Error
    )
    
    unc_label <- switch(
      method,
      "krige" = "KSV (Kriging Standard Variance)",
      "spline" = "SSE (Spline Standard Error)",
      "bam" = "BSE (BAM Posterior Standard Error)"
    )
    
    unc_path <- file.path(
      output_dir,
      paste0(unc_suffix, "_", plant, "-", phase, "_", year, ".tif")
    )
    
    raster::writeRaster(var_raster, unc_path, overwrite = TRUE)
    message("Uncertainty surface written: ", unc_path)
    message("  - Type: ", unc_label)
    
    # Compute global error metrics (quantiles)
    gem <- stats::quantile(raster::values(var_raster), na.rm = TRUE)
    gem_df <- data.frame(
      Quantile = names(gem),
      Value = as.numeric(gem)
    )
    
    gem_path <- file.path(
      output_dir,
      paste0("GEM_", plant, "-", phase, "_", year, ".csv")
    )
    
    utils::write.csv2(gem_df, file = gem_path, row.names = FALSE)
    message("Global error metrics written: ", gem_path)
  }
  
  # =========================================================================
  # STEP 6: Optional validation metrics
  # =========================================================================
  
  if (validation && !is.null(obs_test) && nrow(obs_test) > 0) {
    message("\n--- STEP 6: Computing validation metrics ---")
    
    # Extract predicted DOY at test locations
    pred_at_test <- raster::extract(pred_raster, sf::as_Spatial(obs_test))
    obs_test$DOY_pred <- pred_at_test
    
    # Remove rows with missing predictions
    obs_test <- obs_test[!is.na(obs_test$DOY_pred), ]
    
    if (nrow(obs_test) > 0) {
      # Compute accuracy metrics
      rmse_val <- MLmetrics::RMSE(obs_test$DOY, obs_test$DOY_pred)
      mae_val <- MLmetrics::MAE(obs_test$DOY, obs_test$DOY_pred)
      mse_val <- MLmetrics::MSE(obs_test$DOY, obs_test$DOY_pred)
      
      # R² calculation
      r2_val <- 1 - (sum((obs_test$DOY - obs_test$DOY_pred)^2) / 
                       sum((obs_test$DOY - mean(obs_test$DOY))^2))
      
      # Create validation metrics table (include bam_k if bam method used)
      if (method == "bam") {
        vam <- data.frame(
          PLANT = plant,
          PHASE = phase,
          YEAR = year,
          TN = nrow(obs_train),
          ON = nrow(obs_sf),
          METHOD = method,
          BAM_K = bam_k_used,
          RMSE = round(rmse_val, 2),
          MAE = round(mae_val, 2),
          MSE = round(mse_val, 2),
          R2 = round(r2_val, 4),
          stringsAsFactors = FALSE
        )
      } else {
        vam <- data.frame(
          PLANT = plant,
          PHASE = phase,
          YEAR = year,
          TN = nrow(obs_train),
          ON = nrow(obs_sf),
          METHOD = method,
          RMSE = round(rmse_val, 2),
          MAE = round(mae_val, 2),
          MSE = round(mse_val, 2),
          R2 = round(r2_val, 4),
          stringsAsFactors = FALSE
        )
      }
      
      vam_path <- file.path(
        output_dir,
        paste0("VAM_", plant, "-", phase, "_", year, ".csv")
      )
      
      utils::write.csv2(vam, file = vam_path, row.names = FALSE)
      message("Validation metrics written: ", vam_path)
      message(
        "Validation R² = ", round(r2_val, 4),
        " | RMSE = ", round(rmse_val, 2), " days",
        " | MAE = ", round(mae_val, 2), " days"
      )
      
    } else {
      vam <- NULL
      message("No valid test predictions; skipping validation metrics")
    }
    
  } else {
    vam <- NULL
  }
  
  # =========================================================================
  # SUMMARY AND RETURN
  # =========================================================================
  
  message("\n",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
          "Interpolation complete:\n",
          "  Method: ", method, "\n",
          "  Observations: ", nrow(obs_train), "\n",
          "  Output: ", doy_path, "\n",
          if (method == "bam") paste0("  BAM k used: ", bam_k_used, "\n") else "",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  
  invisible(
    list(
      interpolation = pred_raster,
      uncertainty = if (uncertainty) var_raster else NULL,
      validation_metrics = vam,
      n_observations = nrow(obs_train),
      method_used = method,
      bam_k_used = if (method == "bam") bam_k_used else NA
    )
  )
}

################################################################################
# USAGE EXAMPLE
# ==============================================================================
# # Using mgcv::bam with automatic k selection (recommended)
# result_bam <- spatial_interpolation(
#   plant = 252,
#   phase = 10,
#   year = 2020,
#   shp_dir = "./output/",
#   shp_epsg = 31467,
#   dem_dir = "./data/",
#   dem_grid = "DGM1000_EPSG25832.asc",
#   dem_epsg = 25832,
#   output_dir = "./output/",
#   method = "bam",
#   validation = TRUE,
#   uncertainty = TRUE
# )

################################################################################
# END OF FILE
################################################################################
