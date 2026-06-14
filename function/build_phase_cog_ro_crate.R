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

# Shared crop specs, default creators, and layered keyword builder.
# Source from the same directory as this script.
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

# ---- Gap handling ---------------------------------------------------------
# `gap_spec` lets the caller declare WHY a (phase, year) raster is absent, so
# the NA-padded band can be documented with a machine-readable reason rather
# than an undifferentiated NA. Accepted forms:
#
#   NULL                         -> every gap is reason "insufficient_samples"
#                                   (the default interpolation-failure case)
#
#   a data.frame with columns    -> per-(phase, year) reasons. `phase` may be
#     phase, year, reason           NA to mean "any phase"; `year` may be NA to
#                                   mean "any year". More specific rows win.
#
#   a single string              -> that reason applies to every gap
#                                   (e.g. "not_reported")
#
# Recommended reason codes (free text is allowed, but these map cleanly to
# the DQV completeness measurements emitted later):
#   "not_reported"          - DWD did not observe/report this crop-phase that
#                             year (a true absence, not a processing failure)
#   "insufficient_samples"  - reported, but too few stations passed filtering
#                             to interpolate a stable surface
.normalise_gap_spec <- function(gap_spec) {
  if (is.null(gap_spec)) return(NULL)
  if (is.character(gap_spec) && length(gap_spec) == 1L) {
    return(data.frame(phase = NA_integer_, year = NA_integer_,
                      reason = gap_spec, stringsAsFactors = FALSE))
  }
  if (is.data.frame(gap_spec)) {
    stopifnot(all(c("reason") %in% names(gap_spec)))
    if (!"phase" %in% names(gap_spec)) gap_spec$phase <- NA_integer_
    if (!"year"  %in% names(gap_spec)) gap_spec$year  <- NA_integer_
    return(gap_spec[c("phase", "year", "reason")])
  }
  stop("gap_spec must be NULL, a single string, or a data.frame with a ",
       "`reason` column (optionally `phase` and `year`).")
}

# Resolve the reason for one (phase, year). Most specific match wins:
# exact (phase,year) > phase-only > year-only > wildcard > default.
.gap_reason <- function(gap_spec, phase, year,
                        default = "insufficient_samples") {
  gs <- .normalise_gap_spec(gap_spec)
  if (is.null(gs)) return(default)
  score <- function(r) {
    pm <- is.na(r$phase) || r$phase == phase
    ym <- is.na(r$year)  || r$year  == year
    if (!pm || !ym) return(-1L)
    (!is.na(r$phase)) * 2L + (!is.na(r$year)) * 1L
  }
  best <- -1L; best_reason <- default
  for (i in seq_len(nrow(gs))) {
    s <- score(gs[i, ])
    if (s > best) { best <- s; best_reason <- gs$reason[i] }
  }
  best_reason
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
    # Prediction-interval calibration of the BSE layer. PICP/MPIW are
    # validated *usability* statements about the uncertainty raster, owned
    # locally and anchored only to the real ISO usability dimension class.
    picp                 = "DQ_UsabilityElement",
    mpiw                 = "DQ_UsabilityElement",
    # When called with a dimension-class name directly (e.g. the completeness
    # metric is keyed by its class), map it to itself so the Metric's
    # dqv:inDimension resolves to the correct real ISO class rather than the
    # thematic-accuracy default.
    DQ_ThematicAccuracy    = "DQ_ThematicAccuracy",
    DQ_CompletenessOmission = "DQ_CompletenessOmission",
    DQ_LogicalConsistency  = "DQ_LogicalConsistency",
    DQ_UsabilityElement    = "DQ_UsabilityElement",
    "DQ_ThematicAccuracy"
  )
}

.quality_element <- function(measure, value, unit_text = NULL,
                             definition = NULL, qm_id = NULL,
                             computed_on = NULL) {
  # Each measurement is a first-class top-level entity in the @graph: dual-
  # typed schema:PropertyValue + dqv:QualityMeasurement, with its own @id and
  # a reference (not an inline object) to the dqv:Metric entity that defines
  # what it measures. This shape is what JSON-LD / RO-Crate validators expect
  # for object references — inline anonymous objects under
  # schema:variableMeasured trip the rule "node references MUST have only
  # @id, no other properties" (roc-validator, REQUIRED).
  #
  # HONEST ANCHORING (v1.7.0): schema:propertyID carries the bare measure
  # token (e.g. "cv_rmse", "picp"), NOT "iso19157:cv_rmse". There is no
  # cv_rmse / picp / mpiw concept in ISO 19157 — those would be fabricated
  # IRIs that resolve to nothing. The measure is *owned* locally; its link to
  # the standard is made only at the genuine dimension-CLASS level, via the
  # dqv:Metric entity's dqv:inDimension (see .metric_entity). This mirrors
  # the project's general principle: an IRI in the metadata must resolve to
  # what it claims, or it is not minted.
  el <- list(
    "@id"               = qm_id,
    "@type"             = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = measure,
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list("@id" = paste0("#metric-", measure))
  )
  if (!is.null(unit_text))   el[["schema:unitText"]]    <- unit_text
  if (!is.null(definition))  el[["schema:description"]] <- definition
  # dqv:computedOn ties a measurement to the specific file it was derived
  # from. Used for measures that describe one artefact (e.g. PICP/MPIW are
  # computed from the BSE uncertainty COG), not the prediction as a whole.
  if (!is.null(computed_on)) el[["dqv:computedOn"]] <- list("@id" = computed_on)
  el
}


# ---- Top-level dqv:Metric entity (one per unique measure name in crate) ---
# The Metric describes the *kind* of thing being measured (e.g. RMSE in days,
# mapped to ISO 19157 DQ_ThematicAccuracy). Many measurements reference the
# same Metric via dqv:isMeasurementOf, so it lives at top level rather than
# being inlined redundantly per measurement.
.metric_entity <- function(measure) {
  # The Metric describes the *kind* of thing being measured and links it to a
  # genuine ISO 19157 quality DIMENSION CLASS via dqv:inDimension. It does NOT
  # assert a skos:closeMatch to a fabricated iso19157:<measure> IRI — there is
  # no such concept in ISO 19157 for cv_rmse / picp / mpiw etc., so minting
  # one would be a non-resolving claim. The only ISO IRIs referenced are the
  # real dimension classes (DQ_ThematicAccuracy, DQ_UsabilityElement, ...),
  # which do exist in the standard.
  dim_class <- .iso19157_dimension(measure)
  ent <- list(
    "@id"             = paste0("#metric-", measure),
    "@type"           = "dqv:Metric",
    "skos:prefLabel"  = measure,
    "dqv:inDimension" = list("@id" = paste0("iso19157:", dim_class))
  )
  # When the "measure" passed in is itself a dimension class (e.g. the
  # completeness metric keyed by DQ_CompletenessOmission), inDimension points
  # at that same real class — which is correct and resolves.
  ent
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
    GEM = list.files(vam_dir,  pattern = csv_pat("GEM"),   full.names = TRUE),
    PIC = list.files(vam_dir,  pattern = csv_pat("PIC"),   full.names = TRUE)
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
.aggregate_per_phase <- function(results_dir, plant, phases, years, out_dir,
                                 gap_spec = NULL) {
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
              CAL = character(), GEM = character(), PIC = character())

  # Accumulates one record per NA-padded (layer, phase, year) so the gaps
  # can be surfaced in the RO-Crate metadata after the COGs are written.
  gap_log <- list()

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

      present_stk <- terra::rast(hits)
      names(present_stk) <- as.character(yrs)

      # --- Build the full `years` axis, NA-padding absent years ------------
      # A (phase, year) can be missing in two ways:
      #   (a) no tile on disk at all — the year is absent from `yrs`;
      #   (b) a tile exists but is entirely NA — spatial_interpolation()
      #       wrote an NA surface because the selector dropped that year
      #       (too few samples) or the fit failed.
      # Both must end up as documented gaps. We first assemble a complete
      # 32-band stack (inserting NA bands for case (a)), then scan every
      # band for all-NA content to catch case (b) as well.
      missing_years <- setdiff(years, yrs)
      if (length(missing_years)) {
        templ   <- present_stk[[1]]
        na_band <- terra::setValues(templ, NA)
        full <- vector("list", length(years))
        for (k in seq_along(years)) {
          y <- years[k]
          if (y %in% yrs) {
            full[[k]] <- present_stk[[as.character(y)]]
          } else {
            b <- na_band; names(b) <- as.character(y); full[[k]] <- b
          }
        }
        stk <- terra::rast(full)
      } else {
        stk <- present_stk
      }
      names(stk) <- as.character(years)
      terra::time(stk) <- as.Date(paste0(years, "-01-01"))

      # Identify ALL gap years: those whose band is entirely NA (covers both
      # absent-tile padding and present-but-NA tiles). global(isNA) == ncell
      # means every cell in that band is NA.
      ncell_band <- terra::ncell(stk)
      na_counts  <- terra::global(stk, fun = "isNA")[, 1]
      gap_years  <- years[na_counts == ncell_band]

      for (y in gap_years) {
        reason <- .gap_reason(gap_spec, ph, y)
        gap_log[[length(gap_log) + 1L]] <- list(
          layer = layer, phase = ph, year = y, reason = reason)
      }
      if (length(gap_years))
        message(sprintf(
          "  %s phase %d: %d gap year(s) (NA): %s",
          layer, ph, length(gap_years),
          paste(gap_years, collapse = ", ")))

      # Per-band descriptions: data bands carry the year; gap bands carry
      # the year plus the reason, visible in `gdalinfo`.
      band_desc <- vapply(years, function(y) {
        if (y %in% gap_years)
          sprintf("%d (no data: %s)", y, .gap_reason(gap_spec, ph, y))
        else
          as.character(y)
      }, character(1))

      out_path <- file.path(cogs_out,
                            sprintf("%s_%d-%d.tif", layer, plant, ph))
      terra::writeRaster(
        stk, filename = out_path, overwrite = TRUE,
        filetype = "COG", gdal = cog_opts
      )
      # Re-open to set band descriptions, then re-save (terra preserves them
      # in GDAL_METADATA on COG rewrite).
      try({
        ds <- terra::rast(out_path)
        terra::set.names(ds, band_desc, index = seq_along(band_desc))
      }, silent = TRUE)

      message(sprintf("Aggregated %s phase %d → %s (%d bands, %d data + %d NA)",
                      layer, ph, basename(out_path), terra::nlyr(stk),
                      length(years) - length(gap_years), length(gap_years)))

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

  # PIC: concatenate per-year rows into one wide-format CSV per phase.
  # PIC CSVs (prediction-interval calibration of the BSE layer) already carry
  # their own YEAR column, same shape as CAL. Optional: only present when
  # spatial_interpolation.R was run with method="bam", validation=TRUE and
  # uncertainty=TRUE. Absent PIC files simply produce no aggregated PIC.
  for (ph in phases) {
    pat <- sprintf("^PIC_%d-%d_(\\d{4})\\.csv$", plant, ph)
    hits <- src$PIC[grepl(pat, basename(src$PIC))]
    if (!length(hits)) next
    yr_in_file <- as.integer(sub(pat, "\\1", basename(hits)))
    ord  <- order(match(yr_in_file, years))
    hits <- hits[ord]

    rows <- do.call(rbind, lapply(hits, utils::read.csv2,
                                  stringsAsFactors = FALSE))
    rows <- rows[order(rows$YEAR), ]

    out_path <- file.path(vam_out, sprintf("PIC_%d-%d.csv", plant, ph))
    utils::write.csv2(rows, file = out_path, row.names = FALSE)
    message(sprintf("Aggregated PIC phase %d → %s (%d rows)",
                    ph, basename(out_path), nrow(rows)))

    file.rename(hits, file.path(per_year_dir, "vam", basename(hits)))
    agg$PIC <- c(agg$PIC, out_path)
  }

  attr(agg, "gap_log") <- gap_log
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
  pic_path <- art$PIC[grepl(sprintf("^PIC_%d-%d\\.csv$", plant, phase),
                            basename(art$PIC))]
  parts <- c(doy_path, bse_path, vam_path, cal_path, gem_path, pic_path)
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

  # ---- BSE prediction-interval calibration measurements (PICP / MPIW) ----
  # These come from the per-phase PIC CSV (not VAM) and describe the BSE
  # uncertainty COG specifically, so each is tied to that file via
  # dqv:computedOn. They are validated *usability* statements: PICP is the
  # empirical coverage of held-out stations by the nominal-90% prediction
  # interval (BSE combined with the BAM residual variance), MPIW its mean
  # width. Absent or NA values (e.g. non-BAM methods) emit nothing.
  if (length(pic_path) && file.exists(pic_path) && length(bse_path)) {
    pic_tab <- tryCatch(utils::read.csv2(pic_path, stringsAsFactors = FALSE),
                        error = function(e) NULL)
    bse_rel <- .relpath(bse_path, crate_root)
    if (!is.null(pic_tab) && nrow(pic_tab)) {
      for (i in seq_len(nrow(pic_tab))) {
        r  <- pic_tab[i, ]
        yr <- as.character(r$YEAR)
        add_pic <- function(measure, value, unit_text, definition) {
          if (is.null(value) || is.na(value) ||
              (is.character(value) && !nzchar(value))) return(invisible(NULL))
          value <- suppressWarnings(as.numeric(value))
          if (is.na(value)) return(invisible(NULL))
          qm_id <- sprintf("#qm-%d-%d-%s-%s", plant, phase, yr, measure)
          e <- .quality_element(measure, value, unit_text, definition,
                                qm_id = qm_id, computed_on = bse_rel)
          e[["schema:temporalCoverage"]] <- yr
          e[["dct:temporal"]]            <- yr
          qe[[length(qe) + 1]] <<- e
        }
        nominal <- suppressWarnings(as.numeric(r$NOMINAL))
        nominal_pct <- if (length(nominal) && !is.na(nominal))
          round(100 * nominal) else 90
        add_pic("picp", r$PICP, NULL,
                sprintf(paste0("Prediction-interval coverage probability at ",
                               "nominal %d%%, from k-fold cross-validation: ",
                               "pooled fraction of out-of-fold stations whose ",
                               "observed DOY falls within pred +/- ",
                               "z*sqrt(se_fit^2 + residual_variance), where ",
                               "se_fit is the per-fold BAM posterior SE and ",
                               "residual_variance is from the production ",
                               "all-data fit. Each station is held out exactly ",
                               "once; the published DOY/BSE rasters use all ",
                               "stations and are not affected. Validated ",
                               "predictive-uncertainty measure (assumes ",
                               "Gaussian homoscedastic residuals; single ",
                               "global residual variance)."),
                        nominal_pct))
        add_pic("mpiw", r$MPIW, "days",
                sprintf(paste0("Mean prediction-interval width at nominal ",
                               "%d%% coverage from the same k-fold ",
                               "cross-validation, combining the per-fold BAM ",
                               "posterior standard error with the production ",
                               "residual variance."),
                        nominal_pct))
      }
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
# anyone browsing the Zenodo deposit (or unpacking the optional bulk ZIP)
# finds it without leaving the deposit. Kept terse: complements the Zenodo
# description rather than duplicating it.
.write_crate_readme <- function(out_dir, plant, phase, years,
                                software_doi, upstream_doi, input_data_doi,
                                validation_result = NULL,
                                gap_log = list()) {
  readme_path <- file.path(out_dir, "README.md")
  ph_str <- paste(phase, collapse = ", ")
  yr_str <- sprintf("%d–%d", min(years), max(years))

  # ----- Render the "What this deposit reports" subsection of the gap-handling
  # section. If gap_log is empty, state that no gaps were detected and give a
  # verification snippet that should return zero. If gap_log has entries,
  # render a compact per-(layer, phase) summary of which years became NA bands
  # and why, mirroring what the manifest emits as DQ_CompletenessOmission
  # measurements. The mechanism description above this subsection is the same
  # in either case so the README remains educational independent of whether
  # the chain happened to fire for this build.
  first_phase <- phase[1]
  if (length(gap_log) == 0L) {
    gap_status_lines <- c(
      "#### What this deposit reports",
      "",
      sprintf(paste0(
        "For this specific deposit (plant %d, phases %s, %s), **no temporal ",
        "gaps were detected**: every (phase, year) had enough surviving ",
        "stations to produce a stable interpolated surface. The manifest ",
        "therefore contains no `DQ_CompletenessOmission` measurements, and ",
        "every band in every COG carries real interpolated data rather than ",
        "NA. The mechanism described above is present in the codebase and ",
        "will fire for crops or year ranges where coverage is thinner."),
        plant, ph_str, yr_str),
      "",
      "You can verify the absence of NA bands programmatically:",
      "",
      "```r",
      "library(terra)",
      sprintf("r <- terra::rast(\"cogs/DOY_%d-%d.tif\")", plant, first_phase),
      "# Year-bands that are entirely NA (should be empty for this deposit)",
      "na_years <- names(r)[terra::global(r, fun = \"notNA\")[, 1] == 0]",
      "length(na_years)   # 0",
      "```",
      ""
    )
  } else {
    # Group gap_log entries by (layer, phase) for a compact summary
    keyf <- vapply(gap_log,
                   function(g) sprintf("%s phase %d", g$layer, g$phase),
                   character(1))
    summary_lines <- character()
    for (k in sort(unique(keyf))) {
      recs <- gap_log[keyf == k]
      gy <- sort(vapply(recs, function(r) r$year, integer(1)))
      rs <- unique(vapply(recs, function(r) r$reason, character(1)))
      summary_lines <- c(
        summary_lines,
        sprintf("- **%s**: %d NA band(s) at year(s) %s. Reason(s): %s.",
                k, length(gy), paste(gy, collapse = ", "),
                paste(rs, collapse = "; "))
      )
    }
    gap_status_lines <- c(
      "#### What this deposit reports",
      "",
      sprintf(paste0(
        "For this specific deposit (plant %d, phases %s, %s), the ",
        "gap-handling chain emitted NA bands for the following ",
        "(COG, phase, year) combinations. Each row corresponds to a ",
        "`DQ_CompletenessOmission` `dqv:QualityMeasurement` node in ",
        "`ro-crate-metadata.json`:"),
        plant, ph_str, yr_str),
      "",
      summary_lines,
      "",
      "You can confirm which year-bands are NA programmatically:",
      "",
      "```r",
      "library(terra)",
      sprintf("r <- terra::rast(\"cogs/DOY_%d-%d.tif\")", plant, first_phase),
      "# Year-bands that are entirely NA",
      "na_years <- names(r)[terra::global(r, fun = \"notNA\")[, 1] == 0]",
      "na_years",
      "```",
      ""
    )
  }

  txt <- c(
    sprintf("# PHASE — plant %d, phases %s, %s", plant, ph_str, yr_str),
    "",
    sprintf(paste(
      "Germany-wide, 1 km Cloud-Optimised GeoTIFF surfaces of phenological",
      "entry day-of-year (DOY) and per-pixel basis-spline standard error",
      "(BSE) for plant %d (DWD/JKI code), phenological phases %s, years %s.",
      "Produced by the PhenoPhaseR pipeline using the BSE approach",
      "(Bayesian additive model with bivariate spatial smooth, `mgcv::bam`),",
      "and packaged as an RO-Crate 1.2 (Process Run Crate profile)."),
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
    "### Temporal gaps and NA bands",
    "",
    sprintf(paste0(
      "Every COG carries exactly one band per year over the full ",
      "%s axis (32 bands), so band index always maps to year: ",
      "band *i* corresponds to year %d + *i* \u2212 1."),
      yr_str, min(years)),
    "",
    paste0(
      "The pipeline handles temporal gaps explicitly. A *gap* in this ",
      "context is a year that *should* belong to the crop-phase's reporting ",
      "period but for which no interpolated surface could be produced \u2014 ",
      "typically because too few DWD stations survived the filter-variant ",
      "selection gate (Steps 5\u20136) to support a stable BAM fit. When that ",
      "happens, the year is written into the COG as a **full-extent all-NA ",
      "band** rather than being omitted. This keeps the band-to-year ",
      "mapping stable across phases and across crops, and lets ",
      "`terra::rast(file, lyrs = \"<year>\")` return a clean NA layer for a ",
      "gap year instead of throwing. NA always means \"in scope, no surface ",
      "available\"; it never means \"out of scope\" \u2014 years a crop is ",
      "genuinely not reported for are handled by setting the per-crop year ",
      "range, not by NA-padding."),
    "",
    paste0(
      "For each NA band that *is* written, the pipeline emits an ",
      "ISO 19157-1 `DQ_CompletenessOmission` `dqv:QualityMeasurement` node ",
      "in `ro-crate-metadata.json` (referenced from the affected phase's ",
      "`dqv:hasQualityMeasurement`), and a human-readable description of ",
      "the gap reason on the band itself (visible via ",
      "`gdalinfo cogs/DOY_<plant>-<phase>.tif`)."),
    "",
    gap_status_lines,
    "",
    "```r",
    "library(terra)",
    "",
    "# Local file (after downloading the deposit)",
    "doy_2020 <- terra::rast(\"cogs/DOY_202-15.tif\", lyrs = \"2020\")",
    "",
    "# Or stream directly from Zenodo without downloading the full deposit.",
    "# GDAL's /vsicurl/ uses HTTP range requests, so only the COG header",
    "# plus the bytes overlapping the requested layer/window are fetched.",
    "url <- paste0(\"/vsicurl/https://zenodo.org/records/<RECORD_ID>/files/\",",
    "              \"cogs/DOY_202-15.tif\")",
    "doy_2020 <- terra::rast(url, lyrs = \"2020\")",
    "",
    "# Crop to an area of interest in the same call — GDAL fetches only",
    "# the tiles overlapping the AOI, not the full Germany-wide grid.",
    "aoi <- terra::ext(10.5, 11.5, 52.0, 52.8)   # Uckermark example",
    "doy_2020_aoi <- terra::crop(terra::rast(url, lyrs = \"2020\"), aoi)",
    "```",
    "",
    "or via the CLI:",
    "",
    "```bash",
    "# Local",
    "gdal_translate -b <N> cogs/DOY_202-15.tif DOY_202-15_<year>.tif",
    "",
    "# Streaming from Zenodo (set the band by year position N)",
    "gdal_translate -b <N> \\\\",
    "  /vsicurl/https://zenodo.org/records/<RECORD_ID>/files/cogs/DOY_202-15.tif \\\\",
    "  DOY_202-15_<year>.tif",
    "```",
    "",
    "Streaming access is the recommended consumption pattern for ",
    "downstream pipelines (e.g. weather-index computation) where only ",
    "one year or one region is needed per run. It avoids downloading ",
    "the full multi-year COG when only a slice is required, and works ",
    "because every COG in this deposit is published as an individual ",
    "file at a stable Zenodo URL.",
    "",
    "## Validation",
    "",
    paste("This deposit declares conformance to the **RO-Crate 1.2** base",
          "profile and the **Process Run Crate** profile",
          "([https://w3id.org/ro/wfrun/process/0.5](https://w3id.org/ro/wfrun/process/0.5)),",
          "which is the WRROC base profile for series of software applications",
          "that contribute to the same overall computation without being",
          "orchestrated by a workflow engine. Conformance is verified at build",
          "time against the validator named below; we make no claims about",
          "cleanliness against other tools."),
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
    "- **Crate-declared profiles:** RO-Crate 1.2 base profile; Process Run Crate (WRROC base)",
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
  gap_spec       = NULL,
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  upstream_doi   = "10.5281/zenodo.19483111",
  dffp_tool_doi  = "10.5281/zenodo.19693642",
  dffp_dir       = NULL,
  agent_orcid    = creators[[1]][["@id"]],
  agent_name     = creators[[1]][["name"]],
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = FALSE,
  generate_html_preview = TRUE,
  run_roc_validator     = TRUE,
  roc_validator_profile = "ro-crate-1.1"
) {
  # ----------------------------------------------------------------------
  # Note on `zip_output`:
  # The Hook B deposit ships as a flat directory of multi-band COGs by
  # default (zip_output = FALSE). This is what lets downstream pipelines
  # like WeatherIndicatoR stream individual years via GDAL's /vsicurl/
  # virtual file system without downloading and unpacking the whole
  # deposit:
  #
  #   url <- "/vsicurl/https://zenodo.org/records/<id>/files/cogs/DOY_202-15.tif"
  #   doy_2020 <- terra::rast(url, lyrs = "2020")
  #
  # Burying the COGs inside a ZIP destroys this streaming behaviour
  # because ZIP's central directory is at the end of the archive and
  # per-entry deflate breaks the byte-offset linearity COG depends on.
  # The COGs themselves remain multi-band, multi-year — the change is
  # purely about delivery (flat vs. zipped), not COG internals.
  #
  # Set zip_output = TRUE if you also want a one-file bulk-download
  # archive next to the flat directory (e.g. for offline / archival
  # use, or for caching the full deposit in a single artifact). The
  # ZIP is written alongside the flat directory, not in place of it.
  # ----------------------------------------------------------------------
  #
  # Note on `gap_spec` (temporal gap handling):
  # Some (phase, year) interpolations cannot be produced — either the
  # crop-phase was not reported by DWD that year, or too few stations
  # passed filtering to interpolate a stable surface. Rather than omit
  # those years (which would shift the band-to-year mapping and break
  # downstream code that addresses bands by year), every missing year is
  # written as a full-extent all-NA band, so each COG is always a
  # complete 32-band cube where band i maps to years[i].
  #
  # `gap_spec` lets you record WHY each gap exists so the NA band can be
  # documented with a machine-readable reason. It is one of:
  #
  #   NULL            every gap is "insufficient_samples" (the default
  #                   interpolation-failure case)
  #   "<reason>"      a single reason string applied to every gap
  #   data.frame      columns `reason` (required), `phase` and `year`
  #                   (optional; NA = wildcard). Most specific row wins.
  #
  # Example for spring barley (207), where DWD reporting resumed in 2014
  # so 1993–2013 are true non-observations rather than failures:
  #
  #   gap_spec = data.frame(
  #     phase  = NA_integer_,            # any phase
  #     year   = 1993:2013,
  #     reason = "not_reported"
  #   )
  #
  # Example for oats (208), where reporting ended after 2022:
  #
  #   gap_spec = data.frame(phase = NA, year = 2023:2024,
  #                         reason = "not_reported")
  #
  # The gaps are surfaced as dqv:QualityMeasurement entities (ISO 19157-1
  # DQ_CompletenessOmission) in ro-crate-metadata.json and in each NA
  # band's GDAL band description.
  # ----------------------------------------------------------------------

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # Prevent GDAL from writing .tif.aux.json / .tif.aux.xml PAM sidecars into
  # the crate directory. terra reads each COG back after writing (to set band
  # descriptions and during validation), which would otherwise leave PAM
  # caches next to the COGs. Everything they cache (band statistics, NoData,
  # band names) is already in the COG's TIFF tags, so the sidecars are
  # redundant and would only pollute the Zenodo file listing.
  #
  # Note: GDAL reads GDAL_PAM_ENABLED from its runtime config, not (only) from
  # the process environment at library-load time, so we set it through terra's
  # GDAL config API. Sys.setenv alone does not reliably reach an already-loaded
  # GDAL. Both are set for belt-and-braces; the config call is the effective one.
  if (requireNamespace("terra", quietly = TRUE)) {
    .old_pam_cfg <- tryCatch(terra::getGDALconfig("GDAL_PAM_ENABLED"),
                             error = function(e) NA_character_)
    tryCatch(terra::setGDALconfig("GDAL_PAM_ENABLED" = "NO"),
             error = function(e) NULL)
    on.exit({
      val <- if (is.na(.old_pam_cfg) || !nzchar(.old_pam_cfg)) "YES" else .old_pam_cfg
      tryCatch(terra::setGDALconfig("GDAL_PAM_ENABLED" = val),
               error = function(e) NULL)
    }, add = TRUE)
  }
  .old_pam <- Sys.getenv("GDAL_PAM_ENABLED", unset = NA)
  Sys.setenv(GDAL_PAM_ENABLED = "NO")
  on.exit({
    if (is.na(.old_pam)) Sys.unsetenv("GDAL_PAM_ENABLED")
    else Sys.setenv(GDAL_PAM_ENABLED = .old_pam)
  }, add = TRUE)

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
  agg <- .aggregate_per_phase(results_dir, plant, phase, years, out_dir,
                              gap_spec = gap_spec)
  gap_log <- attr(agg, "gap_log"); if (is.null(gap_log)) gap_log <- list()

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
    validation_result = NULL,
    gap_log           = gap_log
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
  kw             <- build_keywords(
                      crop, artefact = "phase",
                      temporal = sprintf("%d\u2013%d", min(years), max(years)))

  # --- 5b. Completeness measurements from NA-padded gaps -----------------
  # Each (layer, phase) that required NA padding becomes one DQV
  # completeness-omission measurement summarising which years are absent
  # and why. Built before the root dataset so its @id references can be
  # attached to the root dataset's dqv:hasQualityMeasurement.
  gap_entities <- list()
  gap_refs     <- list()
  if (length(gap_log)) {
    # Group gap records by (layer, phase)
    key <- vapply(gap_log, function(g) sprintf("%s_%d", g$layer, g$phase),
                  character(1))
    for (k in unique(key)) {
      recs   <- gap_log[key == k]
      lyr    <- recs[[1]]$layer
      ph     <- recs[[1]]$phase
      gyears <- sort(vapply(recs, function(r) r$year, integer(1)))
      reasons <- unique(vapply(recs, function(r) r$reason, character(1)))
      gid <- sprintf("#completeness-%s-%d", lyr, ph)
      n_missing <- length(gyears)
      n_total   <- length(years)
      gap_entities[[length(gap_entities) + 1L]] <- list(
        "@id"   = gid,
        "@type" = c("schema:PropertyValue", "dqv:QualityMeasurement"),
        "schema:propertyID" = "completeness_omission",
        "schema:name"       = sprintf("temporal completeness (%s phase %d)",
                                      lyr, ph),
        "schema:value"      = sprintf("%d of %d years present",
                                      n_total - n_missing, n_total),
        "dqv:value"         = (n_total - n_missing) / n_total,
        "dqv:isMeasurementOf" = list("@id" = "#metric-DQ_CompletenessOmission"),
        "schema:unitText"   = "fraction of years present",
        "schema:description" = sprintf(
          "Years absent (NA-padded): %s. Reason(s): %s. Band index still maps to year (band i = %d + i - 1); absent years are present as full-extent NA bands so the COG remains a complete %d-band cube.",
          paste(gyears, collapse = ", "),
          paste(reasons, collapse = "; "),
          min(years), n_total),
        "schema:about" = list("@id" = sprintf("cogs/%s_%d-%d.tif",
                                              lyr, plant, ph))
      )
      gap_refs[[length(gap_refs) + 1L]] <- list("@id" = gid)
    }
    # Ensure the completeness Metric entity exists exactly once.
    have_completeness <- any(vapply(metric_entities, function(m)
      identical(m[["@id"]], "#metric-DQ_CompletenessOmission"), logical(1)))
    if (!have_completeness)
      metric_entities <- c(metric_entities,
                           list(.metric_entity("DQ_CompletenessOmission")))
  }

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
    # Subject anchoring: free-text keywords above plus the GeoNames spatial
    # coverage below. Controlled-vocabulary subject anchors (AGROVOC,
    # Wikidata, etc.) are deliberately not emitted in v1.6.2 onward — see
    # _crop_specs.R header comment for the rationale.
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
    "dqv:hasQualityMeasurement" = if (length(gap_refs)) gap_refs else list(),
    "schema:potentialAction" = dffp_action,
    "schema:review"          = if (length(dffp_reviews)) dffp_reviews else list()
  )

  # If a future release re-enables controlled-vocabulary subject anchors via
  # build_subject_entities(), these keys are populated automatically; for
  # v1.6.2 (no controlled vocabulary) the bundle is empty and the keys are
  # omitted from the root dataset entirely.
  if (length(subj_bundle$subject_refs)) {
    root_dataset[["about"]]       <- subj_bundle$subject_refs
    root_dataset[["dct:subject"]] <- subj_bundle$subject_refs
  }

  # --- 7. Contextual entities --------------------------------------------
  context_entities <- c(
    # Person entities for all creators (with roles + affiliation)
    creator_bundle$person_entities,
    list(
      # Profile Crate node — declares which WRROC profile this crate conforms
      # to. Process Run Crate (WRROC base profile) fits PhenoPhaseR's
      # multi-step R pipeline: a sequence of software applications that
      # contribute to the same overall computation, without being orchestrated
      # by a workflow engine. See https://w3id.org/ro/wfrun/process/0.5
      list("@id"     = "https://w3id.org/ro/wfrun/process/0.5",
           "@type"   = "CreativeWork",
           "name"    = "Process Run Crate",
           "version" = "0.5"),
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
           "@type" = "Place", "name" = "Federal Republic of Germany")
      # No DefinedTermSet for the subject vocabulary in v1.6.2 onward —
      # see _crop_specs.R header comment. If build_subject_entities()
      # ever re-emits a non-NULL defined_term_set, it is folded into
      # context_entities below the same way as defined_terms.
    )
  )
  if (!is.null(subj_bundle$defined_term_set))
    context_entities <- c(context_entities, list(subj_bundle$defined_term_set))
  if (length(subj_bundle$defined_terms))
    context_entities <- c(context_entities, subj_bundle$defined_terms)

  # --- 8. Metadata descriptor + assemble ---------------------------------
  metadata_descriptor <- list(
    "@id"        = "ro-crate-metadata.json",
    "@type"      = "CreativeWork",
    "conformsTo" = list(
      list("@id" = "https://w3id.org/ro/crate/1.2"),
      list("@id" = "https://w3id.org/ro/wfrun/process/0.5")
    ),
    "about"      = list("@id" = "./"),
    "description" = paste(
      "RO-Crate 1.2 (Process Run Crate profile) describing the final",
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
        # ISO 19157-1 dimension classes (referenced via dqv:inDimension on
        # the dqv:Metric entities; v1.7.0 no longer mints iso19157:<measure>
        # IRIs — only the genuine DQ_* dimension classes are referenced).
        "iso19157" = "http://standards.iso.org/iso/19157/-1/",
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
      gap_entities,
      metric_entities,
      list(create_action),
      context_entities
    )
  )

  out_json <- file.path(out_dir, "ro-crate-metadata.json")
  write_json(crate, out_json,
             pretty = TRUE, auto_unbox = TRUE,
             null = "null", na = "null", digits = 10)
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
    validation_result = vr,
    gap_log           = gap_log
  )

  # Defensive sweep: remove any PAM sidecars that slipped through (e.g. if a
  # read happened before the GDAL config took effect). These are pure caches;
  # nothing in the deposit references them. Done before any packaging so the
  # optional ZIP cannot capture them either.
  pam_sidecars <- list.files(
    out_dir, pattern = "\\.aux\\.(json|xml)$",
    recursive = TRUE, full.names = TRUE, all.files = TRUE)
  if (length(pam_sidecars)) {
    unlink(pam_sidecars)
    message(sprintf("Removed %d GDAL PAM sidecar(s) (.aux.json/.aux.xml).",
                    length(pam_sidecars)))
  }

  if (zip_output) {
    zip_path <- paste0(out_dir, ".zip")
    old <- setwd(dirname(out_dir)); on.exit(setwd(old), add = TRUE)
    # Enumerate the contents of out_dir, excluding the working subfolder
    # _per_year/ so the published ZIP carries only the aggregated artifacts
    # plus metadata. _per_year/ remains on disk for provenance.
    base <- basename(out_dir)
    all_in <- list.files(base, recursive = TRUE,
                         all.files = FALSE, full.names = TRUE,
                         include.dirs = FALSE)
    pub <- all_in[!grepl(sprintf("^%s/_per_year/", base), all_in)]
    utils::zip(zip_path, pub, flags = "-9X")
    message("Wrote optional bulk archive: ", zip_path,
            " (alongside flat layout; for offline use only)")
  }

  # Final upload guidance — make it explicit what goes to Zenodo so the
  # /vsicurl/ streaming pattern works for downstream consumers.
  all_rel    <- list.files(out_dir, recursive = TRUE, all.files = FALSE,
                           full.names = FALSE, include.dirs = FALSE)
  publishable <- all_rel[!grepl("^_per_year/", all_rel)]
  cog_files  <- publishable[grepl("\\.tif$", publishable)]
  message("\n",
    "================================================================================\n",
    "Hook B deposit ready at:\n  ", out_dir, "\n",
    "  - ", length(cog_files), " multi-band COG(s) under cogs/\n",
    "  - ", length(publishable) - length(cog_files), " supporting file(s) ",
    "(VAM/CAL/GEM CSVs, ro-crate-metadata.json, README.md)\n",
    "\n",
    "Upload the contents of `", basename(out_dir), "/` to a Zenodo deposit\n",
    "as individual files (do NOT pre-zip them). This preserves /vsicurl/\n",
    "streaming access for downstream pipelines, e.g.:\n",
    "\n",
    "  doy_url <- paste0(\"/vsicurl/https://zenodo.org/records/<id>/files/\",\n",
    "                   \"cogs/DOY_", plant, "-", phase[1], ".tif\")\n",
    "  doy_2020 <- terra::rast(doy_url, lyrs = \"2020\")\n",
    "\n",
    "The _per_year/ subfolder is a working artefact only and must not be\n",
    "uploaded. Excluded automatically when zip_output = TRUE.\n",
    "================================================================================"
  )

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
#   ## Simplest call — crop is looked up automatically by plant ID,
#   ## creators defaults to the family-wide list defined in _crop_specs.R.
#   ## With the default zip_output = FALSE, the deposit is written as a
#   ## flat directory of multi-band COGs + CSVs + metadata, which is what
#   ## you upload to Zenodo (one file per upload). This preserves
#   ## /vsicurl/ streaming access for downstream pipelines like
#   ## WeatherIndicatoR.
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
#   ## If you also want a single-file bulk-download ZIP next to the flat
#   ## directory (for archival or offline use), set zip_output = TRUE.
#   ## The ZIP is a companion, not a replacement: the flat directory is
#   ## still produced and is still what should go to Zenodo.
#   # build_phase_cog_ro_crate(..., zip_output = TRUE)
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
