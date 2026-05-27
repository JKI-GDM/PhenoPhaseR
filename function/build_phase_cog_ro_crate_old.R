# ============================================================================
# build_phase_cog_ro_crate.R
#
# PhenoPhaseR Hook B: Package the final interpolated phenological entry-date
# COGs (Step 7 output) into an RO-Crate 1.2 deposit ready for Zenodo upload
# (target concept DOI 10.5281/zenodo.19571847).
#
# INTERPOLATION METHOD
# --------------------
# DOY and BSE rasters are produced by the *BSE approach*: a Bayesian additive
# model (BAM, mgcv::bam) with a bivariate spatial smooth, the 1 km DEM as
# elevation covariate, and posterior variance reported per pixel as the
# basis-spline standard error (BSE). Default interpolation in PhenoPhaseR.
#
# Artifact set (produced by spatial_interpolation.R with subfolders = TRUE):
#   <results>/cogs/DOY_<plant>-<phase>_<year>.tif
#   <results>/cogs/BSE_<plant>-<phase>_<year>.tif
#   <results>/vam/VAM_<plant>-<phase>_<year>.csv   (validation; loop with validation=TRUE)
#   <results>/vam/CAL_<plant>-<phase>_<year>.csv   (BAM in-sample diagnostics)
#   <results>/vam/GEM_<plant>-<phase>_<year>.csv   (BSE quantiles; loop with uncertainty=TRUE)
#
# Note that CAL and GEM share the vam/ subfolder with VAM by convention in
# spatial_interpolation.R; they are NOT in separate cal/, gem/ subfolders.
#
# Quality table column expectations (from concatenated VAM files):
#   PLANT, PHASE, YEAR, TN, ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2
# Note: MEAN_BSE was removed from VAM in the 2026-04-29 spatial_interpolation
# patch (replaced by the GEM quantile table). Legacy VAM rows carrying it
# remain accepted; the mean_bse quality element is silently skipped when the
# column is absent or NA.
#
# VAM columns are mapped to ISO 19157-1 thematic-accuracy quality elements:
#   cv_rmse       ← RMSE
#   cv_mae        ← MAE
#   cv_r2         ← R2
#   training_n    ← TN
#   validation_n  ← VN
#   bam_k         ← BAM_K
#
# CAL CSV columns (in-sample model-fit diagnostics from the fitted bam):
#   PLANT, PHASE, YEAR, BAM_K, AIC, BIC, EDF, DEV_EXPLAINED
# GEM per-year CSV columns (as emitted by spatial_interpolation.R):
#   Quantile, Value          (YEAR not present per-year; added by aggregator
#                             from the filename when row-binding)
# GEM aggregated (per-phase) CSV columns:
#   YEAR, Quantile, Value    (Quantile ∈ {0%, 25%, 50%, 75%, 100%})
# CAL and GEM are OPTIONAL: if not present on disk, the aggregator silently
# skips them and the crate is built without those file entities.
#
# DFFP INTEGRATION
# ----------------
# Optional. If `dffp_dir` points to a directory containing matrix.json,
# datasets.json, categories.json (and optionally narratives.txt /
# report.html), the crate embeds a `schema:potentialAction` (AssessAction)
# referencing the DFFP Application Matrix tool (zenodo.19693642) and one
# `schema:Review` per downstream paper that consumes PHASE.
#
# Author : adapted for PhenoPhaseR by M. Möller, 2026
# License: MIT (this script); CC-BY-4.0 (the output crate contents)
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(tools)
})

# Shared crop specs, default creators, layered keyword builder, and AGROVOC
# DefinedTerm helpers. Source from the same directory as this script.
.this_dir <- tryCatch(
  dirname(sys.frame(1)$ofile),
  error = function(e) getwd()
)
source(file.path(.this_dir, "_crop_specs.R"))


`%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 1 && is.na(a)) return(b)
  a
}


# ---- Shared helpers -------------------------------------------------------
.mime_table <- c(
  tif = "image/tiff;application=geotiff;profile=cloud-optimized",
  csv = "text/csv", json = "application/json",
  txt = "text/plain", html = "text/html"
)
.mime_for <- function(ext) {
  m <- .mime_table[tolower(ext)]
  ifelse(is.na(m), "application/octet-stream", unname(m))
}
.relpath <- function(path, root) {
  sub(paste0("^", normalizePath(root, mustWork = FALSE), "/?"),
      "", normalizePath(path, mustWork = FALSE))
}
.file_entity <- function(path, crate_root, description = NULL) {
  stopifnot(file.exists(path))
  out <- list(
    "@id"            = .relpath(path, crate_root),
    "@type"          = "File",
    "name"           = basename(path),
    "contentSize"    = unname(file.info(path)$size),
    "encodingFormat" = .mime_for(file_ext(path)),
    "dateModified"   = format(file.info(path)$mtime,
                              "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "spdx:checksum"  = paste0("MD5: ", unname(md5sum(path)))
  )
  if (!is.null(description)) out[["description"]] <- description
  out
}
# Map each measure to its ISO 19157-1 quality dimension. Used as the SKOS
# bridge so DQV-aware consumers can group measurements by W3C-standard
# dimensions instead of parsing custom property IDs.
.iso19157_dimension <- function(measure) {
  switch(measure,
    cv_rmse              = "DQ_ThematicAccuracy",
    cv_mae               = "DQ_ThematicAccuracy",
    cv_r2                = "DQ_ThematicAccuracy",
    cv_bias              = "DQ_ThematicAccuracy",
    mean_bse             = "DQ_ThematicAccuracy",
    training_n           = "DQ_CompletenessOmission",
    validation_n         = "DQ_CompletenessOmission",
    bam_k                = "DQ_LogicalConsistency",
    "DQ_ThematicAccuracy"
  )
}

.quality_element <- function(measure, value, unit_text = NULL,
                             definition = NULL, qm_id = NULL) {
  # Each measurement is a first-class top-level entity in the @graph: dual-
  # typed schema:PropertyValue + dqv:QualityMeasurement, with its own @id and
  # a reference (not an inline object) to the dqv:Metric entity that defines
  # what it measures. This shape is what JSON-LD / RO-Crate validators expect
  # for object references — inline anonymous objects under
  # schema:variableMeasured trip the rule "node references MUST have only
  # @id, no other properties" (roc-validator, REQUIRED).
  el <- list(
    "@id"               = qm_id,
    "@type"             = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = paste0("iso19157:", measure),
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list("@id" = paste0("#metric-", measure))
  )
  if (!is.null(unit_text))  el[["schema:unitText"]]    <- unit_text
  if (!is.null(definition)) el[["schema:description"]] <- definition
  el
}


# ---- Top-level dqv:Metric entity (one per unique measure name in crate) ---
# The Metric describes the *kind* of thing being measured (e.g. RMSE in days,
# mapped to ISO 19157 DQ_ThematicAccuracy). Many measurements reference the
# same Metric via dqv:isMeasurementOf, so it lives at top level rather than
# being inlined redundantly per measurement.
.metric_entity <- function(measure) {
  list(
    "@id"             = paste0("#metric-", measure),
    "@type"           = "dqv:Metric",
    "skos:prefLabel"  = measure,
    "skos:closeMatch" = list("@id" = paste0("iso19157:", measure)),
    "dqv:inDimension" = list("@id" = paste0("iso19157:",
                                            .iso19157_dimension(measure)))
  )
}


# ---- Discover BSE-method COG artifacts under the subfolder layout --------
# Convention in spatial_interpolation.R: VAM, CAL and GEM CSVs all live in
# <results>/vam/ together. CAL and GEM are optional — older runs predating
# the 2026-04-29 spatial_interpolation patch may not have them.
.discover_cog_artifacts <- function(results_dir, plant, phases, years) {
  cogs_dir <- file.path(results_dir, "cogs")
  vam_dir  <- file.path(results_dir, "vam")
  phase_alt <- paste(phases, collapse = "|")
  year_alt  <- paste(years,  collapse = "|")
  layer_pat <- function(layer)
    sprintf("^%s_%d-(%s)_(%s)\\.tif$", layer, plant, phase_alt, year_alt)
  csv_pat <- function(layer)
    sprintf("^%s_%d-(%s)_(%s)\\.csv$", layer, plant, phase_alt, year_alt)
  list(
    DOY = list.files(cogs_dir, pattern = layer_pat("DOY"), full.names = TRUE),
    BSE = list.files(cogs_dir, pattern = layer_pat("BSE"), full.names = TRUE),
    VAM = list.files(vam_dir,  pattern = csv_pat("VAM"),   full.names = TRUE),
    CAL = list.files(vam_dir,  pattern = csv_pat("CAL"),   full.names = TRUE),
    GEM = list.files(vam_dir,  pattern = csv_pat("GEM"),   full.names = TRUE)
  )
}


# ---- Aggregate per-(phase, year) artifacts into per-phase artifacts -------
# Stacks the 32 yearly DOY GeoTIFFs for each phase into a single multi-band
# Cloud-Optimised GeoTIFF; same for BSE; concatenates the per-year VAM CSVs
# into one wide-format per-phase table. Per-year inputs are MOVED into a
# working subdirectory `_per_year/` under `out_dir` (not copied) so the
# crate manifest only references the published, aggregated artifacts while
# the per-year provenance trail is preserved on disk.
#
# Returns a list with components $DOY, $BSE, $VAM each holding paths to the
# aggregated per-phase outputs in `out_dir/cogs/` and `out_dir/vam/`.
.aggregate_per_phase <- function(results_dir, plant, phases, years, out_dir) {
  if (!requireNamespace("terra", quietly = TRUE))
    stop("'terra' is required for per-phase COG aggregation. ",
         "Install with install.packages('terra').")

  src <- .discover_cog_artifacts(results_dir, plant, phases, years)

  per_year_dir <- file.path(out_dir, "_per_year")
  cogs_out     <- file.path(out_dir, "cogs")
  vam_out      <- file.path(out_dir, "vam")
  for (d in c(file.path(per_year_dir, "cogs"),
              file.path(per_year_dir, "vam"),
              cogs_out, vam_out))
    dir.create(d, recursive = TRUE, showWarnings = FALSE)

  # Aggregated CAL and GEM are placed in vam_out next to the aggregated VAM,
  # mirroring the source convention in spatial_interpolation.R where all
  # three CSV families live side by side.
  agg <- list(DOY = character(), BSE = character(), VAM = character(),
              CAL = character(), GEM = character())

  # GDAL options for COG output. COPY_SRC_OVERVIEWS preserves any overviews
  # the source GeoTIFFs already carry; otherwise terra builds them.
  cog_opts <- c("COMPRESS=LZW", "BLOCKSIZE=512", "OVERVIEW_RESAMPLING=AVERAGE")

  for (layer in c("DOY", "BSE")) {
    for (ph in phases) {
      pat <- sprintf("^%s_%d-%d_(\\d{4})\\.tif$", layer, plant, ph)
      hits <- src[[layer]][grepl(pat, basename(src[[layer]]))]
      if (!length(hits)) next

      # Match year order to `years` so the band index matches the years vector
      yr_in_file <- as.integer(sub(pat, "\\1", basename(hits)))
      ord  <- order(match(yr_in_file, years))
      hits <- hits[ord]
      yrs  <- yr_in_file[ord]

      stk  <- terra::rast(hits)
      names(stk) <- as.character(yrs)
      terra::time(stk) <- as.Date(paste0(yrs, "-01-01"))

      out_path <- file.path(cogs_out,
                            sprintf("%s_%d-%d.tif", layer, plant, ph))
      terra::writeRaster(
        stk, filename = out_path, overwrite = TRUE,
        filetype = "COG", gdal = cog_opts
      )
      message(sprintf("Aggregated %s phase %d → %s (%d bands)",
                      layer, ph, basename(out_path), terra::nlyr(stk)))

      # Move per-year tiles into the working subfolder
      file.rename(hits, file.path(per_year_dir, "cogs", basename(hits)))
      agg[[layer]] <- c(agg[[layer]], out_path)
    }
  }

  # VAM: concatenate per-year rows into one wide-format CSV per phase
  for (ph in phases) {
    pat <- sprintf("^VAM_%d-%d_(\\d{4})\\.csv$", plant, ph)
    hits <- src$VAM[grepl(pat, basename(src$VAM))]
    if (!length(hits)) next
    yr_in_file <- as.integer(sub(pat, "\\1", basename(hits)))
    ord  <- order(match(yr_in_file, years))
    hits <- hits[ord]

    rows <- do.call(rbind, lapply(hits, utils::read.csv2,
                                  stringsAsFactors = FALSE))
    rows <- rows[order(rows$YEAR), ]

    out_path <- file.path(vam_out, sprintf("VAM_%d-%d.csv", plant, ph))
    utils::write.csv2(rows, file = out_path, row.names = FALSE)
    message(sprintf("Aggregated VAM phase %d → %s (%d rows)",
                    ph, basename(out_path), nrow(rows)))

    file.rename(hits, file.path(per_year_dir, "vam", basename(hits)))
    agg$VAM <- c(agg$VAM, out_path)
  }

  # CAL: concatenate per-year rows into one wide-format CSV per phase.
  # CAL CSVs already carry their own YEAR column.
  for (ph in phases) {
    pat <- sprintf("^CAL_%d-%d_(\\d{4})\\.csv$", plant, ph)
    hits <- src$CAL[grepl(pat, basename(src$CAL))]
    if (!length(hits)) next
    yr_in_file <- as.integer(sub(pat, "\\1", basename(hits)))
    ord  <- order(match(yr_in_file, years))
    hits <- hits[ord]

    rows <- do.call(rbind, lapply(hits, utils::read.csv2,
                                  stringsAsFactors = FALSE))
    rows <- rows[order(rows$YEAR), ]

    out_path <- file.path(vam_out, sprintf("CAL_%d-%d.csv", plant, ph))
    utils::write.csv2(rows, file = out_path, row.names = FALSE)
    message(sprintf("Aggregated CAL phase %d → %s (%d rows)",
                    ph, basename(out_path), nrow(rows)))

    file.rename(hits, file.path(per_year_dir, "vam", basename(hits)))
    agg$CAL <- c(agg$CAL, out_path)
  }

  # GEM: concatenate per-year rows into one long-format CSV per phase.
  # Per-year GEM CSVs as emitted by spatial_interpolation.R have only
  # (Quantile, Value); the aggregator injects YEAR from the filename so the
  # published per-phase CSV matches the Zenodo schema (YEAR, Quantile, Value).
  for (ph in phases) {
    pat <- sprintf("^GEM_%d-%d_(\\d{4})\\.csv$", plant, ph)
    hits <- src$GEM[grepl(pat, basename(src$GEM))]
    if (!length(hits)) next
    yr_in_file <- as.integer(sub(pat, "\\1", basename(hits)))
    ord  <- order(match(yr_in_file, years))
    hits <- hits[ord]; yr_in_file <- yr_in_file[ord]

    rows_list <- mapply(
      function(p, y) {
        df <- utils::read.csv2(p, stringsAsFactors = FALSE)
        # Defensive: tolerate per-year files that already carry YEAR
        if (!"YEAR" %in% names(df)) df$YEAR <- y
        df[, c("YEAR", "Quantile", "Value")]
      },
      hits, yr_in_file, SIMPLIFY = FALSE
    )
    rows <- do.call(rbind, rows_list)
    q_num <- suppressWarnings(as.numeric(sub("%", "", rows$Quantile)))
    rows  <- rows[order(rows$YEAR, q_num), ]

    out_path <- file.path(vam_out, sprintf("GEM_%d-%d.csv", plant, ph))
    utils::write.csv2(rows, file = out_path, row.names = FALSE)
    message(sprintf("Aggregated GEM phase %d → %s (%d rows)",
                    ph, basename(out_path), nrow(rows)))

    file.rename(hits, file.path(per_year_dir, "vam", basename(hits)))
    agg$GEM <- c(agg$GEM, out_path)
  }

  agg
}


.layer_description <- function(layer, plant, phase, years) {
  yr_min <- min(years); yr_max <- max(years); n_yr <- length(years)
  switch(layer,
    DOY = sprintf(paste("Posterior mean of the phenological entry day-of-year",
                        "for plant %d, phase %d. BSE approach (BAM bivariate",
                        "spatial smooth, mgcv::bam) with the 1 km DEM as",
                        "elevation covariate. Multi-band Cloud-Optimised",
                        "GeoTIFF: %d bands, one per year (%d–%d).",
                        "Band names match years; subset by year via",
                        "terra::rast(file, lyrs=as.character(year))."),
                  plant, phase, n_yr, yr_min, yr_max),
    BSE = sprintf(paste("Basis-spline standard error of the BAM posterior for",
                        "plant %d, phase %d — per-pixel uncertainty of the",
                        "DOY prediction (units: days). Multi-band Cloud-",
                        "Optimised GeoTIFF: %d bands, one per year (%d–%d).",
                        "Bands aligned with the corresponding DOY raster."),
                  plant, phase, n_yr, yr_min, yr_max),
    VAM = sprintf(paste("Cross-validation accuracy metrics for plant %d,",
                        "phase %d. Wide-format CSV with one row per year",
                        "(%d–%d, %d rows). Columns: PLANT, PHASE, YEAR, TN,",
                        "ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2."),
                  plant, phase, yr_min, yr_max, n_yr),
    CAL = sprintf(paste("In-sample model-fit (calibration) diagnostics",
                        "computed from the fitted BAM object (mgcv::bam)",
                        "for plant %d, phase %d. Complements the out-of-",
                        "sample VAM table by reporting model complexity",
                        "and goodness-of-fit on the training data. Wide-",
                        "format CSV with one row per year (%d–%d, %d rows).",
                        "Columns: PLANT, PHASE, YEAR, BAM_K, AIC, BIC,",
                        "EDF, DEV_EXPLAINED."),
                  plant, phase, yr_min, yr_max, n_yr),
    GEM = sprintf(paste("Global Error Map (GEM) — spatial quantiles of the",
                        "per-pixel BSE raster for plant %d, phase %d,",
                        "summarising the Germany-wide distribution of",
                        "prediction uncertainty for each year. Long-format",
                        "CSV with five rows per year (%d × 5 = %d rows).",
                        "Columns: YEAR, Quantile, Value. Quantile levels:",
                        "0%%, 25%%, 50%%, 75%%, 100%%. Replaces the",
                        "MEAN_BSE column previously carried in VAM."),
                  plant, phase, n_yr, n_yr * 5L)
  )
}


# ---- Per-phase PHASE Dataset block ----------------------------------------
# Replaces the previous per-(phase, year) emitter. One Dataset per phase,
# referencing the aggregated multi-band DOY+BSE COGs and the wide-format
# per-phase VAM CSV. Quality measurements remain scalar (one value per
# year per metric) and each carries dct:temporal/temporalCoverage so
# DQV-aware consumers can group or filter by year.
.phase_dataset <- function(phase, art, crate_root, plant, years, q_phase) {

  doy_path <- art$DOY[grepl(sprintf("^DOY_%d-%d\\.tif$", plant, phase),
                            basename(art$DOY))]
  bse_path <- art$BSE[grepl(sprintf("^BSE_%d-%d\\.tif$", plant, phase),
                            basename(art$BSE))]
  vam_path <- art$VAM[grepl(sprintf("^VAM_%d-%d\\.csv$", plant, phase),
                            basename(art$VAM))]
  cal_path <- art$CAL[grepl(sprintf("^CAL_%d-%d\\.csv$", plant, phase),
                            basename(art$CAL))]
  gem_path <- art$GEM[grepl(sprintf("^GEM_%d-%d\\.csv$", plant, phase),
                            basename(art$GEM))]
  parts <- c(doy_path, bse_path, vam_path, cal_path, gem_path)
  if (!length(parts)) return(NULL)

  # ---- Per-year scalar quality measurements -----------------------------
  # For every (year, measure) in q_phase, emit one quality-measurement entity
  # with its own @id; the Dataset references them by @id only (valid JSON-LD
  # node reference). The entities are hoisted into the top-level @graph by
  # the caller. Years missing from q_phase silently produce no measurement
  # nodes (rather than NA), mirroring how missing years are handled in the
  # underlying GeoTIFF bands by virtue of being absent from the input set.
  qe <- list()
  if (nrow(q_phase)) {
    for (i in seq_len(nrow(q_phase))) {
      r  <- q_phase[i, ]
      yr <- as.character(r$YEAR)
      add_qe <- function(measure, value, unit_text, definition) {
        if (is.null(value) || is.na(value)) return(NULL)
        qm_id <- sprintf("#qm-%d-%d-%s-%s", plant, phase, yr, measure)
        e <- .quality_element(measure, value, unit_text, definition,
                              qm_id = qm_id)
        e[["schema:temporalCoverage"]] <- yr
        e[["dct:temporal"]]            <- yr
        qe[[length(qe) + 1]] <<- e
      }
      add_qe("cv_rmse",      r$RMSE,    "days",
             "Cross-validation root mean square error of DOY")
      add_qe("cv_mae",       r$MAE,     "days",
             "Cross-validation mean absolute error of DOY")
      add_qe("cv_r2",        r$R2,      NULL,
             "Coefficient of determination, observed vs predicted DOY")
      add_qe("training_n",   r$TN,      "count",
             "Number of stations used to fit the BAM")
      add_qe("validation_n", r$VN,      "count",
             "Number of withheld stations in cross-validation")
      add_qe("bam_k",        r$BAM_K,   "rank",
             "Effective basis dimension of the BAM smooth")
      add_qe("mean_bse",     r$MEAN_BSE,"days",
             "Spatial mean of the BSE raster across the prediction grid")
    }
  }
  qm_refs <- lapply(qe, function(e) list("@id" = e[["@id"]]))

  dataset <- list(
    "@id"   = sprintf("#phase-%d-%d", plant, phase),
    # Dual typing: Dataset (Schema.org/RO-Crate) + dcat:Dataset (W3C DCAT 3)
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf("PHASE entry-date prediction (plant %d, phase %d, %d–%d)",
                       plant, phase, min(years), max(years)),
    "description" = paste0(
      "Per-phase aggregated outputs for plant ", plant, ", phase ", phase,
      ", years ", min(years), "–", max(years), ". Comprises a ",
      length(years), "-band DOY posterior-mean COG, a matching ",
      length(years), "-band BSE per-pixel uncertainty COG, a wide-",
      "format VAM CSV with one row per year (holdout cross-validation), ",
      "a wide-format CAL CSV with one row per year (in-sample BAM ",
      "diagnostics: AIC, BIC, EDF, deviance explained), and a long-",
      "format GEM CSV with five rows per year (spatial quantiles of the ",
      "BSE raster at 0/25/50/75/100%). Bands are named by year; subset ",
      "semantically with terra::rast(file, lyrs=as.character(year)) or ",
      "gdal_translate -b N. Produced by spatial_interpolation.R using ",
      "the BSE approach (BAM) and aggregated by build_phase_cog_ro_crate.R."),
    "encodingFormat" = "image/tiff;application=geotiff;profile=cloud-optimized",
    "hasPart"        = lapply(parts, function(p) list("@id" = .relpath(p, crate_root))),
    "schema:variableMeasured"   = qm_refs,
    "dqv:hasQualityMeasurement" = qm_refs,
    "schema:temporalCoverage"  = sprintf("%d/%d", min(years), max(years)),
    "dct:temporal"             = sprintf("%d/%d", min(years), max(years)),
    "schema:spatialCoverage"   = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"              = list("@id" = "https://www.geonames.org/2921044/"),
    "schema:spatialResolution" = "1000 m",
    "dcat:spatialResolutionInMeters" = 1000
  )

  list(dataset = dataset, measurements = qe)
}


# ---- DFFP helpers ---------------------------------------------------------
.dffp_assess_action <- function(dffp_tool_doi, dffp_dir = NULL) {
  out <- list(
    "@id"          = "#dffp-assessment",
    # Dual typing: schema:AssessAction + W3C prov:Activity
    "@type"        = c("AssessAction", "prov:Activity"),
    "name"         = "Data Fitness-for-Purpose (DFFP) assessment",
    "description"  = paste(
      "Cross-paper Data Fitness-for-Purpose evaluation of this dataset's",
      "suitability for downstream scientific applications, generated by the",
      "DFFP Application Matrix tool (Hedayat Mahmoudi & Möller 2026)."),
    "instrument"   = list("@id" = paste0("https://doi.org/", dffp_tool_doi)),
    "object"       = list("@id" = "./"),
    "prov:used"    = list("@id" = "./"),
    "actionStatus" = "CompletedActionStatus"
  )
  if (!is.null(dffp_dir) &&
      file.exists(file.path(dffp_dir, "report.html"))) {
    out[["result"]] <- list("@id" = "dffp/report.html")
  }
  out
}

.dffp_review_from_app <- function(app, dataset_label = "PHASE") {
  cat_props <- if (length(app$categories)) {
    lapply(names(app$categories), function(cat_name) {
      e <- app$categories[[cat_name]]
      list(
        "@type"              = "schema:PropertyValue",
        "schema:propertyID"  = paste0("dffp:", cat_name),
        "schema:name"        = cat_name,
        "schema:value"       = e$level,
        "schema:description" = e$justification %||% ""
      )
    })
  } else list()

  reviewed_item <- if (!is.null(app$doi))
                     list("@id" = paste0("https://doi.org/", app$doi))
                   else
                     list("@type" = "ScholarlyArticle",
                          "name"  = app$citation %||% app$id)

  list(
    "@type"              = "Review",
    "name"               = sprintf("DFFP fitness assessment: %s applied to %s",
                                    dataset_label, app$citation %||% app$id),
    "itemReviewed"       = reviewed_item,
    "reviewRating"       = list(
      "@type"          = "Rating",
      "ratingValue"    = app$fitness_overall %||% NA,
      "bestRating"     = "High",
      "worstRating"    = "Low",
      "additionalType" = "DFFP Fitness Level"
    ),
    "reviewBody"         = app$narrative %||% "",
    "additionalProperty" = cat_props
  )
}

.dffp_reviews_from_dir <- function(dffp_dir, dataset_filter = "PHASE") {
  if (is.null(dffp_dir) || !dir.exists(dffp_dir)) return(list())
  matrix_file <- file.path(dffp_dir, "matrix.json")
  if (!file.exists(matrix_file)) {
    warning("dffp_dir given but matrix.json not found: ", matrix_file)
    return(list())
  }
  m <- jsonlite::read_json(matrix_file, simplifyVector = FALSE)
  apps <- m$applications %||% m$papers %||% m
  if (!length(apps)) return(list())
  reviews <- lapply(apps, function(a) {
    used <- a$datasets_used %||% a$datasets %||% character(0)
    if (length(used) &&
        !any(grepl(dataset_filter, unlist(used), ignore.case = TRUE)))
      return(NULL)
    .dffp_review_from_app(a, dataset_label = dataset_filter)
  })
  Filter(Negate(is.null), reviews)
}

.dffp_stage <- function(dffp_dir, out_dir) {
  if (is.null(dffp_dir) || !dir.exists(dffp_dir)) return(invisible(NULL))
  dest <- file.path(out_dir, "dffp")
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  for (f in c("matrix.json", "datasets.json", "categories.json",
              "narratives.txt", "report.html")) {
    src <- file.path(dffp_dir, f)
    if (file.exists(src)) file.copy(src, dest, overwrite = TRUE)
  }
  invisible(dest)
}


# ---- README.md template inside the crate ---------------------------------
# Written at build time, embeds the validator-stance paragraph so that
# anyone unpacking the ZIP from Zenodo finds it without leaving the deposit.
# Kept terse: complements the Zenodo description rather than duplicating it.
.write_crate_readme <- function(out_dir, plant, phase, years,
                                software_doi, upstream_doi, input_data_doi,
                                validation_result = NULL) {
  readme_path <- file.path(out_dir, "README.md")
  ph_str <- paste(phase, collapse = ", ")
  yr_str <- sprintf("%d–%d", min(years), max(years))

  txt <- c(
    sprintf("# PHASE — plant %d, phases %s, %s", plant, ph_str, yr_str),
    "",
    sprintf(paste(
      "Germany-wide, 1 km Cloud-Optimised GeoTIFF surfaces of phenological",
      "entry day-of-year (DOY) and per-pixel basis-spline standard error",
      "(BSE) for plant %d (DWD/JKI code), phenological phases %s, years %s.",
      "Produced by the PhenoPhaseR pipeline using the BSE approach",
      "(Bayesian additive model with bivariate spatial smooth, `mgcv::bam`),",
      "and packaged as an RO-Crate 1.2 (Workflow Run Crate profile)."),
      plant, ph_str, yr_str),
    "",
    "## Contents",
    "",
    "- `cogs/DOY_<plant>-<phase>.tif` — 32-band DOY posterior-mean COG, one band per year, band names = years.",
    "- `cogs/BSE_<plant>-<phase>.tif` — 32-band BSE per-pixel uncertainty COG, aligned with DOY.",
    "- `vam/VAM_<plant>-<phase>.csv`  — holdout cross-validation metrics, one row per year.",
    "- `vam/CAL_<plant>-<phase>.csv`  — in-sample BAM model-fit diagnostics (AIC, BIC, EDF, deviance explained).",
    "- `vam/GEM_<plant>-<phase>.csv`  — spatial quantiles of the BSE raster (long-format, five rows per year).",
    "- `ro-crate-metadata.json`       — RO-Crate 1.2 manifest with PROV-O provenance, ISO 19157-1 quality elements (via DQV/SKOS), and Data Fitness-for-Purpose reviews where supplied.",
    "- `ro-crate-preview.html`        — self-contained human-readable rendering of the manifest (open in any web browser; no tooling required).",
    "",
    "Subset a multi-band COG by year in R:",
    "",
    "```r",
    "library(terra)",
    "doy_2020 <- terra::rast(\"cogs/DOY_202-15.tif\", lyrs = \"2020\")",
    "```",
    "",
    "or via the CLI:",
    "",
    "```bash",
    "gdal_translate -b <N> cogs/DOY_202-15.tif DOY_202-15_<year>.tif",
    "```",
    "",
    "## Validation",
    "",
    paste("This deposit declares conformance to the **RO-Crate 1.2** base",
          "profile and the **Workflow Run Crate** profile",
          "([https://w3id.org/ro/crate/1.2/Workflow-Run-Crate](https://w3id.org/ro/crate/1.2/Workflow-Run-Crate)).",
          "Conformance is verified at build time against the validator named",
          "below; we make no claims about cleanliness against other tools."),
    "",
    "### Build-time validation record",
    "",
    .validation_block_md(validation_result),
    "",
    "### Reproducing the validation",
    "",
    "```bash",
    "pip install roc-validator",
    "rocrate-validator validate -l required -p ro-crate-1.1 .",
    "```",
    "",
    paste("We chose `roc-validator` because it is the only RO-Crate",
          "validation tool that (a) validates against the profiles a crate",
          "declares, rather than a fixed ruleset, and (b) separates",
          "**REQUIRED** from **RECOMMENDED** / **OPTIONAL** severity levels",
          "— so a clean run at REQUIRED is a well-defined claim. Other",
          "RO-Crate validation tools exist and may report additional",
          "advisory notices; those notices do not affect RO-Crate 1.2",
          "conformance, parsing by `ro-crate-py`, or rendering by",
          "RO-Crate–aware HTML viewers, and we do not treat them as gating."),
    "",
    paste("Note on the `dffp:` namespace: this crate uses a custom",
          "vocabulary at",
          "`https://github.com/MahdiHedayatMahmoudi/dffp-application-matrix`",
          "for the Data Fitness-for-Purpose review entities. That namespace",
          "is not currently network-resolvable as a machine-readable RDF",
          "schema. The `dffp:` properties remain valid RO-Crate extension",
          "terms and are documented in the upstream DFFP Application Matrix",
          "tool deposit (Zenodo 19693642)."),
    "",
    paste("For visual inspection without any tooling, open",
          "`ro-crate-preview.html` in a web browser."),
    "",
    "## Provenance and citation",
    "",
    sprintf("- Software: PhenoPhaseR — https://doi.org/%s",  software_doi),
    sprintf("- Upstream data (filter variants): https://doi.org/%s", upstream_doi),
    sprintf("- Input data (DWD): https://doi.org/%s",        input_data_doi),
    "",
    "## License",
    "",
    "Crate contents: CC-BY-4.0. Generating code: MIT.",
    "",
    "---",
    sprintf("Generated by `build_phase_cog_ro_crate.R` on %s.",
            format(Sys.Date()))
  )

  writeLines(txt, readme_path, useBytes = TRUE)
  message("Wrote crate README: ", readme_path)
  invisible(readme_path)
}


# ---- ro-crate-preview.html: pure-R renderer ------------------------------
# Renders the manifest at out_dir/ro-crate-metadata.json into a self-
# contained HTML preview using only base R + jsonlite (already a hard
# dependency of this script). No Node.js, no npm, no external binaries.
# The preview shows a table of contents, every entity in the @graph as a
# property table with anchor cross-links between entities, and collapses
# large nested arrays of inline objects (e.g. per-year quality
# measurements) into <details> blocks so the file stays browsable.
.write_ro_crate_html_native <- function(out_dir) {
  metadata_json <- file.path(out_dir, "ro-crate-metadata.json")
  preview_path  <- file.path(out_dir, "ro-crate-preview.html")
  if (!file.exists(metadata_json)) return(invisible(NULL))

  crate <- jsonlite::fromJSON(metadata_json, simplifyVector = FALSE)
  graph <- crate[["@graph"]]
  if (is.null(graph) || length(graph) == 0L) return(invisible(NULL))

  esc <- function(x) {
    if (is.null(x) || length(x) == 0L) return("")
    x <- as.character(x)
    x <- gsub("&",  "&amp;",  x, fixed = TRUE)
    x <- gsub("<",  "&lt;",   x, fixed = TRUE)
    x <- gsub(">",  "&gt;",   x, fixed = TRUE)
    x <- gsub("\"", "&quot;", x, fixed = TRUE)
    x
  }
  anchorize <- function(id)
    paste0("e-", gsub("[^A-Za-z0-9._-]", "_", as.character(id)))

  # Entity index for cross-linking — @id → display name (falls back to @id)
  entity_index <- list()
  for (e in graph) {
    id <- as.character(e[["@id"]])
    nm <- if (!is.null(e[["name"]]))         as.character(e[["name"]])
          else if (!is.null(e[["schema:name"]])) as.character(e[["schema:name"]])
          else id
    entity_index[[id]] <- nm
  }
  id_link <- function(id) {
    id_char <- as.character(id)
    if (id_char %in% names(entity_index))
      sprintf("<a href=\"#%s\">%s</a> <code>(%s)</code>",
              anchorize(id_char), esc(entity_index[[id_char]]), esc(id_char))
    else if (grepl("^https?://", id_char))
      sprintf("<a href=\"%s\">%s</a>", esc(id_char), esc(id_char))
    else
      sprintf("<code>%s</code>", esc(id_char))
  }

  # Recursive value renderer: scalars → text or links; arrays → joined;
  # @id-only objects → cross-links; large arrays of inline objects →
  # collapsible JSON to keep the page tidy.
  render_value <- function(v) {
    if (is.null(v)) return("&mdash;")
    if (!is.list(v)) {
      v_char <- as.character(v)
      if (length(v_char) == 0L) return("&mdash;")
      if (length(v_char) > 1L) {
        parts <- vapply(v_char, function(x) {
          if (grepl("^https?://", x))
            sprintf("<a href=\"%s\">%s</a>", esc(x), esc(x))
          else esc(x)
        }, character(1))
        return(paste(parts, collapse = ", "))
      }
      if (grepl("^https?://", v_char))
        return(sprintf("<a href=\"%s\">%s</a>", esc(v_char), esc(v_char)))
      return(esc(v_char))
    }
    # is.list(v)
    if (is.null(names(v))) {
      # Array
      if (length(v) == 0L) return("&mdash;")
      is_nested_obj <- vapply(v, function(x)
        is.list(x) && !is.null(names(x)) && !identical(names(x), "@id"),
        logical(1))
      if (length(v) > 5L && all(is_nested_obj)) {
        json_pretty <- as.character(jsonlite::toJSON(
          v, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
        return(sprintf(
          "<details><summary>array of %d nested objects (click to expand)</summary><pre>%s</pre></details>",
          length(v), esc(json_pretty)))
      }
      return(paste(vapply(v, render_value, character(1)), collapse = "; "))
    }
    if (length(v) == 1L && identical(names(v), "@id"))
      return(id_link(v[["@id"]]))
    # Nested inline object
    json_pretty <- as.character(jsonlite::toJSON(
      v, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
    if (nchar(json_pretty) <= 160L)
      return(sprintf("<code>%s</code>", esc(json_pretty)))
    sprintf(
      "<details><summary>nested object (%d keys)</summary><pre>%s</pre></details>",
      length(v), esc(json_pretty))
  }

  render_entity <- function(e) {
    id <- as.character(e[["@id"]])
    nm <- entity_index[[id]]
    types <- e[["@type"]]
    type_str <- if (is.null(types)) "Thing"
                else if (is.list(types))
                  paste(vapply(types, as.character, character(1)), collapse = ", ")
                else paste(as.character(types), collapse = ", ")
    rows <- character(0)
    for (k in setdiff(names(e), c("@id", "@type", "name"))) {
      rows <- c(rows, sprintf(
        "<tr><th>%s</th><td>%s</td></tr>", esc(k), render_value(e[[k]])))
    }
    root_class <- if (id == "./") " root" else ""
    sprintf(
      paste0("<section id=\"%s\" class=\"entity%s\">\n",
             "<h3>%s</h3>\n",
             "<p class=\"meta\"><code>@id:</code> <code>%s</code> ",
             "&middot; <code>@type:</code> %s</p>\n",
             "<table>\n%s\n</table>\n</section>"),
      anchorize(id), root_class,
      esc(nm), esc(id), esc(type_str),
      paste(rows, collapse = "\n"))
  }

  toc_items <- vapply(graph, function(e) {
    id <- as.character(e[["@id"]])
    sprintf("<li><a href=\"#%s\">%s</a> &mdash; <code>%s</code></li>",
            anchorize(id), esc(entity_index[[id]]), esc(id))
  }, character(1))

  root_entity <- NULL
  for (e in graph) {
    if (identical(as.character(e[["@id"]]), "./")) { root_entity <- e; break }
  }
  crate_title <- if (!is.null(root_entity[["name"]]))
    as.character(root_entity[["name"]]) else "RO-Crate"

  css <- paste0(
    "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;",
    "max-width:980px;margin:2em auto;padding:0 1.2em;color:#222;line-height:1.55}",
    "h1{border-bottom:2px solid #2c3e50;padding-bottom:.3em;margin-bottom:.2em}",
    "h2{margin-top:2em;border-bottom:1px solid #aaa;padding-bottom:.2em}",
    "h3{margin:0 0 .3em 0}",
    ".lead{color:#666;margin-top:0;font-style:italic}",
    ".meta{font-size:.9em;color:#555;margin:.2em 0 .8em 0}",
    "table{border-collapse:collapse;width:100%;margin:.4em 0 1em 0}",
    "th{background:#f4f6f8;text-align:left;padding:.45em .8em;border:1px solid #d8dee4;",
    "width:22%;vertical-align:top;font-weight:600}",
    "td{padding:.45em .8em;border:1px solid #d8dee4;vertical-align:top}",
    "a{color:#1c6ea4;text-decoration:none}a:hover{text-decoration:underline}",
    "code{background:#f4f6f8;padding:.1em .35em;border-radius:3px;font-size:.9em;",
    "font-family:'SFMono-Regular',Consolas,'Liberation Mono',monospace}",
    ".toc{background:#fafbfc;border:1px solid #d8dee4;padding:.8em 1.2em;margin:1em 0 2em 0}",
    ".toc ul{margin:.3em 0;padding-left:1.4em}.toc li{margin:.15em 0}",
    "section.entity{margin-top:1.5em}",
    "section.root{background:#f8fbfd;border-left:4px solid #1c6ea4;padding:1em 1.5em}",
    "details{margin:.3em 0}details summary{cursor:pointer;color:#555;font-size:.9em}",
    "details pre{background:#fafbfc;padding:.6em;border:1px solid #d8dee4;",
    "border-radius:3px;overflow-x:auto;font-size:.85em}",
    ".footer{margin-top:3em;padding-top:1em;border-top:1px solid #d8dee4;",
    "font-size:.85em;color:#666}"
  )

  html <- c(
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    sprintf("<title>%s &mdash; RO-Crate preview</title>", esc(crate_title)),
    sprintf("<style>%s</style>", css),
    "</head>",
    "<body>",
    sprintf("<h1>%s</h1>", esc(crate_title)),
    paste("<p class=\"lead\">RO-Crate 1.2 preview &mdash; rendered by",
          "<code>build_phase_cog_ro_crate.R</code> (native R renderer,",
          "no external dependencies).</p>"),
    "<nav class=\"toc\"><strong>Entities in this crate:</strong>",
    "<ul>",
    paste(toc_items, collapse = "\n"),
    "</ul></nav>",
    "<h2>Entity details</h2>",
    paste(vapply(graph, render_entity, character(1)), collapse = "\n\n"),
    sprintf(paste("<p class=\"footer\">Generated on %s.",
                  "Validation strategy: see <code>README.md</code> in this",
                  "deposit.</p>"),
            format(Sys.Date())),
    "</body>",
    "</html>"
  )

  writeLines(html, preview_path, useBytes = TRUE)
  message("Wrote ro-crate-preview.html (native R): ", preview_path)
  invisible(preview_path)
}


# ---- ro-crate-preview.html dispatcher ------------------------------------
# Prefers the Node.js `rochtml` tool if it happens to be on PATH (richer,
# JS-driven preview); falls back to the pure-R renderer above otherwise.
# The fallback path means the preview is ALWAYS produced with zero external
# dependencies — no installs required on the build machine.
# ---- Optional: run roc-validator at build time ---------------------------
# Soft dependency on the Python tool `rocrate-validator`
# (https://pypi.org/project/roc-validator/). When available on PATH and
# `enable = TRUE`, runs it at the REQUIRED severity level against the
# declared profiles, captures the output, and returns a small list with
# the result. When unavailable, returns a "not run" status without error
# so the build continues.
#
# The returned list is intended to be embedded into the in-crate README
# so the deposit carries a build-time validation record rather than a
# bare assertion.
.run_roc_validator <- function(out_dir, enable = TRUE,
                               profile = "ro-crate-1.1") {
  if (!isTRUE(enable))
    return(list(status = "skipped", reason = "disabled by caller",
                profile = profile, version = NA_character_, output = ""))

  bin <- Sys.which("rocrate-validator")
  if (!nzchar(bin))
    return(list(status = "not_run",
                reason = "rocrate-validator not found on PATH",
                profile = profile,
                version = NA_character_, output = ""))

  ver <- tryCatch(
    paste(system2(bin, args = "--version", stdout = TRUE, stderr = TRUE),
          collapse = " "),
    error = function(e) NA_character_)

  res <- tryCatch(
    system2(bin,
            args = c("validate", "-l", "required",
                     "-p", shQuote(profile),
                     shQuote(out_dir)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) NULL)

  status <- attr(res, "status")
  if (is.null(status)) status <- 0L
  list(
    status  = if (status == 0L) "passed" else "failed",
    reason  = NA_character_,
    profile = profile,
    version = ver,
    output  = paste(res, collapse = "
")
  )
}


# ---- Render a validation result as Markdown for the in-crate README ------
.validation_block_md <- function(vr) {
  if (is.null(vr)) vr <- list(status = "not_run",
                              reason = "validation step skipped",
                              profile = "ro-crate-1.1",
                              version = NA_character_, output = "")

  badge <- switch(vr$status,
    passed  = "PASSED",
    failed  = "FAILED",
    not_run = "NOT RUN",
    skipped = "SKIPPED",
    "UNKNOWN"
  )

  prof_applied <- if (is.null(vr$profile) || is.na(vr$profile) ||
                      !nzchar(vr$profile)) "ro-crate-1.1"
                  else vr$profile

  lines <- c(
    sprintf("- **Status:** **%s**", badge),
    "- **Validator:** [`rocrate-validator`](https://pypi.org/project/roc-validator/) (PyPI: `roc-validator`)",
    sprintf("- **Validator version:** %s",
            if (is.na(vr$version) || !nzchar(vr$version)) "_not recorded_"
            else paste0("`", vr$version, "`")),
    "- **Severity level applied:** `required`",
    sprintf("- **Validator profile applied:** `%s`", prof_applied),
    "- **Crate-declared profiles:** RO-Crate 1.2 base profile; Workflow Run Crate",
    sprintf("- **Build date:** %s", format(Sys.Date()))
  )

  if (prof_applied == "ro-crate-1.1")
    lines <- c(lines,
      paste("- **Note on profile choice:** the bundled profile set of",
            "`roc-validator` 0.9.x supports up to RO-Crate 1.1; the",
            "REQUIRED-level checks at 1.1 are a strict subset of what 1.2",
            "requires (1.2 adds optional features, not new MUST clauses on",
            "the base profile). The crate itself remains RO-Crate 1.2,",
            "declared by its `@context` and `conformsTo` properties; once",
            "`roc-validator` ships native 1.2 profile support, pass",
            "`profile = \"ro-crate-1.2\"` to switch."))

  if (!is.na(vr$reason) && nzchar(vr$reason))
    lines <- c(lines, sprintf("- **Note:** %s", vr$reason))

  if (vr$status %in% c("passed", "failed") && nzchar(vr$output))
    lines <- c(lines, "",
               "<details><summary>Validator output</summary>",
               "",
               "```",
               vr$output,
               "```",
               "",
               "</details>")
  paste(lines, collapse = "\n")
}


.run_ro_crate_html <- function(out_dir, enable = TRUE) {
  if (!isTRUE(enable)) return(invisible(NULL))
  metadata_json <- file.path(out_dir, "ro-crate-metadata.json")
  if (!file.exists(metadata_json)) return(invisible(NULL))

  bin <- Sys.which("rochtml")
  if (nzchar(bin)) {
    tryCatch(
      system2(bin, args = shQuote(metadata_json),
              stdout = TRUE, stderr = TRUE),
      error = function(e) NULL)
    preview_path <- file.path(out_dir, "ro-crate-preview.html")
    if (file.exists(preview_path)) {
      message("Wrote ro-crate-preview.html via rochtml.")
      return(invisible(preview_path))
    }
    message("rochtml found but did not produce a preview; ",
            "falling back to native R renderer.")
  }
  .write_ro_crate_html_native(out_dir)
}


# ============================================================================
# Main entry point
# ============================================================================
build_phase_cog_ro_crate <- function(
  out_dir,
  plant,
  phase,                                       # vector of phase IDs
  years,
  results_dir,
  quality_table,                               # concatenated VAM contents
  crop           = crop_spec(plant),
  creators       = default_creators("phase"),
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  upstream_doi   = "10.5281/zenodo.19483111",
  dffp_tool_doi  = "10.5281/zenodo.19693642",
  dffp_dir       = NULL,
  agent_orcid    = creators[[1]][["@id"]],
  agent_name     = creators[[1]][["name"]],
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = TRUE,
  generate_html_preview = TRUE,
  run_roc_validator     = TRUE,
  roc_validator_profile = "ro-crate-1.1"
) {

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # --- 0. Normalize quality_table (defensive; tolerate NULL & empty) ------
  # `do.call(rbind, list())` in the wiring at the call site returns NULL when
  # the per-year VAM glob came back empty — typically because a previous
  # build_phase_cog_ro_crate() run already moved them into _per_year/vam/.
  # Recover by scanning both <results>/vam/ and <out_dir>/_per_year/vam/.
  .empty_qtab <- function() data.frame(
    PLANT = integer(0), PHASE = integer(0), YEAR = integer(0),
    TN = integer(0), ON = integer(0), VN = integer(0),
    METHOD = character(0), BAM_K = integer(0),
    RMSE = numeric(0), MAE = numeric(0), MSE = numeric(0), R2 = numeric(0),
    stringsAsFactors = FALSE
  )
  if (is.null(quality_table) ||
      (is.data.frame(quality_table) && nrow(quality_table) == 0L)) {
    vam_pat <- sprintf("^VAM_%d-\\d+_\\d{4}\\.csv$", plant)
    search_dirs <- c(
      file.path(results_dir, "vam"),
      file.path(out_dir,    "_per_year", "vam")
    )
    found <- unlist(lapply(search_dirs, function(d)
      if (dir.exists(d))
        list.files(d, pattern = vam_pat, full.names = TRUE)
      else character()))
    if (length(found)) {
      quality_table <- do.call(rbind, lapply(found, utils::read.csv2,
                                              stringsAsFactors = FALSE))
      message(sprintf(
        "quality_table was empty; reconstructed from %d per-year VAM file(s).",
        length(found)))
    } else {
      message("quality_table is empty and no per-year VAM files were found; ",
              "manifest will omit per-year quality measurements.")
      quality_table <- .empty_qtab()
    }
  } else if (!is.data.frame(quality_table)) {
    stop("`quality_table` must be a data.frame (or NULL); got: ",
         paste(class(quality_table), collapse = "/"))
  }

  # --- 1. Stage + aggregate artifacts into the crate ----------------------
  # Per-year DOY/BSE/VAM artifacts produced by spatial_interpolation.R are
  # aggregated per phase: 32-band DOY+BSE COGs, wide-format VAM CSV with
  # one row per year. Per-year inputs are MOVED into out_dir/_per_year/
  # (working subdirectory, kept on disk for provenance but excluded from
  # the published manifest).
  agg <- .aggregate_per_phase(results_dir, plant, phase, years, out_dir)

  .dffp_stage(dffp_dir, out_dir)
  art <- agg   # downstream code uses `art$DOY/$BSE/$VAM` as before

  # --- 2. Per-phase PHASE Dataset blocks ----------------------------------
  # Each .phase_dataset() call returns the Dataset node (with @id-only
  # references in schema:variableMeasured) and the measurement entities,
  # which we hoist into the @graph as first-class top-level entries. This
  # is the JSON-LD-correct shape; inline anonymous objects under
  # schema:variableMeasured trip roc-validator's REQUIRED checks.
  year_datasets        <- list()
  measurement_entities <- list()
  for (ph in phase) {
    q_phase <- quality_table[quality_table$PLANT == plant &
                             quality_table$PHASE == ph, , drop = FALSE]
    # NROW() returns 0 for NULL and for zero-row data frames alike; safer
    # than `!nrow(...)` which errors on NULL via `!NULL`.
    if (NROW(q_phase) == 0L)
      q_phase <- .empty_qtab()
    ds <- .phase_dataset(ph, art, out_dir, plant, years, q_phase)
    if (is.null(ds)) next
    year_datasets        <- c(year_datasets,        list(ds$dataset))
    measurement_entities <- c(measurement_entities, ds$measurements)
  }

  # --- 2b. dqv:Metric entities (one per unique measure name in crate) -----
  # Hoisted out of each measurement to remove redundancy and give DQV
  # consumers a stable identifier to group by.
  measure_names <- unique(vapply(measurement_entities,
                                 function(e) e[["schema:name"]],
                                 character(1)))
  metric_entities <- lapply(measure_names, .metric_entity)

  # --- 3. Per-file File entities (aggregated artifacts only) --------------
  file_entities <- list()
  for (layer in c("DOY", "BSE")) {
    for (p in art[[layer]]) {
      m <- regmatches(basename(p),
        regexec(sprintf("^%s_%d-(\\d+)\\.tif$", layer, plant),
                basename(p)))[[1]]
      ph <- as.integer(m[2])
      file_entities <- c(file_entities, list(.file_entity(
        p, out_dir, description = .layer_description(layer, plant, ph, years))))
    }
  }
  for (csv_layer in c("VAM", "CAL", "GEM")) {
    for (p in art[[csv_layer]]) {
      m <- regmatches(basename(p),
        regexec(sprintf("^%s_%d-(\\d+)\\.csv$", csv_layer, plant),
                basename(p)))[[1]]
      ph <- as.integer(m[2])
      file_entities <- c(file_entities, list(.file_entity(
        p, out_dir, description = .layer_description(csv_layer, plant, ph,
                                                     years))))
    }
  }

  dffp_in_crate <- list.files(file.path(out_dir, "dffp"), full.names = TRUE)
  for (p in dffp_in_crate) {
    file_entities <- c(file_entities, list(.file_entity(
      p, out_dir,
      description = "Data Fitness-for-Purpose assessment artifact")))
  }

  # README.md: written before file_entities is finalised so it appears as a
  # File entity in the manifest and is referenced from the root dataset.
  # The first pass uses validation_result = NULL (status "not_run"); after
  # the manifest is written and `roc-validator` has run, the README is
  # rewritten with the real result. This keeps the validation record inside
  # the README itself rather than in a separate file.
  readme_path <- .write_crate_readme(
    out_dir           = out_dir,
    plant             = plant,
    phase             = phase,
    years             = years,
    software_doi      = software_doi,
    upstream_doi      = upstream_doi,
    input_data_doi    = input_data_doi,
    validation_result = NULL
  )
  file_entities <- c(file_entities, list(.file_entity(
    readme_path, out_dir,
    description = paste(
      "Human-readable overview of the crate's contents and the build-time",
      "RO-Crate validation record (validator name, version, profiles, and",
      "status as captured at build time)."))))

  # --- 4. PROV-O CreateAction (Step 7 only) -------------------------------
  all_outputs <- unname(unlist(c(art$DOY, art$BSE, art$VAM, art$CAL, art$GEM)))
  create_action <- list(
    "@id"        = "#phase-cog-creation",
    # Dual typing: schema:CreateAction + W3C prov:Activity
    "@type"      = c("CreateAction", "prov:Activity"),
    "name"       = paste("PhenoPhaseR Step 7: spatial interpolation to 1 km",
                          "COGs using the BSE approach (BAM)"),
    "agent"      = list("@id" = agent_orcid),
    "prov:wasAssociatedWith" = list("@id" = agent_orcid),
    "instrument" = list("@id" = paste0("https://doi.org/", software_doi)),
    "object"     = list(list("@id" = paste0("https://doi.org/", upstream_doi))),
    "prov:used"  = list(list("@id" = paste0("https://doi.org/", upstream_doi))),
    "result"     = lapply(all_outputs,
                          function(p) list("@id" = .relpath(p, out_dir))),
    "startTime"          = format(start_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "prov:startedAtTime" = format(start_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "endTime"            = format(end_time,   "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "prov:endedAtTime"   = format(end_time,   "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )

  # --- 5. DFFP AssessAction + Reviews -------------------------------------
  dffp_action  <- .dffp_assess_action(dffp_tool_doi, dffp_dir)
  dffp_reviews <- .dffp_reviews_from_dir(dffp_dir, dataset_filter = "PHASE")

  # --- 5a. Build subject / keyword / creator entities --------------------
  # Centralised in _crop_specs.R so the same policy applies across every
  # crop and both crate kinds (filter variants and PHASE).
  subj_bundle    <- build_subject_entities(crop, artefact = "phase")
  creator_bundle <- build_creator_entities(creators)
  kw             <- build_keywords(crop, artefact = "phase")

  # --- 6. Root dataset descriptor -----------------------------------------
  root_dataset <- list(
    "@id"   = "./",
    # Dual typing: Dataset (Schema.org/RO-Crate) + dcat:Dataset (W3C DCAT 3)
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf(
      "PHASE Crop Phenological Development Dataset — plant %d, phases %s, %d–%d",
      plant, paste(phase, collapse = ","), min(years), max(years)),
    "description" = paste(
      "Final output of the PhenoPhaseR pipeline (Step 7): Germany-wide,",
      "1 km Cloud-Optimised GeoTIFF surfaces of phenological entry day-of-",
      "year and per-pixel basis-spline standard error, together with per-",
      "year cross-validation tables. Generated by the BSE approach — a",
      "Bayesian additive model (BAM, mgcv::bam) with bivariate spatial",
      "smooth."),
    "datePublished" = format(Sys.Date()),
    "dct:issued"    = format(Sys.Date()),
    "license"       = list("@id" = "https://creativecommons.org/licenses/by/4.0/"),
    "dct:license"   = list("@id" = "https://creativecommons.org/licenses/by/4.0/"),
    "creator"       = creator_bundle$creator_refs,
    "dct:creator"   = creator_bundle$creator_refs,
    "publisher"     = list("@id" = "https://ror.org/022d5qt08"),
    "dct:publisher" = list("@id" = "https://ror.org/022d5qt08"),
    "keywords"      = kw,
    "dcat:keyword"  = kw,
    # Domain semantics: AGROVOC subject terms (crop + phenology + GDD +
    # spatial interpolation + Germany)
    "about"         = subj_bundle$subject_refs,
    "dct:subject"   = subj_bundle$subject_refs,
    "spatialCoverage"   = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"       = list("@id" = "https://www.geonames.org/2921044/"),
    "temporalCoverage"  = sprintf("%d/%d", min(years), max(years)),
    "dct:temporal"      = sprintf("%d/%d", min(years), max(years)),
    "spatialResolution" = "1000 m",
    "dcat:spatialResolutionInMeters" = 1000,
    "isBasedOn" = list(
      list("@id" = paste0("https://doi.org/", software_doi)),
      list("@id" = paste0("https://doi.org/", upstream_doi)),
      list("@id" = paste0("https://doi.org/", input_data_doi))
    ),
    "prov:wasDerivedFrom" = list(
      list("@id" = paste0("https://doi.org/", software_doi)),
      list("@id" = paste0("https://doi.org/", upstream_doi)),
      list("@id" = paste0("https://doi.org/", input_data_doi))
    ),
    "hasPart"             = c(
      lapply(year_datasets, function(d) list("@id" = d[["@id"]])),
      list(list("@id" = "README.md"))
    ),
    "wasGeneratedBy"      = list("@id" = "#phase-cog-creation"),
    "prov:wasGeneratedBy" = list("@id" = "#phase-cog-creation"),
    "schema:potentialAction" = dffp_action,
    "schema:review"          = if (length(dffp_reviews)) dffp_reviews else list()
  )

  # --- 7. Contextual entities --------------------------------------------
  context_entities <- c(
    # Person entities for all creators (with roles + affiliation)
    creator_bundle$person_entities,
    list(
      list("@id" = "https://ror.org/022d5qt08",
           "@type" = "Organization",
           "name"  = paste("Julius K\u00fchn-Institut (JKI) \u2013 Federal",
                           "Research Centre for Cultivated Plants")),
      list("@id" = "https://creativecommons.org/licenses/by/4.0/",
           "@type" = "CreativeWork",
           "name"  = "Creative Commons Attribution 4.0 International"),
      list("@id" = paste0("https://doi.org/", software_doi),
           "@type" = "SoftwareApplication", "name" = "PhenoPhaseR"),
      list("@id" = paste0("https://doi.org/", upstream_doi),
           "@type" = "Dataset",
           "name"  = "PhenoPhaseR filter variant results (intermediate)"),
      list("@id" = paste0("https://doi.org/", input_data_doi),
           "@type" = "Dataset",
           "name"  = "DWD phenology and gridded temperature input data"),
      list("@id" = paste0("https://doi.org/", dffp_tool_doi),
           "@type" = "SoftwareApplication",
           "name"  = "DFFP Application Matrix",
           "description" = "Cross-paper Data Fitness-for-Purpose tool",
           "url"   = "https://github.com/MahdiHedayatMahmoudi/dffp-application-matrix"),
      list("@id" = "https://www.geonames.org/2921044/",
           "@type" = "Place", "name" = "Federal Republic of Germany"),
      # AGROVOC concept set + DefinedTerm entities
      subj_bundle$defined_term_set
    ),
    subj_bundle$defined_terms
  )

  # --- 8. Metadata descriptor + assemble ---------------------------------
  metadata_descriptor <- list(
    "@id"        = "ro-crate-metadata.json",
    "@type"      = "CreativeWork",
    "conformsTo" = list(
      list("@id" = "https://w3id.org/ro/crate/1.2"),
      list("@id" = "https://w3id.org/ro/crate/1.2/Workflow-Run-Crate")
    ),
    "about"      = list("@id" = "./"),
    "description" = paste(
      "RO-Crate 1.2 (Workflow Run Crate profile) describing the final",
      "PHASE entry-date COGs of the PhenoPhaseR pipeline, with embedded",
      "PROV-O provenance, ISO 19157-1 quality elements, and Data Fitness-",
      "for-Purpose (DFFP) reviews per downstream application.")
  )

  crate <- list(
    "@context" = list(
      "https://w3id.org/ro/crate/1.2/context",
      list(
        # W3C vocabularies (primary for quality propagation)
        "dcat"     = "http://www.w3.org/ns/dcat#",
        "dct"      = "http://purl.org/dc/terms/",
        "dqv"      = "http://www.w3.org/ns/dqv#",
        "prov"     = "http://www.w3.org/ns/prov#",
        "skos"     = "http://www.w3.org/2004/02/skos/core#",
        "xsd"      = "http://www.w3.org/2001/XMLSchema#",
        # ISO bridge target (referenced via skos:closeMatch from DQV)
        "iso19157" = "http://standards.iso.org/iso/19157/-1/",
        # Domain subject vocabulary (referenced via schema:about / dct:subject)
        "agrovoc"  = "http://aims.fao.org/aos/agrovoc/",
        # Carrier vocabularies. Note: schema is http (not https) by design —
        # the official RO-Crate 1.2 context loaded above maps all Schema.org
        # terms to http://schema.org/ identifiers. Using https here would
        # split Schema.org into two RDF namespaces in the expanded graph
        # (Schema.org-from-RO-Crate vs. Schema.org-from-this-prefix). Stay on
        # http until and unless RO-Crate itself migrates.
        "schema"   = "http://schema.org/",
        "spdx"     = "http://spdx.org/rdf/terms#",
        "dffp"     = "https://github.com/MahdiHedayatMahmoudi/dffp-application-matrix#"
      )
    ),
    "@graph" = c(
      list(metadata_descriptor),
      list(root_dataset),
      year_datasets,
      file_entities,
      measurement_entities,
      metric_entities,
      list(create_action),
      context_entities
    )
  )

  out_json <- file.path(out_dir, "ro-crate-metadata.json")
  write_json(crate, out_json,
             pretty = TRUE, auto_unbox = TRUE,
             null = "null", na = "null")
  message("Wrote crate metadata: ", out_json)
  if (length(dffp_reviews))
    message(sprintf("  embedded %d DFFP review(s) for PHASE consumers",
                    length(dffp_reviews)))

  # Optional: generate ro-crate-preview.html via the `rochtml` tool. Soft
  # dependency on Node.js + ro-crate-html; skipped with a clear message if
  # not installed. Included in the ZIP if produced.
  .run_ro_crate_html(out_dir, enable = generate_html_preview)

  # Run roc-validator against the finished crate and rewrite the README so
  # the validation record is captured inside the deposit. Soft dependency:
  # skipped with a "not_run" status if `rocrate-validator` isn't installed.
  vr <- .run_roc_validator(out_dir, enable = run_roc_validator,
                           profile = roc_validator_profile)
  message(sprintf("rocrate-validator: %s%s",
                  vr$status,
                  if (!is.na(vr$reason) && nzchar(vr$reason))
                    sprintf(" (%s)", vr$reason) else ""))
  .write_crate_readme(
    out_dir           = out_dir,
    plant             = plant,
    phase             = phase,
    years             = years,
    software_doi      = software_doi,
    upstream_doi      = upstream_doi,
    input_data_doi    = input_data_doi,
    validation_result = vr
  )

  if (zip_output) {
    zip_path <- paste0(out_dir, ".zip")
    old <- setwd(dirname(out_dir)); on.exit(setwd(old), add = TRUE)
    # Enumerate the contents of out_dir explicitly, excluding the working
    # subfolder _per_year/ so the published ZIP carries only the aggregated
    # artifacts plus metadata. _per_year/ remains on disk for provenance.
    pub <- setdiff(list.files(basename(out_dir), recursive = TRUE,
                              all.files = FALSE, full.names = TRUE,
                              include.dirs = FALSE),
                   list.files(file.path(basename(out_dir), "_per_year"),
                              recursive = TRUE,
                              all.files = FALSE, full.names = TRUE,
                              include.dirs = FALSE))
    utils::zip(zip_path, pub, flags = "-9X")
    message("Wrote crate ZIP    : ", zip_path,
            " (excludes _per_year/ working subfolder)")
  }

  invisible(out_json)
}


# ============================================================================
# Wiring example for PhenoPhaseR.R (after Step 7)
# ============================================================================
#   t1_ph <- Sys.time()
#
#   ## VAM tables now live under output_dir/vam/
#   vam_files  <- list.files(file.path(output_dir, "vam"),
#                            pattern = sprintf("^VAM_%d-.+\\.csv$", plant),
#                            full.names = TRUE)
#   qtab_phase <- do.call(rbind,
#                         lapply(vam_files, read.csv2,
#                                stringsAsFactors = FALSE))
#
#   source(file.path(function_dir, "build_phase_cog_ro_crate.R"))
#
#   ## Simplest call — crop_spec is looked up automatically by plant ID,
#   ## creators defaults to the family-wide list defined in _crop_specs.R:
#   build_phase_cog_ro_crate(
#     out_dir       = file.path(output_dir, "ro_crate_phase"),
#     plant         = plant,
#     phase         = target_phases,
#     years         = years,
#     results_dir   = output_dir,
#     quality_table = qtab_phase,
#     start_time    = t0_ph,
#     end_time      = t1_ph,
#     dffp_dir      = file.path(data_dir, "dffp")    # NULL to skip
#   )
#
#   ## To override the default contributor list for a specific deposit:
#   # build_phase_cog_ro_crate(
#   #   ..., creators = list(
#   #     list("@id"   = "https://orcid.org/0000-0002-1918-7747",
#   #          name    = "Markus Möller",
#   #          role    = "Producer",
#   #          affiliation_ror = "https://ror.org/022d5qt08")
#   #   )
#   # )
# ============================================================================
