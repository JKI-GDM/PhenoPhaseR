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

# AUTHOR:
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI) – Federal Research Centre
#              for Cultivated Plants; https://www.julius-kuehn.de/
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/

# USE OF AI TOOLS
# Parts of this code were developed with assistance from a generative AI 
# system (Perplexity, powered by GPT‑5.1), which was used to draft function 
# skeletons, refactor code, and generate documentation comments. All AI-assisted 
# content was reviewed, tested, and, where necessary, modified by the author, 
# who takes full responsibility for the final code and its behaviour.


# DATA SOURCE:
# Input:
# - DWD CDC Open Data: phenological annual reporter observations (TXT)
#   https://opendata.dwd.de/climate_environment/CDC/observations_germany/
#     phenology/annual_reporters/crops/
# - PHENO_STATION_EPSG31467.shp (Shapefile): DWD station coordinates
# - DGM1000_EPSG25832.asc (ASCII grid): 1 km DEM for Germany (BKG)
# - tmit_YYYY.csv (CSV): DWD gridded daily mean temperature
# Output:
# - DOY_<plant>-<phase>_<year>.tif (GeoTIFF): interpolated phenology grids
# - BSE_/KSV_/SSE_<plant>-<phase>_<year>.tif (GeoTIFF): uncertainty grids
# - VAM_<plant>-<phase>_<year>.csv (CSV): validation accuracy metrics
# - OPT_<plant>_<phase(s)>.csv (CSV): optimal filter variant tables

# DEPENDENCIES:
# - R >= 4.0.0
# - sf (spatial features I/O and projection)
# - raster (raster I/O and manipulation)
# - sp (spatial overlay and legacy support)
# - automap (automatic variogram fitting for kriging)
# - fields (thin-plate spline interpolation)
# - mgcv (generalized additive models – bam method)
# - caret (train/test partitioning)
# - MLmetrics (accuracy metrics: RMSE, MAE, MSE)
# - geosphere (coordinate calculations)
# - ggplot2 (visualization)

# CITATION:
# If you use this software in your research, please cite:
#   Möller, M. & Gerstmann, H. (2026). PhenoPhaseR: Reproducible phenology processing
#   workflow for DWD observations (v2.2). Zenodo.
#   https://doi.org/10.5281/zenodo.XXXXXXX

# FAIR COMPLIANCE:
# This software follows FAIR4RS principles (Barker et al., 2022;
# https://doi.org/10.15497/RDA00068) and the FAIRagro roadmap for
# publishing research code FAIR (Beyer et al., 2025;
# https://doi.org/10.5281/zenodo.14772748).
# See CITATION.cff and codemeta.json for machine-readable metadata.

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
output_dir   <- "~/PhenoPhaseR/output/"

# Temporal scope
years <- 1993:2024

# ==============================================================================
# CROP AND PHASE DEFINITIONS
# ==============================================================================
# DWD plant IDs and phenological phases to process.
# Uncomment the desired crop block or modify for custom runs.

# plant <- 202; target_phases <- c(10, 12, 15, 18, 19, 21, 24)           # Winter wheat
# plant <- 203; target_phases <- c(5, 6, 10, 12, 15, 18, 21, 24)         # Winter rye
# plant <- 204; target_phases <- c(10, 12, 15, 18, 21, 24)               # Winter barley
# plant <- 205; target_phases <- c(5, 10, 12, 14, 17, 22, 24, 67)        # Winter rapeseed
# plant <- 207; target_phases <- c(10,12,15,18,21,24)                    # Summer barley
# plant <- 208; target_phases <- c(10, 12, 15, 19, 21, 24, 66)           # Oats
# plant <- 215; target_phases <- c(5, 10, 12, 19, 20, 21, 24, 65, 67)    # Maize

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
      station_shapefile = "PHENO_STATION_EPSG31467.shp",
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
# threshold per year and phase, using adaptive Sample Number (SN)-weighted scoring.

source(file.path(function_dir, "filter_variant_selector.R"))

filter_variant_selector(
  in_dir          = output_dir,
  plant           = plant,
  phases          = target_phases,
  years           = years,
  sn_exponent_end = 2
)

# ==============================================================================
# STEP 7: Spatial interpolation
# ==============================================================================
# Interpolate optimal DOY observations to 1 km grid using mgcv::bam with
# automatic basis dimension selection. Optional kriging/TPS 
# (method = [krige, spline]) available.

source(file.path(function_dir, "spatial_interpolation.R"))

for (year in years) {
  for (target_phase in target_phases) {
    spatial_interpolation(
      plant       = plant,
      phase       = target_phase,
      year        = year,
      shp_dir     = output_dir,
      shp_epsg    = 31467,
      dem_dir     = data_dir,
      dem_grid    = "DGM1000_EPSG25832.asc",
      dem_epsg    = 25832,
      output_dir  = output_dir,
      method      = "bam",
      validation  = TRUE,
      uncertainty = FALSE
    )
  }
}

################################################################################
# END OF FILE
################################################################################
