################################################################################
#
# Climate Data Loading Function for Phenological Analysis
#
################################################################################

# PURPOSE:
# Load interpolated gridded temperature data for a specific vegetation period 
# defined by phenological observations.
# Handles crop-specific temporal logic (winter vs. summer crops, sowing year
# offsets) and aligns climate data with phenological observation dates.
#
# This function bridges phenological observations (from couple_phenology_stations)
# with gridded climate data to enable agro-meteorological analysis, growing
# degree-day calculations, and climate-phenology relationships.

# AUTHORS:
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/

# DATA SOURCE:
# Input 1: Phenological observations (from function couple_phenology_stations)
# Input 2: Gridded climate data (interpolated temperature)
#          pre-processed by DWD

# DEPENDENCIES:
# - R >= 4.0.0
# - Base R packages (no additional dependencies)

# VERSION HISTORY:
# v1.0.0 (2024-12-12): Original version

# CITATION:
# If you use this code in your research, please cite:
# Möller, M. & Gerstmann, H. (2025). load_gridded_temperature: Climate data loading tool for phenological analysis.
# Available at: [repository URL - add when published]

# LICENSE:
# This code is provided under the MIT License

################################################################################
# ==============================================================================
# FUNCTION: load_gridded_temperature
# ==============================================================================

# PURPOSE:
# Load interpolated gridded temperature data aligned with a specific 
#vegetation period. Automatically handles:
# - Crop-specific temporal logic (winter crops sow in previous year)
# - Day-of-year (DOY) to calendar date conversion
# - Multi-year temperature data concatenation
# - File path construction from standard naming conventions

# ARGUMENTS:

# pheno_data (data.frame, REQUIRED):
# - Phenological observations with required columns:
#   * STATION: Meteorological station ID (numeric)
#   * YEAR: Reference/harvest year (numeric, calendar year)
#   * PLANT: Crop object ID using DWD codes:
#     - Winter crops: 202 (Winter wheat), 203 (Winter rye),
#       204 (Winter barley), 205 (Winter rapeseed)
#     - Summer crops: 201, 207-209, 215, 231-234, 250, 252-253
#   * PHASE: Phenological phase ID (numeric)
#     - Phase 10: Sowing
#     - Phase 12, 14: Special handling (sowing phase equivalents)
#     - Other phases: Regular handling
#   * DOY: Day of year (numeric, 1-366) for target observation date
#   * DOY_START: Day of year (numeric) for reference start date (e.g., sowing)
# - Output from couple_phenology_stations() or equivalent

# input_dir (character, REQUIRED):
# - Full path to directory containing gridded climate data files
# - Directory structure expected:
#   [parameter][YEAR].csv (e.g., "tmit_2024.csv")
# - Files should contain gridded interpolated data with:
#   * Column 1: GRID_ID (spatial grid identifier)
#   * Columns 2+: Daily values (T1, T2, ..., T366 for full year)

# parameter (character, REQUIRED):
# - Prefix of climate data files to load
# - Examples: "tmit_" = daily mean temperature
# - Function constructs file names as: DOY_[CROP-ID]-[PHASE-ID][YEAR].csv
# - Must match DWD naming convention

# year (numeric, REQUIRED):
# - Harvest/reference year (calendar year)
# - For winter crops: function automatically loads previous year data
# - For summer crops and the winter crop phases 10, 12 and 14: only current year data loaded

# RETURNS:
# gridded_data (data.frame):
# - Gridded temperature data aligned with vegetation period
# - Structure:
#   * Column 1: GRID_ID (grid cell identifier)
#   * Column 2+: Daily climate values for vegetation period
#     - Column names: T1, T2, ..., TN (sequential days)
#     - For winter crops spanning 2 calendar years:
#       * Negative indices (T-365, T-364, ..., T-1, T0) for sowing year
#       * Positive indices (T1, T2, ..., TN) for harvest year
# - Rows represent individual grid cells
# - Fully documented with standardized column naming

# SIDE EFFECTS:
# 1. Console messages: reports data loading steps, crop type, year handling
# 2. File operations: reads climate data files from input_dir
# 3. Memory: creates temporary data frames during processing
#    (explicitly garbage collected to manage memory usage)

# CROP-SPECIFIC LOGIC:

# Winter Crops (202, 203, 204, 205):
# - Sown in autumn of previous calendar year
# - Exceptions: phases 10, 12 and 14 are treated like Summer Crops 
# - Phenological observations typically span 2 calendar years
# - Example: 2024 harvest wheat sown in autumn 2023
# - Climate data:
#   * Loads temperature from YEAR-1 (2023) for sowing period
#   * Loads temperature from YEAR (2024) for growth period
#   * Merges into single data frame with:
#     - Negative DOY indices: autumn 2023 (T-365 to T0)
#     - Positive DOY indices: spring 2024 (T1 onwards)
#   * Allows Growingh Degree Day (GDD)/thermal sum calculations across year boundary

# Summer Crops (201, 207-209, 215, 231-234, 250, 252-253):
# - Sown in spring of current calendar year
# - Observations typically within single calendar year
# - Example: 2024 potato sown and harvested in 2024
# - Climate data:
#   * Loads only YEAR temperature (single year)
#   * DOY indices are positive (T1, T2, ..., T365/366)
#   * No multi-year merging required

# PHASE HANDLING:
# - Phase 10 (sowing): Always uses previous year data for winter crops
# - Phases 12, 14: Treated as special sowing equivalents (winter crops)
# - Other phases (e.g., 25 = emergence): Use standard temporal logic

# TEMPORAL INDEXING:
# - Day-of-year (DOY) represents position within calendar year:
#   * DOY = 1: January 1st
#   * DOY = 32: February 1st
#   * DOY = 365/366: December 31st
# - For winter crops, sowing DOY from YEAR-1, growth DOY from YEAR
# - Column naming convention:
#   * T1, T2, ..., T365/366: Daily values indexed by DOY
#   * Enables seamless merging of data from different years

# DATA QUALITY:
# - Function assumes input files are pre-processed and quality-checked
# - No missing value handling (assumes complete gridded datasets)
# - No spatial validation (assumes GRID_ID consistency across years)
# - Consider implementing optional validation for production use

# ERRORS & WARNINGS:
# - Error: Files not found if input_dir or parameter combination invalid
# - Warning: None explicit; function assumes valid inputs
# - Consider: Add warning if file sizes differ (indicates data inconsistency)

# FILE NAME CONSTRUCTION:
# - Pattern: [parameter][YEAR].csv
# - Example: "tmit_2024.csv"
# - Location: [input_dir]/[constructed_filename]
# - Files must be readable as standard R CSV format

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

load_gridded_temperature <- function(
    pheno_data,
    input_dir,
    output_dir,
    parameter,
    year
) {
  
  # -------------------------------------------------------------------------
  # INPUT VALIDATION
  # -------------------------------------------------------------------------
  
  message(
    "Loading gridded climate data for vegetation period...\n",
    "Parameter: ", parameter, " | Year: ", year
  )
  
  # Check required columns in phenological input
  required_cols <- c("PLANT", "PHASE", "YEAR", "DOY", "DOY_START")
  missing_cols <- setdiff(required_cols, names(pheno_data))
  
  if (length(missing_cols) > 0) {
    stop(
      "Missing required columns in pheno_data: ",
      paste(missing_cols, collapse = ", "),
      "\nExpected columns (from couple_phenology_stations): ",
      paste(required_cols, collapse = ", ")
    )
  }
  
  # Verify input directory exists
  if (!dir.exists(input_dir)) {
    stop(
      "Input directory not found: ", input_dir,
      "\nPlease verify path and try again."
    )
  }
  
  # -------------------------------------------------------------------------
  # CROP CLASSIFICATION
  # -------------------------------------------------------------------------
  
  # Define crop groups for temporal logic
  winter_crops <- c(202, 203, 204, 205)  # Winter cereals and rapeseed
  summer_crops <- c(201, 207, 208, 209, 215, 231, 232, 233, 234, 250, 252, 253)
  
  # Extract crop ID from phenological data (assume uniform crop in dataset)
  crop <- unique(pheno_data$PLANT)[1]
  is_winter_crop <- crop %in% winter_crops
  
  # -------------------------------------------------------------------------
  # PHASE CLASSIFICATION (Reusability)
  # -------------------------------------------------------------------------
  
  # Extract phenological phase from data
  phase <- unique(pheno_data$PHASE)[1]
  
  # Determine if this is a sowing-type phase for winter crops
  is_sowing_phase <- is_winter_crop && (phase %in% c(10, 12, 14))
  
  # -------------------------------------------------------------------------
  # LOAD SCENARIO 1: Winter crop at sowing phase (after harvest in the reference YEAR)
  # -------------------------------------------------------------------------
  
  if (is_sowing_phase) {
    
    # Construct file path for sowing year climate data
    climate_file <- file.path(input_dir, paste0(parameter, year, ".csv"))
    
    # Check file existence
    if (!file.exists(climate_file)) {
      stop(
        "Climate data file not found: ", climate_file,
        "\nExpected file pattern: [input_dir]/[parameter][YEAR].csv"
      )
    }
    
    # Read sowing year climate data
    # header = FALSE: data file has no header (standard gridded format)
    # sep = ",": comma-delimited CSV format
    gridded_full <- read.table(
      climate_file,
      header = FALSE,
      sep = ",",
      dec = "."
    )
    
    # Standardize column naming: GRID_ID, T1, T2, ..., T366
    colnames(gridded_full) <- c(
      "GRID_ID",
      paste0("T", seq_len(ncol(gridded_full) - 1))
    )
    
    message(
      "Loaded temperature data for winter crops, target_phase ", target_phase, " and year ", observation_year
    )
    
    # Return early: no multi-year merging needed
    return(gridded_full)
  }
  
  # -------------------------------------------------------------------------
  # LOAD SCENARIO 2: General case
  # -------------------------------------------------------------------------
  
  # Construct file path for reference year climate data
  climate_file <- file.path(input_dir, paste0(parameter, year, ".csv"))
  
  # Verify file existence
  if (!file.exists(climate_file)) {
    stop(
      "Climate data file not found: ", climate_file,
      "\nExpected file pattern: [input_dir]/[parameter][YEAR].csv"
    )
  }
  
  # Read reference year climate data
  gridded_year <- read.table(
    climate_file,
    header = FALSE,
    sep = ",",
    dec = "."
  )
  
  # Standardize column names for reference year
  colnames(gridded_year) <- c(
    "GRID_ID",
    paste0("T", seq_len(ncol(gridded_year) - 1))
  )
  
  message(
    "Loading temperature data for summer crops, target_phase ", target_phase, " and year ", year)
  
  # -------------------------------------------------------------------------
  # HANDLE WINTER CROPS (Multi-year merging)
  # -------------------------------------------------------------------------
  
  if (is_winter_crop && !is.element(phase, c(10, 12, 14))) {
    
    # Identify minimum sowing DOY from phenological data
    # This determines how far back into previous year we need climate data
    min_doy_start <- min(pheno_data$DOY_START, na.rm = TRUE)
    
    message(
      "Earliest sowing date: DOY ", min_doy_start, " (",
      "loading from DOY ", min_doy_start, " in previous year)"
    )
    
    # Store reference year temporarily
    gridded_ref_year <- gridded_year
    rm(gridded_year)
    gc()  # Garbage collect to manage memory for large gridded datasets
    
    # Load sowing year climate data
    climate_file_prev <- file.path(
      input_dir,
      paste0(parameter, year - 1, ".csv")
    )
    
    if (!file.exists(climate_file_prev)) {
      stop(
        "Previous year climate data not found: ", climate_file_prev,
        "\nRequired for winter crop analysis spanning ",
        year - 1, " to ", year
      )
    }
    
    # Read previous year data
    gridded_prev_year <- read.table(
      climate_file_prev,
      header = FALSE,
      sep = ",",
      dec = "."
    )
    
    # Standardize column names for sowing year
    colnames(gridded_prev_year) <- c(
      "GRID_ID",
      paste0("T", seq_len(ncol(gridded_prev_year) - 1))
    )
    
    message(
      "Loading temperature data for winter crops, target_phase ", target_phase, " for the years ", year, " and ", year - 1)
    
    
    # -----------------------------------------------------------------------
    # TEMPORAL ALIGNMENT: Convert previous year DOY to negative indices
    # -----------------------------------------------------------------------
    
    # Column naming convention for previous year:
    # - DOY 1-365 of YEAR-1 → T-365, T-364, ..., T-1, T0
    # - This allows seamless chronological merging across year boundary
    # - Example: DOY 200 of 2023 → T-166 (166 days before Jan 1, 2024)
    
    n_prev_cols <- ncol(gridded_prev_year) - 1  # Exclude GRID_ID column
    negative_doy_values <- seq(-n_prev_cols, -1, by = 1)
    
    colnames(gridded_prev_year) <- c(
      "GRID_ID",
      paste0("T", negative_doy_values)
    )
    
    # -----------------------------------------------------------------------
    # MERGE: Combine previous and reference year data
    # -----------------------------------------------------------------------
    
    # Merge on GRID_ID to align spatial grid cells
    gridded_full <- merge(
      gridded_prev_year,
      gridded_ref_year,
      by = "GRID_ID",
      all = FALSE,  # Keep only matching grid cells
      sort = FALSE
    )
    
    # Cleanup temporary objects
    rm(gridded_prev_year, gridded_ref_year)
    gc()
    
  } else {
    # Summer crops or special sowing phases: use only reference year
    gridded_full <- gridded_year
  }

    # -------------------------------------------------------------------------
  # RETURN VALUE
  # -------------------------------------------------------------------------
  
  message(
    "Climate data loading complete. ",
    "Data frame structure: ",
    nrow(gridded_full), " rows (grid cells) × ",
    ncol(gridded_full), " columns (GRID_ID + DOY values)\n"
  )
  
  # Return gridded data invisibly
  # invisible() prevents auto-printing in interactive sessions
  # but allows assignment: temp_data <- load_gridded_temperature(...)
  invisible(gridded_full)
}

################################################################################
# USAGE EXAMPLES
# ==============================================================================
# # Example 1: Winter Wheat (202) temperature data, 2023 sowing and 2024 harvest
# winter_wheat_temps <- load_gridded_temperature(
#   pheno_data = stations_winter_wheat,  # from couple_phenology_stations()
#   input_dir = "./data/",
#   parameter = "tmit_",
#   year = 2024
# )
# # Returns: Temperatures from autumn 2023 (sowing) through spring 2024 (harvest)
# # Columns: GRID_ID, T-365, T-364, ..., T0, T1, T2, ..., T365

# # Example 2: Maize (215) temperature data, 2024 sowing andharvest
# potato_precip <- fLoadTemp(
#   pheno_data = stations_potato,  # from couple_phenology_stations()
#   input_dir = "./data/",
#   parameter = "tmit_",
#   year = 2024
# )
# # Returns: Temperature from spring 2024 (sowing) through autumn 2024
# # Columns: GRID_ID, T1, T2, ..., T365
# ################################################################################
# END OF FILE
# ################################################################################
