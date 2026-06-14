################################################################################
# PhenoPhaseR
################################################################################
# PURPOSE:
# Orchestrate the complete PhenoPhaseR pipeline: download, filter, and
# spatially interpolate phenological Day of Year (DOY) observations from
# the German Weather Service (DWD). Implements the PHASE approach
# (Gerstmann et al., 2016, https://doi.org/10.1016/j.compag.2016.07.032)
# for temperature-sum-based phenological modelling of agricultural crops
# across Germany at 1 km spatial resolution.
#
# A single run of this wrapper now also publishes:
#   * Hook A → RO-Crate 1.2 of the filter variant results
#               (target Zenodo concept DOI 10.5281/zenodo.19483111)
#   * Hook B → RO-Crate 1.2 of the final PHASE entry-date COGs,
#               aggregated per phase as multi-band COGs (one band per year)
#               (target Zenodo concept DOI 10.5281/zenodo.19571847)
# Both crates carry embedded PROV-O provenance and ISO 19157-1 quality
# elements, an auto-written README.md documenting the validation stance,
# and a self-contained ro-crate-preview.html for browser-based inspection
# without external tooling. Hook B aggregates the per-(phase, year)
# intermediate outputs of spatial_interpolation.R into per-phase multi-
# band COGs (Cloud-Optimised GeoTIFFs with band names = years 1993–2025)
# plus three CSV families per phase: VAM (wide cross-validation), CAL
# (wide BAM in-sample diagnostics: AIC, BIC, EDF, deviance explained),
# and GEM (long-format spatial quantiles of the BSE uncertainty raster).
# The per-year intermediate files are moved into a working subdirectory
# `_per_year/` which is excluded from the published ZIP. Hook B
# additionally embeds Data-Fitness-for-Purpose (DFFP) reviews if
# dffp_dir is supplied. Mirrors the in-pipeline publishing pattern of
# WeatherIndicatoR (Möller 2026, doi:10.5281/zenodo.19631197).
#
# CONFIGURATION (this run):
#   PLANT         = 202 (winter wheat)
#   PHASES        = 10, 12, 15, 18, 19, 21, 24  (all winter wheat phases)
#   YEARS         = 1993–2025
#   METHOD        = bam   (BSE approach: BAM Bayesian additive model)
#   UNCERTAINTY   = TRUE  (required for BSE rasters)
#   OUTPUT LAYOUT = subfolders (shapefiles/, opt_scores/, cogs/, vam/, …)
#
# AUTHOR:
# Markus Möller; ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/
#
# USE OF AI TOOLS
# Parts of this code were developed with assistance from generative AI
# systems (Perplexity / GPT-5.1; Anthropic Claude). All AI-assisted content
# was reviewed, tested, and where necessary modified by the author, who
# takes full responsibility for the final code and its behaviour.
#
# DATA SOURCE:
# Input:
#   - DWD CDC Open Data: phenological annual reporter observations (TXT)
#   - PHENO_STATION_EPSG31467.shp (DWD station coordinates)
#   - DGM1000_EPSG25832.asc (1 km DEM for Germany, BKG)
#   - tmit_YYYY.csv (DWD gridded daily mean temperature)
# Output (subfolders under output_dir):
#   - shapefiles/                       Step 6 optimised DOY observations
#   - opt_scores/                       Step 6 OPT scoring tables
#   - opt_scores/diagnostics/           Step 6 diagnostic PDFs
#   - cogs/                             Step 7 per-(phase, year) DOY + BSE
#                                       Cloud-Optimized GeoTIFFs (interim)
#   - vam/                              Step 7 per-year validation accuracy
#                                       metrics (interim)
#   - splits/                           Step 7 training/test shapefiles
#   - ro_crate_filtervariants/  + .zip  Hook A publish-ready RO-Crate
#   - ro_crate_phase/cogs/              Hook B per-phase aggregated multi-
#                                       band COGs (1 band per year, named
#                                       by year)
#   - ro_crate_phase/vam/               Hook B per-phase wide-format VAM
#                                       CSVs (1 row per year)
#   - ro_crate_phase/_per_year/         Working subfolder containing the
#                                       Step 7 per-year inputs that were
#                                       aggregated; excluded from the ZIP
#   - ro_crate_phase.zip                Hook B publish-ready RO-Crate
#
# DEPENDENCIES:
# - R >= 4.0.0
# - sf, raster, sp, automap, fields, mgcv, caret, MLmetrics
# - geosphere, ggplot2, jsonlite, tools, gtools
# - terra (>= 1.7) — required by build_phase_cog_ro_crate.R for per-phase
#   multi-band COG aggregation
#
# CITATION:
# Möller, M. & Gerstmann, H. (2026). PhenoPhaseR: Reproducible phenology
# processing workflow for DWD observations (v1.7.1). Zenodo.
# https://doi.org/10.5281/zenodo.18743008
#
# FAIR COMPLIANCE:
# This software follows FAIR4RS principles (Barker et al., 2022;
# https://doi.org/10.15497/RDA00068) and the FAIRagro roadmap for
# publishing research code FAIR (Beyer et al., 2025;
# https://doi.org/10.5281/zenodo.14772748).
#
# LICENSE:
# This code is provided under the MIT License (SPDX: MIT)
# https://opensource.org/licenses/MIT
################################################################################

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Directory paths
function_dir <- "~/PhenoPhaseR/function/"
data_dir     <- "~/PhenoPhaseR/data/"

# ------------------------------------------------------------------------------
# CROP AND PHASE DEFINITIONS
# ------------------------------------------------------------------------------
# DWD plant ID 202 = Winter Wheat. Below all winter-wheat phases that
# PhenoPhaseR currently supports. Uncomment another block to switch crops —
# `_crop_specs.R` carries the full per-crop metadata (binomial, AGROVOC URI,
# Wikidata QID) for 202, 203, 204, 205, 207, 208, 215, 253 and is sourced
# automatically by both publish hooks.

plant <- 202
target_phases <- c(10, 12, 15, 18, 19, 21, 24)         # Winter wheat (202)
# plant <- 203; target_phases <- c(5, 6, 10, 12, 15, 18, 21, 24)   # Winter rye
# plant <- 204; target_phases <- c(10, 12, 15, 18, 21, 24)         # Winter barley
# plant <- 205; target_phases <- c(5, 10, 12, 14, 17, 22, 24, 67)  # Winter rapeseed
# plant <- 207; target_phases <- c(10, 12, 15, 18, 21, 24)         # Spring barley
# plant <- 208; target_phases <- c(10, 12, 15, 19, 21, 24, 66)     # Oats
# plant <- 215; target_phases <- c(5, 10, 12, 19, 20, 21, 24, 65, 67) # Maize
# Sugar beet (DWD plant ID 253; "Zucker-Ruebe" in the DWD catalogue) reports
# four observational milestones: 10 (Bestellung Beginn = sowing), 12
# (Auflaufen Beginn = emergence), 13 (Bestand geschlossen = canopy closure),
# 24 (Ernte = harvest). Note that DWD phase IDs are cross-crop observation
# slots from PH_Beschreibung_Phase.txt — 10/12/24 mean sowing/emergence/
# harvest universally across crops in the catalogue, not BBCH leaf-stage
# codes. (The DWD plant-ID assignment for beets has 252 = fodder beet and
# 253 = sugar beet per the authoritative phase catalogue.)
# plant <- 253; target_phases <- c(10, 12, 13, 24)                 # Sugar beet

# Per-crop output directory: parametric on `plant` so a single switch above
# routes the whole run (working artefacts + both publish-ready ZIPs) into
# its own directory and the previous crop's outputs are preserved on disk.
output_dir <- file.path("~/PhenoPhaseR/output", plant)
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# Source the shared crop-spec helper so we can render a human-readable
# crop name in the run summary at the bottom of this script. Both publish
# hooks source the same file themselves — there is no need to source it
# again here for the hooks to work; this is purely for the message banner.
source(file.path(function_dir, "_crop_specs.R"))
this_crop <- crop_spec(plant)

# +++ Optional: verify AGROVOC subject-anchor URIs against the live catalogue.
# The v1.6.0 AGROVOC layer shipped seven of ten hand-typed URIs pointing at
# the wrong concept (caught only by manual checking before publishing the
# second crop). verify_agrovoc_uris() resolves every URI in _crop_specs.R
# against agrovoc.fao.org and reports any that no longer match the concept
# they claim. It needs outbound network access and is throttled to respect
# AGROVOC's rate limit, so it adds ~20 s to a run. Report-only here so an
# offline run is not blocked; set stop_on_mismatch = TRUE (and ideally
# stop_on_unreachable = TRUE) in a CI/publishing context so a wrong URI
# cannot reach a published deposit. Comment this block out to skip entirely.
if (isTRUE(getOption("phenophaser.verify_agrovoc", default = TRUE))) {
  try(verify_agrovoc_uris(stop_on_mismatch = FALSE), silent = TRUE)
}

# Optional DFFP results directory (containing matrix.json, datasets.json,
# categories.json, narratives.txt, report.html). Set to NULL to skip the
# DFFP layer in the Hook B crate.
dffp_dir <- file.path(data_dir, "dffp")
if (!dir.exists(dffp_dir)) dffp_dir <- NULL

# Temporal scope
years <- 1993:2025


# +++ Capture pipeline start time for the Hook A PROV-O CreateAction +++
t0_filtervariant <- Sys.time()


# ==============================================================================
# STEP 1: Download phenology data from DWD Open Data
# ==============================================================================
# Downloads annual reporter phenological observations for the specified crop
# from the DWD CDC FTP server. Combines historical and recent datasets,
# removes duplicates, and exports to a standardized text file.

source(file.path(function_dir, "download_dwd_phenology.R"))
pheno_data <- download_dwd_phenology(
  plant      = plant,
  output_dir = output_dir
)


# ==============================================================================
# STEPS 2–5: Year × Phase processing loop
# ==============================================================================
# For each year and phenological phase:
#   Step 2: Couple observations with station coordinates and reference phases
#   Step 3: Load DWD gridded daily mean temperature for the vegetation period
#   Step 4: Calculate cumulative thermal time (Growing Degree Days = GDD) per station
#   Step 5: Determine critical DOY via temperature-sum quantile thresholds

for (year in years) {
  for (target_phase in target_phases) {

    # Step 2: Couple phenological observations with station coordinates
    source(file.path(function_dir, "couple_phenology_stations.R"))
    stations <- couple_phenology_stations(
      input_dir         = data_dir,
      station_shapefile = "PHENO_STATION_EPSG31467",
      target_phase      = target_phase,
      start_phase       = 10,
      plant             = plant,
      observation_year  = year,
      output_dir        = output_dir
    )

    # Step 3: Load gridded temperature aligned with vegetation period
    source(file.path(function_dir, "load_gridded_temperature.R"))
    temps <- load_gridded_temperature(
      pheno_data = stations,
      input_dir  = data_dir,
      parameter  = "tmit_",
      year       = year
    )

    # Step 4: Effective temperature calculation (cumulative thermal time)
    source(file.path(function_dir, "effective_temperature_calculation.R"))
    gdd_eft <- effective_temperature_calculation(
      gridded_climate      = temps,
      pheno_data           = stations,
      use_base_temperature = TRUE
    )

    # Step 5: Critical DOY determination with multiple filter strengths
    f_stds <- seq(1, 3, 0.5)
    source(file.path(function_dir, "critical_doy_determination.R"))
    for (f_std in f_stds) {
      temp_pheno_doy <- critical_doy_determination(
        pheno_data = gdd_eft,
        output_dir = output_dir,
        f_std      = f_std,
        q1         = 0.3,
        q2         = 0.7
      )
    }
  }
}


# ==============================================================================
# STEP 6: Filter variant optimization
# ==============================================================================
# Selects the optimal combination of filter strength (f_std) and quantile
# threshold per year and phase, using adaptive Sample Number (SN)-weighted
# scoring. Outputs are routed into <output_dir>/shapefiles/ and
# <output_dir>/opt_scores/ via subfolders = TRUE.

source(file.path(function_dir, "filter_variant_selector.R"))
filter_variant_selector(
  in_dir          = output_dir,
  out_dir         = output_dir,
  plant           = plant,
  phases          = target_phases,
  years           = years,
  sn_exponent_end = 2,
  subfolders      = TRUE
)


# ==============================================================================
# HOOK A: Publish filter variant results as RO-Crate 1.2
# ==============================================================================
# Packages the Step 6 outputs (shapefiles + OPT scoring tables) into a self-
# contained, Zenodo-ready RO-Crate with embedded PROV-O CreateAction
# spanning Steps 1–6 and ISO 19157-1 quality elements per (phase, year).
# Target Zenodo concept DOI: 10.5281/zenodo.19483111

t1_filtervariant <- Sys.time()

source(file.path(function_dir, "build_filtervariant_ro_crate.R"))

# Quality table is the OPT_MAX master file written by Step 6.
qtab_fv <- utils::read.csv2(
  file.path(output_dir, "opt_scores",
            sprintf("OPT_MAX_%d_ALL_PHASES.csv", plant)),
  stringsAsFactors = FALSE
)

build_filtervariant_ro_crate(
  out_dir       = file.path(output_dir, "ro_crate_filtervariants"),
  plant         = plant,
  phase         = target_phases,
  years         = years,
  results_dir   = output_dir,
  quality_table = qtab_fv,
  start_time    = t0_filtervariant,
  end_time      = t1_filtervariant
)


# ==============================================================================
# STEP 7: Spatial interpolation
# ==============================================================================
# Interpolate optimal DOY observations to 1 km grid using the BSE approach
# (BAM Bayesian additive model, mgcv::bam) with automatic basis dimension
# selection. Outputs DOY and BSE Cloud-Optimized GeoTIFFs into
# <output_dir>/cogs/ and per-year VAM cross-validation tables into
# <output_dir>/vam/.
# Note:
#   * shp_dir now points at output_dir/shapefiles/, the subfolder where
#     filter_variant_selector wrote the optimal-variant shapefiles.
#   * uncertainty = TRUE is required to produce the BSE rasters that
#     Hook B publishes.

# +++ Capture pipeline start time for the Hook B PROV-O CreateAction +++
t0_phase <- Sys.time()
source(file.path(function_dir, "spatial_interpolation.R"))

# Resilient per-cell wrapper. A single failed (phase, year) interpolation
# must never abort the whole loop. spatial_interpolation() already returns a
# clean "skipped" status (writing an NA surface) when the selector produced
# no input shapefile; this wrapper additionally catches *unanticipated* fit
# failures (singular fits, non-convergence) so they log-and-continue too.
# Failures are collected in `interp_failures` for the run summary.
interp_failures <- list()
run_interpolation <- function(...) {
  args <- list(...)
  res <- tryCatch(
    do.call(spatial_interpolation, args),
    error = function(e) {
      msg <- conditionMessage(e)
      message("FAILED interpolation: PLANT=", args$plant,
              " PHASE=", args$phase, " YEAR=", args$year,
              " — ", msg, " (continuing)")
      interp_failures[[length(interp_failures) + 1L]] <<- data.frame(
        PLANT = args$plant, PHASE = args$phase, YEAR = args$year,
        REASON = paste0("fit_error: ", msg), stringsAsFactors = FALSE)
      NULL
    }
  )
  invisible(res)
}

# Note:
#   * Interpolation without uncertainty layer derivation using training samples
#     and calculating global accuracy metrics
for (year in years) {
  for (target_phase in target_phases) {
    run_interpolation(
      plant       = plant,
      phase       = target_phase,
      year        = year,
      shp_dir     = file.path(output_dir, "shapefiles"),
      shp_epsg    = 31467,
      dem_dir     = data_dir,
      dem_grid    = "DGM1000_EPSG25832.asc",
      dem_epsg    = 25832,
      output_dir  = output_dir,
      method      = "bam",
      validation  = TRUE,
      uncertainty = FALSE,
      subfolders  = TRUE,
      skip_on_missing_input = TRUE
    )
  }
}

# Note:
#   * Final interpolation with uncertainty layer derivation using all samples
#     overwriting previous interpolation which only used training samples
for (year in years) {
  for (target_phase in target_phases) {
    run_interpolation(
      plant       = plant,
      phase       = target_phase,
      year        = year,
      shp_dir     = file.path(output_dir, "shapefiles"),
      shp_epsg    = 31467,
      dem_dir     = data_dir,
      dem_grid    = "DGM1000_EPSG25832.asc",
      dem_epsg    = 25832,
      output_dir  = output_dir,
      method      = "bam",
      validation  = FALSE,
      uncertainty = TRUE,
      subfolders  = TRUE,
      skip_on_missing_input = TRUE
    )
  }
}
# ==============================================================================
# HOOK B: Publish PHASE entry-date COGs as RO-Crate 1.2
# ==============================================================================
# Packages the Step 7 outputs (DOY + BSE COGs + VAM tables) into a self-
# contained, Zenodo-ready RO-Crate with embedded PROV-O CreateAction for
# Step 7, ISO 19157-1 quality elements per (phase, year), and — if
# dffp_dir is supplied — Data-Fitness-for-Purpose reviews per downstream
# application.
# Target Zenodo concept DOI: 10.5281/zenodo.19571847

t1_phase <- Sys.time()

source(file.path(function_dir, "build_phase_cog_ro_crate.R"))

# Quality table assembled from per-year VAM tables written by Step 7.
vam_files <- list.files(
  file.path(output_dir, "vam"),
  pattern    = sprintf("^VAM_%d-.+\\.csv$", plant),
  full.names = TRUE
)
qtab_phase <- do.call(
  rbind,
  lapply(vam_files, utils::read.csv2, stringsAsFactors = FALSE)
)

# Assemble the gap reasons for Hook B from two sources:
#   1. GAPS_<plant>.csv written by filter_variant_selector (the authoritative
#      "insufficient samples / low correlation" detections at the min_obs gate)
#   2. any runtime fit failures caught by run_interpolation() above
# build_phase_cog_ro_crate() will NA-pad exactly these (phase, year) cells and
# record each as an ISO 19157-1 DQ_CompletenessOmission measurement. Leaving
# this NULL falls back to a generic "insufficient_samples" reason for any
# NA-padded year.
gaps_file <- file.path(output_dir, "opt_scores", paste0("GAPS_", plant, ".csv"))
gap_spec <- NULL
gap_rows <- list()
if (file.exists(gaps_file)) {
  gl <- utils::read.csv2(gaps_file, stringsAsFactors = FALSE)
  if (nrow(gl))
    gap_rows[[length(gap_rows) + 1L]] <-
      data.frame(phase = gl$PHASE, year = gl$YEAR, reason = gl$REASON,
                 stringsAsFactors = FALSE)
}
if (length(interp_failures))
  gap_rows[[length(gap_rows) + 1L]] <- {
    fdf <- do.call(rbind, interp_failures)
    data.frame(phase = fdf$PHASE, year = fdf$YEAR, reason = fdf$REASON,
               stringsAsFactors = FALSE)
  }
if (length(gap_rows)) gap_spec <- do.call(rbind, gap_rows)

build_phase_cog_ro_crate(
  out_dir       = file.path(output_dir, "ro_crate_phase"),
  plant         = plant,
  phase         = target_phases,
  years         = years,
  results_dir   = output_dir,
  quality_table = qtab_phase,
  gap_spec      = gap_spec,
  start_time    = t0_phase,
  end_time      = t1_phase,
  upstream_doi  = "10.5281/zenodo.19483111",
  dffp_dir      = dffp_dir
)


# Optional visualization
# Runs after the Hook B publish step because it consumes the per-year working
# files under ro_crate_phase/_per_year/cogs/ (those are kept on disk for
# provenance even though they are excluded from the published flat layout).
# Adjust target_phase / year for the AOI of interest. The two helper scripts
# (plot_phenology_raster_maps.R, plot_phenology_window_timeseries.R) are
# expected under function_dir.
doy_2018 <- file.path(output_dir, "ro_crate_phase", "_per_year", "cogs",
                      "DOY_202-18_2018.tif")
bse_2018 <- file.path(output_dir, "ro_crate_phase", "_per_year", "cogs",
                      "BSE_202-18_2018.tif")
pheno_dir <- file.path(output_dir, "ro_crate_phase", "_per_year", "cogs")

if (file.exists(doy_2018) && file.exists(bse_2018) &&
    file.exists(file.path(function_dir, "plot_phenology_raster_maps.R"))) {
  source(file.path(function_dir, "plot_phenology_raster_maps.R"))
  map_res <- plot_phenology_raster_maps(
    doy_file     = doy_2018,
    bse_file     = bse_2018,
    plant        = 202, target_phase = 18, year = 2018,
    output_dir   = output_dir, aoi = "Uckermark"
  )
}

if (dir.exists(pheno_dir) &&
    file.exists(file.path(function_dir, "plot_phenology_window_timeseries.R"))) {
  source(file.path(function_dir, "plot_phenology_window_timeseries.R"))
  ts_res <- plot_phenology_window_timeseries(
    pheno_dir   = pheno_dir,
    aoi         = "Uckermark",
    plant       = 202, crop_label = "Winter Wheat",
    phases      = c(`15` = "shooting", `18` = "heading"),
    years       = 1993:2025,
    output_dir  = output_dir
  )
}


# ==============================================================================
# RUN SUMMARY
# ==============================================================================
message(
  "\n",
  "================================================================================\n",
  "PhenoPhaseR run complete\n",
  "================================================================================\n",
  "Crop:             ", plant, " (", this_crop$common_name_en,
                       ", ", this_crop$binomial, ")\n",
  "Phases:           ", paste(target_phases, collapse = ", "), "\n",
  "Years:            ", min(years), "-", max(years), "\n",
  "Output directory: ", output_dir, "\n",
  "\n",
  "Hook A (filter variants) → ",
  file.path(output_dir, "ro_crate_filtervariants.zip"),
  "  (one ZIP, upload to Zenodo as-is)\n",
  "Hook B (PHASE COGs)      → ",
  file.path(output_dir, "ro_crate_phase"),
  "/  (flat directory; upload all files to Zenodo individually)\n",
  "\n",
  "Hook A ships as a single ZIP because the underlying ESRI shapefiles\n",
  "are multi-file sets that have to be bundled. Hook B ships as a flat\n",
  "directory of multi-band COGs so downstream pipelines can stream\n",
  "individual years via GDAL's /vsicurl/ from Zenodo without downloading\n",
  "the whole deposit.\n",
  "\n",
  "Ready for upload to Zenodo as new versions of the concept records\n",
  "for this crop. For winter wheat (plant 202) these are:\n",
  "  - 10.5281/zenodo.19483111  (filter variant results)\n",
  "  - 10.5281/zenodo.19571847  (PHASE entry-date COGs)\n",
  "For other crops, mint a new pair of concept DOIs on first upload and\n",
  "record them in the per-crop deposit configuration.\n",
  "================================================================================\n"
)


################################################################################
# END OF FILE
################################################################################
