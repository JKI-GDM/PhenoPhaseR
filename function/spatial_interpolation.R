################################################################################
# Spatial Interpolation of Phenological Day of Year (DOY) Observations
################################################################################
#
# AUTHORS: Markus Möller (JKI), Henning Gerstmann (BfN)
#
# CHANGES (2026-04-29 patch):
#   1. New parameter `subfolders = TRUE` routes outputs into:
#        <output_dir>/cogs/    → DOY_, BSE_, KSV_, SSE_ GeoTIFFs
#        <output_dir>/vam/     → VAM_, CAL_, GEM_ CSV files
#        <output_dir>/splits/  → TRAIN_, TEST_ shapefiles
#      Pass `subfolders = FALSE` for the previous flat layout.
#   2. VAM table now carries two extra columns:
#        VN       = nrow(obs_test)                      (validation N)
#        MEAN_BSE = raster::cellStats(var_raster, mean) (only when uncertainty
#                                                        = TRUE; NA otherwise)
#      consumed as ISO 19157-1 quality elements by the Hook B publisher.
#   3. `shp_dir` remains the *input* directory (for the pre-interpolation
#      shapefile produced by filter_variant_selector). With the new layout
#      this is typically `file.path(output_dir, "shapefiles")`.
################################################################################

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
ensure_packages(c("sf", "raster", "automap", "fields", "caret", "MLmetrics", "mgcv"))


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
    method      = "krige",
    validation  = TRUE,
    uncertainty = FALSE,
    bam_k       = NULL,
    subfolders  = TRUE
) {

  message("Spatial interpolation of DOY for PLANT = ", plant,
          ", PHASE = ", phase, ", YEAR = ", year)

  # Validate method argument
  valid_methods <- c("krige", "spline", "bam")
  if (!method %in% valid_methods) {
    stop("Invalid method: '", method, "'. Must be one of: ",
         paste(valid_methods, collapse = ", "))
  }

  if (!dir.exists(shp_dir)) stop("Shapefile directory not found: ", shp_dir)
  if (!dir.exists(dem_dir)) stop("DEM directory not found: ", dem_dir)
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    message("Created output directory: ", output_dir)
  }

  # ----------------------------------------------------------------------------
  # Output directory layout
  # ----------------------------------------------------------------------------
  if (subfolders) {
    out_cogs   <- file.path(output_dir, "cogs")
    out_vam    <- file.path(output_dir, "vam")
    out_splits <- file.path(output_dir, "splits")
  } else {
    out_cogs <- out_vam <- out_splits <- output_dir
  }
  for (d in unique(c(out_cogs, out_vam, out_splits)))
    dir.create(d, recursive = TRUE, showWarnings = FALSE)

  # ============================================================================
  # STEP 1: Load and prepare spatial data
  # ============================================================================
  message("\n--- STEP 1: Loading spatial data ---")

  dem_path <- file.path(dem_dir, dem_grid)
  if (!file.exists(dem_path)) stop("DEM file not found: ", dem_path)
  dem_raster <- raster::raster(dem_path)
  raster::projection(dem_raster) <- sp::CRS(paste0("+init=epsg:", dem_epsg))
  names(dem_raster) <- "DEM"
  message("DEM loaded: ", nrow(dem_raster), " x ", ncol(dem_raster), " cells")

  shp_path <- file.path(
    shp_dir,
    paste0("DOY_", plant, "-", phase, "_", year, ".shp")
  )
  if (!file.exists(shp_path)) {
    stop("Shapefile not found: ", shp_path, "\n",
         "Verify filter_variant_selector has run and produced the optimal shapefile.")
  }
  obs_sf <- sf::st_read(shp_path, quiet = TRUE)
  sf::st_crs(obs_sf) <- shp_epsg
  message("Observations loaded: ", nrow(obs_sf), " stations")

  # ============================================================================
  # STEP 2: Reproject and extract DEM values
  # ============================================================================
  message("\n--- STEP 2: Projecting and extracting DEM values ---")
  obs_sf      <- sf::st_transform(obs_sf, sf::st_crs(dem_raster))
  dem_spatial <- methods::as(dem_raster, "SpatialPixelsDataFrame")
  obs_spatial <- sf::as_Spatial(obs_sf)
  dem_at_obs  <- sp::over(obs_spatial, dem_spatial)
  obs_sf$DEM  <- dem_at_obs$DEM
  obs_sf      <- obs_sf[!is.na(obs_sf$DEM), ]
  coords <- sf::st_coordinates(obs_sf)
  obs_sf$X <- coords[, 1]; obs_sf$Y <- coords[, 2]
  message("Observations with valid DEM: ", nrow(obs_sf))

  # ============================================================================
  # STEP 3: Optional validation split
  # ============================================================================
  if (validation) {
    message("\n--- STEP 3: Creating training/test split ---")
    set.seed(202401)
    idx_train <- caret::createDataPartition(y = obs_sf$DOY, p = 0.75, list = FALSE)
    obs_train <- stats::na.omit(obs_sf[ idx_train, ])
    obs_test  <- stats::na.omit(obs_sf[-idx_train, ])
    message("Training set: ", nrow(obs_train), " observations\n",
            "Test set: ",     nrow(obs_test),  " observations")

    sf::st_write(obs_train,
                 file.path(out_splits,
                           paste0("TRAIN_", plant, "-", phase, "_", year, ".shp")),
                 delete_layer = TRUE, quiet = TRUE)
    sf::st_write(obs_test,
                 file.path(out_splits,
                           paste0("TEST_", plant, "-", phase, "_", year, ".shp")),
                 delete_layer = TRUE, quiet = TRUE)
  } else {
    obs_train <- obs_sf
    obs_test  <- NULL
    message("Validation disabled; using all observations for fitting")
  }

  # ============================================================================
  # STEP 4: Spatial interpolation
  # ============================================================================
  message("\n--- STEP 4: Spatial interpolation (", method, ") ---")

  if (method == "krige") {
    message("Fitting autoKrige model with formula: DOY ~ 1 + DEM")
    krige_result <- automap::autoKrige(
      as.formula("DOY ~ 1 + DEM"),
      input_data  = sf::as_Spatial(obs_train),
      new_data    = dem_spatial,
      verbose     = FALSE, debug.level = -1, nmax = Inf
    )
    pred_raster <- raster::raster(krige_result$krige_output)
    var_raster  <- raster::raster(krige_result$krige_output, layer = 3)
    bam_k_used  <- NA
    message("Kriging complete. Range: ",
            round(raster::cellStats(pred_raster, min), 1), " to ",
            round(raster::cellStats(pred_raster, max), 1), " DOY")

  } else if (method == "spline") {
    message("Fitting thin-plate spline model")
    coords_tps <- sf::st_coordinates(obs_train)
    xyz <- data.frame(coords_tps[, 1], coords_tps[, 2], obs_train$DEM)
    colnames(xyz) <- c("x", "y", "dem")
    tps_fit <- fields::Tps(xyz, obs_train$DOY)
    pred_grid <- as.data.frame(raster::rasterToPoints(dem_raster))
    colnames(pred_grid) <- c("X", "Y", "DEM")
    pred_grid <- stats::na.omit(pred_grid)
    pred_values <- predict(tps_fit, x = as.matrix(pred_grid[, c("X", "Y", "DEM")]))
    pred_df <- data.frame(x = pred_grid$X, y = pred_grid$Y, pred = pred_values)
    pred_raster <- raster::rasterFromXYZ(pred_df, crs = raster::projection(dem_raster))
    pred_raster <- raster::mask(pred_raster, dem_raster)
    if (uncertainty) {
      pred_se <- predict.se(tps_fit, x = as.matrix(pred_grid[, c("X", "Y", "DEM")]))
      se_df <- data.frame(x = pred_grid$X, y = pred_grid$Y, se = pred_se)
      var_raster <- raster::rasterFromXYZ(se_df, crs = raster::projection(dem_raster))
      var_raster <- raster::mask(var_raster, dem_raster)
    } else var_raster <- NULL
    bam_k_used <- NA

  } else {  # bam
    n <- nrow(obs_train)
    if (is.null(bam_k)) {
      bam_k_used <- if (n < 100)             max(30,  min(50,  floor(n * 0.6)))
                    else if (n < 300)        max(50,  min(150, floor(n * 0.5)))
                    else if (n < 600)        max(150, min(250, floor(n * 0.45)))
                    else                                    min(400, floor(n * 0.4))
    } else {
      bam_k_used <- bam_k
    }
    message("Fitting BAM with k = ", bam_k_used, " on n = ", n)

    train_df <- as.data.frame(obs_train)
    bam_fit <- mgcv::bam(DOY ~ s(X, Y, k = bam_k_used) + DEM,
                         data = train_df, method = "fREML",
                         discrete = TRUE)

    cal <- data.frame(
      PLANT = plant, PHASE = phase, YEAR = year,
      BAM_K = bam_k_used,
      AIC   = stats::AIC(bam_fit),
      BIC   = stats::BIC(bam_fit),
      EDF   = sum(bam_fit$edf),
      DEV_EXPLAINED = summary(bam_fit)$dev.expl,
      stringsAsFactors = FALSE
    )
    cal_path <- file.path(out_vam,
                          paste0("CAL_", plant, "-", phase, "_", year, ".csv"))
    utils::write.csv2(cal, file = cal_path, row.names = FALSE)
    message("Calibration metrics written: ", cal_path)

    pred_grid <- as.data.frame(raster::rasterToPoints(dem_raster))
    colnames(pred_grid) <- c("X", "Y", "DEM")
    pred_grid <- stats::na.omit(pred_grid)
    message("Predicting to ", nrow(pred_grid), " grid cells...")

    pred_values <- mgcv::predict.bam(bam_fit, newdata = pred_grid, type = "response")
    pred_df <- data.frame(x = pred_grid$X, y = pred_grid$Y, pred = pred_values)
    pred_raster <- raster::rasterFromXYZ(pred_df, crs = raster::projection(dem_raster))
    pred_raster <- raster::mask(pred_raster, dem_raster)

    if (uncertainty) {
      message("Computing posterior standard errors (uncertainty)...")
      pred_se <- mgcv::predict.bam(bam_fit, newdata = pred_grid, se.fit = TRUE)
      se_df   <- data.frame(x = pred_grid$X, y = pred_grid$Y, se = pred_se$se.fit)
      var_raster <- raster::rasterFromXYZ(se_df, crs = raster::projection(dem_raster))
      var_raster <- raster::mask(var_raster, dem_raster)
    } else var_raster <- NULL

    message("BAM fit complete. Prediction range: ",
            round(raster::cellStats(pred_raster, min), 1), " to ",
            round(raster::cellStats(pred_raster, max), 1), " DOY")
  }

  # ============================================================================
  # STEP 5: Output writing
  # ============================================================================
  message("\n--- STEP 5: Writing outputs ---")

  doy_path <- file.path(out_cogs,
                        paste0("DOY_", plant, "-", phase, "_", year, ".tif"))
  raster::writeRaster(pred_raster, doy_path, overwrite = TRUE)
  message("Interpolated DOY written: ", doy_path)

  mean_bse <- NA_real_
  if (uncertainty && !is.null(var_raster)) {
    unc_suffix <- switch(method, "krige" = "KSV", "spline" = "SSE", "bam" = "BSE")
    unc_label  <- switch(method,
                          "krige"  = "KSV (Kriging Standard Variance)",
                          "spline" = "SSE (Spline Standard Error)",
                          "bam"    = "BSE (BAM Posterior Standard Error)")

    unc_path <- file.path(out_cogs,
                          paste0(unc_suffix, "_", plant, "-", phase,
                                  "_", year, ".tif"))
    raster::writeRaster(var_raster, unc_path, overwrite = TRUE)
    message("Uncertainty surface written: ", unc_path)
    message("  - Type: ", unc_label)

    # Spatial mean for ISO 19157-1 quality element
    mean_bse <- raster::cellStats(var_raster, stat = "mean", na.rm = TRUE)

    gem <- stats::quantile(raster::values(var_raster), na.rm = TRUE)
    gem_df <- data.frame(Quantile = names(gem), Value = as.numeric(gem))
    gem_path <- file.path(out_vam,
                          paste0("GEM_", plant, "-", phase, "_", year, ".csv"))
    utils::write.csv2(gem_df, file = gem_path, row.names = FALSE)
    message("Global error metrics written: ", gem_path)
  }

  # ============================================================================
  # STEP 6: Validation metrics
  # ============================================================================
  vam <- NULL
  if (validation && !is.null(obs_test) && nrow(obs_test) > 0) {
    message("\n--- STEP 6: Computing validation metrics ---")

    pred_at_test    <- raster::extract(pred_raster, sf::as_Spatial(obs_test))
    obs_test$DOY_pred <- pred_at_test
    obs_test <- obs_test[!is.na(obs_test$DOY_pred), ]

    if (nrow(obs_test) > 0) {
      rmse_val <- MLmetrics::RMSE(obs_test$DOY, obs_test$DOY_pred)
      mae_val  <- MLmetrics::MAE (obs_test$DOY, obs_test$DOY_pred)
      mse_val  <- MLmetrics::MSE (obs_test$DOY, obs_test$DOY_pred)
      r2_val <- 1 - sum((obs_test$DOY - obs_test$DOY_pred)^2) /
                    sum((obs_test$DOY - mean(obs_test$DOY))^2)

      vam <- data.frame(
        PLANT    = plant,
        PHASE    = phase,
        YEAR     = year,
        TN       = nrow(obs_train),
        ON       = nrow(obs_sf),
        VN       = nrow(obs_test),
        METHOD   = method,
        BAM_K    = if (method == "bam") bam_k_used else NA_integer_,
        RMSE     = round(rmse_val, 2),
        MAE      = round(mae_val,  2),
        MSE      = round(mse_val,  2),
        R2       = round(r2_val,   4),
        MEAN_BSE = if (is.na(mean_bse)) NA_real_ else round(mean_bse, 3),
        stringsAsFactors = FALSE
      )

      vam_path <- file.path(out_vam,
                            paste0("VAM_", plant, "-", phase, "_", year, ".csv"))
      utils::write.csv2(vam, file = vam_path, row.names = FALSE)
      message("Validation metrics written: ", vam_path)
      message("Validation R² = ", round(r2_val, 4),
              " | RMSE = ", round(rmse_val, 2), " days",
              " | MAE = ",  round(mae_val,  2), " days")
    } else {
      message("No valid test predictions; skipping validation metrics")
    }
  }

  # ============================================================================
  # SUMMARY AND RETURN
  # ============================================================================
  message("\n",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
          "Interpolation complete:\n",
          "  Method: ", method, "\n",
          "  Observations: ", nrow(obs_train), "\n",
          "  Output: ", doy_path, "\n",
          if (method == "bam") paste0("  BAM k used: ", bam_k_used, "\n") else "",
          "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

  invisible(list(
    interpolation       = pred_raster,
    uncertainty         = if (uncertainty) var_raster else NULL,
    validation_metrics  = vam,
    n_observations      = nrow(obs_train),
    method_used         = method,
    bam_k_used          = if (method == "bam") bam_k_used else NA,
    mean_bse            = mean_bse
  ))
}

################################################################################
# END OF FILE
################################################################################
