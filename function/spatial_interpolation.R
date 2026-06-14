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
#   2. VAM table now carries one extra column:
#        VN       = nrow(obs_test)                      (validation N)
#      consumed as ISO 19157-1 quality elements by the Hook B publisher.
#   3. `shp_dir` remains the *input* directory (for the pre-interpolation
#      shapefile produced by filter_variant_selector). With the new layout
#      this is typically `file.path(output_dir, "shapefiles")`.
#   4. Spatial summary of the BSE raster is delegated to GEM_ files
#      (quantile breakdown), written when uncertainty = TRUE. The previous
#      MEAN_BSE column in VAM has been removed because (i) it duplicated
#      information available from the BSE raster, and (ii) the mean is a
#      poor summary of a typically right-skewed uncertainty distribution;
#      consumers should use GEM quantiles instead.
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


# ==============================================================================
# .compute_pic_kfold() — k-fold cross-validated calibration of the BSE layer
# ==============================================================================
# Standalone, side-effect-free helper (returns a one-row data.frame) so the
# calibration logic can be unit-tested without running a full interpolation.
#
# WHY k-FOLD, SEPARATE FROM THE PRODUCTION FIT
# --------------------------------------------
# The published DOY/BSE rasters are built from ALL stations (best surface, most
# representative uncertainty). PICP, by definition, needs out-of-sample points:
# "when the model predicts where it did NOT see data, how often does the truth
# fall in the interval?" These two needs cannot be met by one fit — a single
# all-data fit has no out-of-sample points, and holding 25% out would degrade
# the published product. So calibration is computed by a DEDICATED k-fold CV
# pass that does not touch the published rasters. This is the standard pattern:
# report cross-validated metrics alongside a final model trained on all data.
#
# Each station is held out exactly once (in one fold). For each fold we refit
# the BAM on the other k-1 folds — mirroring the production formula and fit
# settings exactly — and predict at the held-out fold's stations WITH se.fit,
# which is the per-station analogue of the BSE. Pooling the out-of-fold
# (DOY, DOY_pred, se_fit) triples over all folds gives one PICP/MPIW per
# (phase, year), evaluated on every station, none of them in-sample at the
# point of evaluation.
#
# Inputs:
#   obs_all    sf/data.frame of ALL stations with columns DOY, X, Y, DEM.
#   bam_k_used integer basis dimension used by the production BAM fit (folds
#              reuse it so the CV mirrors production; capped to fold size).
#   sigma2     residual/scale variance of the PRODUCTION all-data BAM fit
#              (bam_fit$sig2). This is the residual-variance term added to the
#              fold se.fit so the interval is a *prediction* interval, not a
#              confidence interval for the mean. Using the production sigma2
#              (not a per-fold one) keeps the calibration anchored to the
#              published model's scale.
#   method     only "bam" is calibrated; others skip with a reason.
#   k          number of folds (default 5).
#   nominal    nominal coverage (default 0.90 -> z = qnorm(0.95) = 1.645).
#   plant,phase,year, seed   identifiers / reproducibility.
#
# Output (one row): PLANT PHASE YEAR NOMINAL Z PICP MPIW SIGMA2 VN K METHOD REASON
#   - PICP : pooled out-of-fold coverage = mean(|DOY - DOY_pred| <= half_width)
#   - MPIW : mean pooled out-of-fold interval width (= mean 2*half_width), days
#   - VN   : number of out-of-fold stations actually evaluated
#   - K    : folds actually used
#   - REASON : NA when computed; a short string when skipped
#
# Interval: half_width_i = z * sqrt( se_fit_i^2 + sigma2 ). Assumes Gaussian,
# homoscedastic residuals and a single global sigma2 — aggregate PICP can mask
# regional miscalibration where station density varies (documented caveat).
.compute_pic_kfold <- function(obs_all, bam_k_used, sigma2, method,
                               k = 5, nominal = 0.90,
                               plant = NA, phase = NA, year = NA,
                               seed = 1L) {

  skip <- function(reason, vn = 0L, kk = NA_integer_) data.frame(
    PLANT = plant, PHASE = phase, YEAR = year,
    NOMINAL = nominal, Z = NA_real_,
    PICP = NA_real_, MPIW = NA_real_, SIGMA2 = NA_real_,
    VN = vn, K = kk, METHOD = method, REASON = reason,
    stringsAsFactors = FALSE
  )

  if (!identical(method, "bam"))
    return(skip(paste0("k-fold PIC defined for method='bam' only (got '", method, "')")))
  if (is.null(obs_all) || nrow(obs_all) == 0)
    return(skip("no stations available for cross-validation"))
  if (is.na(sigma2))
    return(skip("production residual variance (sigma2) unavailable"))

  df_all <- as.data.frame(obs_all)
  needed <- c("DOY", "X", "Y", "DEM")
  if (!all(needed %in% names(df_all)))
    return(skip(paste0("stations missing required columns: ",
                       paste(setdiff(needed, names(df_all)), collapse = ", "))))
  df_all <- df_all[stats::complete.cases(df_all[, needed]), , drop = FALSE]
  n <- nrow(df_all)
  if (n < 2L * k)
    return(skip(sprintf("too few stations (%d) for %d-fold CV", n, k)))

  # Assign folds. caret::createFolds keeps folds balanced; fall back to a
  # simple modulo partition if caret is unavailable.
  set.seed(seed)
  if (requireNamespace("caret", quietly = TRUE)) {
    fold_id <- integer(n)
    folds <- caret::createFolds(df_all$DOY, k = k, list = TRUE, returnTrain = FALSE)
    for (i in seq_along(folds)) fold_id[folds[[i]]] <- i
  } else {
    fold_id <- sample(rep(seq_len(k), length.out = n))
  }

  z <- stats::qnorm(1 - (1 - nominal) / 2)

  oof <- vector("list", k)   # out-of-fold (DOY, pred, se) per fold
  for (i in seq_len(k)) {
    test_idx  <- which(fold_id == i)
    train_idx <- which(fold_id != i)
    if (!length(test_idx) || length(train_idx) < 10L) next

    train_i <- df_all[train_idx, , drop = FALSE]
    test_i  <- df_all[test_idx,  , drop = FALSE]

    # k must not exceed the fold's data support; cap it as the production
    # logic would for a smaller n.
    k_i <- min(bam_k_used, max(10L, floor(nrow(train_i) * 0.6)))

    fit_i <- tryCatch(
      mgcv::bam(DOY ~ s(X, Y, k = k_i) + DEM,
                data = train_i, method = "fREML", discrete = TRUE),
      error = function(e) NULL
    )
    if (is.null(fit_i)) next

    pr <- tryCatch(
      mgcv::predict.bam(fit_i, newdata = test_i, se.fit = TRUE, type = "response"),
      error = function(e) NULL
    )
    if (is.null(pr)) next

    oof[[i]] <- data.frame(
      DOY  = test_i$DOY,
      pred = as.numeric(pr$fit),
      se   = as.numeric(pr$se.fit),
      stringsAsFactors = FALSE
    )
  }

  pooled <- do.call(rbind, oof)
  pooled <- pooled[stats::complete.cases(pooled), , drop = FALSE]
  k_used <- sum(vapply(oof, function(x) !is.null(x) && nrow(x) > 0, logical(1)))
  if (is.null(pooled) || nrow(pooled) == 0)
    return(skip("no out-of-fold predictions produced", kk = k_used))

  # Prediction interval: fold se.fit (SE of the fitted mean for that fold) plus
  # the production residual variance, so it covers an individual observation.
  half_width <- z * sqrt(pooled$se^2 + sigma2)
  inside     <- abs(pooled$DOY - pooled$pred) <= half_width

  data.frame(
    PLANT = plant, PHASE = phase, YEAR = year,
    NOMINAL = nominal,
    Z       = round(z, 4),
    PICP    = round(mean(inside), 4),
    MPIW    = round(mean(2 * half_width), 2),
    SIGMA2  = round(sigma2, 4),
    VN      = nrow(pooled),
    K       = k_used,
    METHOD  = method,
    REASON  = NA_character_,
    stringsAsFactors = FALSE
  )
}


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
    subfolders  = TRUE,
    skip_on_missing_input = TRUE,
    gaps_file   = NULL,
    calibrate   = NULL,
    n_folds     = 5L
) {

  message("Spatial interpolation of DOY for PLANT = ", plant,
          ", PHASE = ", phase, ", YEAR = ", year)

  # Validate method argument
  valid_methods <- c("krige", "spline", "bam")
  if (!method %in% valid_methods) {
    stop("Invalid method: '", method, "'. Must be one of: ",
         paste(valid_methods, collapse = ", "))
  }

  # k-fold calibration (PICP/MPIW) is meaningful only for the BAM method (the
  # only one with the predict.bam se.fit machinery the interval is built on).
  # Default: run it whenever method == "bam". It is INDEPENDENT of the
  # validation / uncertainty flags by design — calibration uses its own k-fold
  # CV over ALL stations and never touches the published all-data DOY/BSE
  # rasters (see .compute_pic_kfold). Set calibrate = FALSE to skip the k
  # extra fits per (phase, year) for speed.
  if (is.null(calibrate)) calibrate <- identical(method, "bam")

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
    if (!isTRUE(skip_on_missing_input)) {
      stop("Shapefile not found: ", shp_path, "\n",
           "Verify filter_variant_selector has run and produced the optimal shapefile.")
    }
    # The selector intentionally produced no optimal shapefile for this
    # (phase, year) — typically because no filter variant met the min_obs /
    # min_cor constraints (i.e. too few samples). Rather than abort the
    # whole loop, write a full-extent NA DOY surface (and NA uncertainty
    # surface if requested) on the DEM grid so the (phase, year) slot still
    # exists as a complete raster, and record the skip. The Hook B publisher
    # then NA-pads / documents it like any other gap.
    reason <- "no_input_shapefile (selector dropped this phase/year; see GAPS log)"
    # Try to enrich the reason from the selector's gap log if available.
    if (is.null(gaps_file)) {
      cand <- file.path(dirname(shp_dir), "opt_scores",
                        paste0("GAPS_", plant, ".csv"))
      if (file.exists(cand)) gaps_file <- cand
    }
    if (!is.null(gaps_file) && file.exists(gaps_file)) {
      gl <- tryCatch(utils::read.csv2(gaps_file, stringsAsFactors = FALSE),
                     error = function(e) NULL)
      if (!is.null(gl) && all(c("PHASE","YEAR","REASON") %in% names(gl))) {
        hit <- gl[gl$PHASE == phase & gl$YEAR == year, , drop = FALSE]
        if (nrow(hit) >= 1) reason <- hit$REASON[1]
      }
    }
    message("SKIP: no input shapefile for PLANT=", plant, " PHASE=", phase,
            " YEAR=", year, " — writing NA surface(s). Reason: ", reason)

    na_grid <- dem_raster
    raster::values(na_grid) <- NA_real_

    doy_path <- file.path(out_cogs,
                          paste0("DOY_", plant, "-", phase, "_", year, ".tif"))
    raster::writeRaster(na_grid, doy_path, overwrite = TRUE)
    if (uncertainty) {
      unc_suffix <- switch(method, "krige" = "KSV", "spline" = "SSE", "bam" = "BSE")
      unc_path <- file.path(out_cogs,
                            paste0(unc_suffix, "_", plant, "-", phase,
                                    "_", year, ".tif"))
      raster::writeRaster(na_grid, unc_path, overwrite = TRUE)
    }

    return(invisible(list(
      interpolation      = na_grid,
      uncertainty        = if (uncertainty) na_grid else NULL,
      validation_metrics = NULL,
      n_observations     = 0L,
      method_used        = method,
      bam_k_used         = NA,
      status             = "skipped",
      skip_reason        = reason
    )))
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

  # Residual variance of the fit, captured at fit time for the prediction-
  # interval calibration check in STEP 6. Only the BAM path sets a real
  # value (bam_fit$sig2); kriging and TPS leave it NA, which makes the
  # calibration step skip gracefully for those methods.
  bam_sig2 <- NA_real_

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

    # Residual (scale) variance of the Gaussian BAM fit. Used in STEP 6 to
    # form an honest *prediction* interval for individual held-out stations
    # (BSE alone is the SE of the fitted mean and omits this term). mgcv
    # stores the estimated scale in $sig2; fall back to $scale if absent.
    bam_sig2 <- if (!is.null(bam_fit$sig2)) bam_fit$sig2
                else if (!is.null(bam_fit$scale)) bam_fit$scale
                else NA_real_

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

    # Spatial quantile breakdown of the uncertainty raster, written to GEM.
    # Replaces the previous MEAN_BSE scalar; consumers should prefer the
    # quantile representation (richer summary, robust to skew).
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
  # STEP 6b: k-fold cross-validated calibration (PIC) of the BSE layer
  # ============================================================================
  # PICP/MPIW measure how well the BSE uncertainty layer is calibrated as a
  # *predictive* uncertainty: when the model predicts where it did not see
  # data, how often does the truth fall inside the interval?
  #
  # This is computed by a DEDICATED k-fold CV pass over ALL stations, entirely
  # separate from the production fit. The published DOY/BSE rasters are built
  # from all samples (best surface, most representative uncertainty); holding
  # data out for PICP would degrade them, while an all-data fit has no
  # out-of-sample points to measure coverage on. Decoupling resolves that
  # tension — every station is held out exactly once across the folds, and the
  # published rasters are never touched. The residual-variance term added to
  # each fold's se.fit is sigma2 from the PRODUCTION all-data fit, anchoring
  # the calibration to the published model's scale.
  #
  # Independent of the validation / uncertainty flags by design. Runs when
  # calibrate = TRUE (default: TRUE for method = "bam"). Set calibrate = FALSE
  # to skip the k extra fits per (phase, year).
  if (isTRUE(calibrate)) {
    pic <- .compute_pic_kfold(
      obs_all    = obs_sf,            # ALL stations (not the train/test split)
      bam_k_used = if (method == "bam") bam_k_used else NA_integer_,
      sigma2     = bam_sig2,          # production all-data residual variance
      method     = method,
      k          = n_folds,
      nominal    = 0.90,
      plant = plant, phase = phase, year = year
    )
    pic_path <- file.path(out_vam,
                          paste0("PIC_", plant, "-", phase, "_", year, ".csv"))
    utils::write.csv2(pic, file = pic_path, row.names = FALSE)
    if (!is.na(pic$PICP)) {
      message(sprintf("Calibration (%d-fold PIC) written: %s", pic$K, pic_path))
      message(sprintf("PICP@%.0f%% = %.3f (nominal %.2f) | MPIW = %.2f days | sigma^2 = %.2f | N_oof = %d",
                      100 * pic$NOMINAL, pic$PICP, pic$NOMINAL, pic$MPIW, pic$SIGMA2, pic$VN))
    } else {
      message(sprintf("Calibration (k-fold PIC) skipped: %s  [%s]", pic$REASON, pic_path))
    }
  } else {
    message("Calibration (k-fold PIC) disabled (calibrate = FALSE)")
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
    bam_k_used          = if (method == "bam") bam_k_used else NA
  ))
}

################################################################################
# END OF FILE
################################################################################
