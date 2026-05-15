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
# Artifact set (produced by the patched spatial_interpolation.R with
# subfolders = TRUE):
#   <results>/cogs/DOY_<plant>-<phase>_<year>.tif
#   <results>/cogs/BSE_<plant>-<phase>_<year>.tif
#   <results>/vam/VAM_<plant>-<phase>_<year>.csv
#
# Quality table column expectations (from concatenated VAM files):
#   PLANT, PHASE, YEAR, TN, ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2,
#   MEAN_BSE
# These columns are mapped to ISO 19157-1 thematic-accuracy quality elements:
#   cv_rmse       ← RMSE
#   cv_mae        ← MAE
#   cv_r2         ← R2
#   training_n    ← TN
#   validation_n  ← VN
#   bam_k         ← BAM_K
#   mean_bse      ← MEAN_BSE
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
                             definition = NULL) {
  # Dual typing: schema:PropertyValue keeps Schema.org consumers happy;
  # dqv:QualityMeasurement makes the node first-class for W3C DQV pipelines.
  el <- list(
    "@type"             = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = paste0("iso19157:", measure),
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list(
      "@type"           = "dqv:Metric",
      "skos:prefLabel"  = measure,
      "skos:closeMatch" = list("@id" = paste0("iso19157:", measure)),
      "dqv:inDimension" = list("@id" = paste0("iso19157:",
                                              .iso19157_dimension(measure)))
    )
  )
  if (!is.null(unit_text))  el[["schema:unitText"]]    <- unit_text
  if (!is.null(definition)) el[["schema:description"]] <- definition
  el
}


# ---- Discover BSE-method COG artifacts under the subfolder layout --------
.discover_cog_artifacts <- function(results_dir, plant, phases, years) {
  cogs_dir <- file.path(results_dir, "cogs")
  vam_dir  <- file.path(results_dir, "vam")
  phase_alt <- paste(phases, collapse = "|")
  year_alt  <- paste(years,  collapse = "|")
  layer_pat <- function(layer)
    sprintf("^%s_%d-(%s)_(%s)\\.tif$", layer, plant, phase_alt, year_alt)
  list(
    DOY = list.files(cogs_dir, pattern = layer_pat("DOY"), full.names = TRUE),
    BSE = list.files(cogs_dir, pattern = layer_pat("BSE"), full.names = TRUE),
    VAM = list.files(vam_dir,  pattern = sprintf(
      "^VAM_%d-(%s)_(%s)\\.csv$", plant, phase_alt, year_alt),
      full.names = TRUE)
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

  agg <- list(DOY = character(), BSE = character(), VAM = character())

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
                        "ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2,",
                        "MEAN_BSE."),
                  plant, phase, yr_min, yr_max, n_yr)
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
  parts <- c(doy_path, bse_path, vam_path)
  if (!length(parts)) return(NULL)

  # ---- Per-year scalar quality measurements (Option B) -------------------
  # For every (year, measure) in q_phase, emit one quality element node
  # carrying the scalar value and a dct:temporal year tag. Years missing
  # from q_phase silently produce no measurement nodes (rather than NA),
  # mirroring how missing years are handled in the underlying GeoTIFF
  # bands by virtue of being absent from the input set.
  qe <- list()
  if (nrow(q_phase)) {
    for (i in seq_len(nrow(q_phase))) {
      r  <- q_phase[i, ]
      yr <- as.character(r$YEAR)
      add_qe <- function(measure, value, unit_text, definition) {
        if (is.null(value) || is.na(value)) return(NULL)
        e <- .quality_element(measure, value, unit_text, definition)
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

  list(
    "@id"   = sprintf("phase_%d-%d/", plant, phase),
    # Dual typing: Dataset (Schema.org/RO-Crate) + dcat:Dataset (W3C DCAT 3)
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf("PHASE entry-date prediction (plant %d, phase %d, %d–%d)",
                       plant, phase, min(years), max(years)),
    "description" = paste0(
      "Per-phase aggregated outputs for plant ", plant, ", phase ", phase,
      ", years ", min(years), "–", max(years), ". Comprises a ",
      length(years), "-band DOY posterior-mean COG, a matching ",
      length(years), "-band BSE per-pixel uncertainty COG, and a wide-",
      "format VAM CSV with one row per year. Bands are named by year; ",
      "subset semantically with terra::rast(file, lyrs=as.character(year)) ",
      "or gdal_translate -b N. Produced by spatial_interpolation.R using ",
      "the BSE approach (BAM) and aggregated by build_phase_cog_ro_crate.R."),
    "encodingFormat" = "image/tiff;application=geotiff;profile=cloud-optimized",
    "hasPart"        = lapply(parts, function(p) list("@id" = .relpath(p, crate_root))),
    # Quality info: Schema.org variableMeasured + W3C DQV hasQualityMeasurement
    # both reference the same node array (dual-typed in .quality_element).
    "schema:variableMeasured"   = qe,
    "dqv:hasQualityMeasurement" = qe,
    "schema:temporalCoverage"  = sprintf("%d/%d", min(years), max(years)),
    "dct:temporal"             = sprintf("%d/%d", min(years), max(years)),
    "schema:spatialCoverage"   = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"              = list("@id" = "https://www.geonames.org/2921044/"),
    "schema:spatialResolution" = "1000 m",
    "dcat:spatialResolutionInMeters" = 1000
  )
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
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  upstream_doi   = "10.5281/zenodo.19483111",
  dffp_tool_doi  = "10.5281/zenodo.19693642",
  dffp_dir       = NULL,
  agent_orcid    = "https://orcid.org/0000-0002-1918-7747",
  agent_name     = "Markus Möller",
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = TRUE
) {

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

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
  year_datasets <- list()
  for (ph in phase) {
    q_phase <- quality_table[quality_table$PLANT == plant &
                             quality_table$PHASE == ph, ]
    if (!nrow(q_phase))
      q_phase <- data.frame(YEAR = integer(0), TN = integer(0),
                            ON = integer(0), VN = integer(0),
                            RMSE = numeric(0), MAE = numeric(0),
                            R2 = numeric(0), BAM_K = integer(0),
                            MEAN_BSE = numeric(0))
    ds <- .phase_dataset(ph, art, out_dir, plant, years, q_phase)
    if (!is.null(ds)) year_datasets[[length(year_datasets) + 1]] <- ds
  }

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
  for (p in art$VAM) {
    m <- regmatches(basename(p),
      regexec(sprintf("^VAM_%d-(\\d+)\\.csv$", plant),
              basename(p)))[[1]]
    ph <- as.integer(m[2])
    file_entities <- c(file_entities, list(.file_entity(
      p, out_dir, description = .layer_description("VAM", plant, ph, years))))
  }

  dffp_in_crate <- list.files(file.path(out_dir, "dffp"), full.names = TRUE)
  for (p in dffp_in_crate) {
    file_entities <- c(file_entities, list(.file_entity(
      p, out_dir,
      description = "Data Fitness-for-Purpose assessment artifact")))
  }

  # --- 4. PROV-O CreateAction (Step 7 only) -------------------------------
  all_outputs <- unname(unlist(c(art$DOY, art$BSE, art$VAM)))
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
    "creator"       = list(list("@id" = agent_orcid)),
    "dct:creator"   = list(list("@id" = agent_orcid)),
    "publisher"     = list("@id" = "https://ror.org/02jx3x895"),
    "dct:publisher" = list("@id" = "https://ror.org/02jx3x895"),
    "keywords"      = c("phenology", "winter wheat", "BAM", "BSE",
                        "Bayesian additive model", "DWD",
                        "Cloud Optimized GeoTIFF", "Germany", "FAIR",
                        "RO-Crate", "ISO 19157-1", "DFFP", "DQV", "PHASE"),
    "dcat:keyword"  = c("phenology", "winter wheat", "BAM", "BSE",
                        "Bayesian additive model", "DWD",
                        "Cloud Optimized GeoTIFF", "Germany", "FAIR",
                        "RO-Crate", "ISO 19157-1", "DFFP", "DQV", "PHASE"),
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
    "hasPart"             = lapply(year_datasets, function(d) list("@id" = d[["@id"]])),
    "wasGeneratedBy"      = list("@id" = "#phase-cog-creation"),
    "prov:wasGeneratedBy" = list("@id" = "#phase-cog-creation"),
    "schema:potentialAction" = dffp_action,
    "schema:review"          = if (length(dffp_reviews)) dffp_reviews else list()
  )

  # --- 7. Contextual entities --------------------------------------------
  context_entities <- list(
    list("@id" = agent_orcid, "@type" = "Person", "name" = agent_name,
         "affiliation" = list("@id" = "https://ror.org/02jx3x895")),
    list("@id" = "https://ror.org/02jx3x895",
         "@type" = "Organization", "name" = "Julius Kühn-Institut (JKI)"),
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
         "@type" = "Place", "name" = "Federal Republic of Germany")
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
        # Carrier vocabularies (kept for entities without W3C equivalents)
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
# ============================================================================
