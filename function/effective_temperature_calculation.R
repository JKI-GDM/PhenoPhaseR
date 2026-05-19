################################################################################
#
# Thermal Time Summation Function for Phenological Analysis
#
################################################################################

# PURPOSE:
# Calculate effective temperature and thermal time sums for phenological 
# observations across a vegetation period. Integrates phenological observations 
# with gridded climate data to derive crop-specific thermal accumulations, 
# accounting for crop-specific base temperatures, photoperiod effects, and 
# multi-year temporal logic.


# AUTHORS:
# Henning Gerstmann
# Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/
# Markus Möller
# ORCID: https://orcid.org/0000-0002-1918-7747
# Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/


# DATA SOURCE:
# Input 1: Phenological observations (from function couple_phenology_stations())
# Input 2: Gridded climate data (from function load_gridded_temperature())

# DEPENDENCIES:
# - R >= 4.0.0
# - sp (for spatial data handling)
# - geosphere (for daylength calculations)

# VERSION HISTORY:
# v1.0.0 (2025-12-12): Original version

# CITATION:
# If you use this code in your research, please cite:
# Möller, M. & Gerstmann, H. (2025). effectice_temperature_calculation: Thermal time summation tool for phenological analysis.
# Available at: [repository URL - add when published]

# LICENSE:
# This code is provided under the MIT License

################################################################################
# ==============================================================================
# FUNCTION: effective_temperature_calculation()
# ==============================================================================

# PURPOSE:
# Calculate cumulative thermal time (effective temperature) and growing degree-days
# (GDD) from phenological observations and gridded temperature data. Performs:
# - Crop-specific base temperature (Tb) selection
# - Base temperature subtraction from daily temperatures
# - Photoperiod adjustment (daylength weighting)
# - Truncation of negative values (GDD never negative)
# - Temporal alignment across calendar year boundaries (winter crops)
# - Row-wise summation across vegetation periods
#
# Returns spatial data frame with original phenological data augmented by
# thermal accumulation metrics (T_SUMS column).

# ARGUMENTS:

# gridded_climate (data.frame or SpatialDataFrame, REQUIRED):
# - Gridded climate data with required structure:
#   * Column 1: GRID_ID (spatial grid cell identifier)
#   * Columns 2+: Daily climate values with standardized naming:
#     - For single-year data: T1, T2, ..., T365 or T366
#     - For multi-year data: T-365, T-364, ..., T0, T1, T2, ...T365
#     - Column names extracted with substr(name, 2, 5) for DOY conversion
# - Output from load_gridded_temperature() or equivalent gridded climate processing
# - Represents interpolated daily temperature (°C × 10 in DWD convention)

# pheno_data (SpatialPointsDataFrame, REQUIRED):
# - Phenological observations spatially referenced to grid cells
# - Required attributes (pheno_data@data):
#   * STATION: Meteorological station ID (numeric)
#   * GRID_ID: Spatial grid cell identifier (numeric)
#   * YEAR: Reference/harvest year (numeric, calendar year)
#   * PLANT: Crop object ID using DWD codes
#   * PHASE: Phenological phase ID (numeric)
#   * DATE: Observation date in format YYYYMMDD (numeric)
#   * DOY: Day of year for target phase (numeric, 1-366)
#   * DOY_START: Day of year for start phase (numeric)
#     - For winter crops: references previous calendar year (stored as negative)
#     - For summer crops: positive index within current year
# - Output from couple_phenology_stations() or equivalent

# use_base_temperature (logical, default = TRUE):
# - If TRUE: Apply crop-specific base temperature (Tb) subtraction
#     - Base temperature varies by crop type (e.g., 5.5°C for cereals)
#     - GDD = sum(max(0, Temp - Tb)) across vegetation period
#     - Note: Input temperatures assumed to be × 10 (DWD convention)
# - If FALSE: Calculate simple temperature sum without Tb
#     - Returns raw cumulative temperature (not recommended for GDD)
#     - Useful for validation or alternative thermal metrics

# RETURNS:
# result (SpatialPointsDataFrame):
# - Enhanced version of input pheno_data with appended thermal metrics
# - Retained attributes:
#   * All original pheno_data@data columns
#   * Spatial coordinates (CRS preserved)
#   * Feature geometries
# - New attributes:
#   * LON: Longitude (EPSG:4326, WGS84)
#   * LAT: Latitude (EPSG:4326, WGS84)
#   * ID: Sequential observation identifier
#   * T_SUMS: Cumulative effective temperature (GDD) from DOY_START to DOY
#     - Units: °C × 10 (following DWD convention)
#     - Interpretation: Growing degree-days accumulated during vegetation period
#     - Values constrained to [0, Inf); negative daily temperatures treated as 0
# - Rows: Only observations with DOY > DOY_START (valid vegetation period)

# SIDE EFFECTS:
# 1. Console messages: Reports processing steps, crop type, base temperature selection
# 2. Data transformations: Modifies spatial attributes in place
# 3. Memory: Creates temporary data frames during processing
#    (automatically cleaned up via R garbage collection)

# CROP-SPECIFIC BASE TEMPERATURES (Tb):
# Base temperature values define the theoretical minimum for crop growth.
# Values follow agronomic literature and DWD conventions.
#
# Winter cereals & grass (T_base = 5.5°C):
# - 202: Winter wheat
# - 203: Winter rye
# - 204: Winter barley
# - 207: Summer barley
# - 208: Oats
# - 215: Maize [alternative: 10°C for grain maize]
#
# Winter rapeseed (T_base = 5.0°C):
# - 205: Winter rapeseed
#
# Grassland & forage crops (T_base = 2.0°C):
# - 201: Permanent grassland
#
# Oil crops (T_base = 6.0°C):
# - 209: Sunflower
#
# Root crops & beet (T_base = 3.0°C):
# - 250: Beet, unspecified
# - 252: Fodder beet
# - 253: Sugar beet
#
# Vegetables & other crops (variable):
# - 241-246: Various vegetables
# - < 200: Grassland and extensive (T_base = 0.0°C)
# - 300-400: Fruits and vegetables (T_base = 0.0°C)
# - > 400: Special crops (T_base = 10.0°C)
# - Default: T_base = 5.0°C for unmapped crops

# PHOTOPERIOD ADJUSTMENT:
# Daily temperatures weighted by photoperiod length to account for variable
# day length across seasons and latitudes.
#
# Algorithm:
# 1. Extract DOY from temperature column names (e.g., T123 → DOY 123)
# 2. Calculate daylength using geosphere::daylength(latitude, doy)
# 3. Adjust daily temperature: Adjusted_T = Temp × (Daylength / 24)
# 4. This reduces effective temperature accumulation in winter/high latitudes
#
# Note: Assumes input daylength in hours; normalization by 24 scales to full-day equivalent

# TEMPORAL ALIGNMENT (Winter Crops):
# Winter crops span two calendar years (e.g., autumn sowing 2023 → spring harvest 2024).
#
# Algorithm:
# 1. Input DOY_START references previous year (stored negative): DOY_START = -150
# 2. Column names from function load_gridded_temperature(): T-365, T-364, ..., T0, T1, T2, ...
# 3. Row filtering: Keep only observations with DOY > DOY_START
# 4. Row summation: Sum columns from T[DOY_START] through T[DOY]
#
# Special case (Phase 10 = Sowing):
# - Winter crop at sowing: DOY_START reset to 1 (season start)
# - uses previous year temperature data (from load_gridded_temperature()) for phases of 
# the current year; phase 10, 12 and 14 are treated like summer crops

# DATA QUALITY & CONSTRAINTS:
# - Negative daily temperatures truncated to 0 (GDD constraint)
# - DOY values capped at 365 (handles leap year edge cases)
# - Missing values: Function assumes complete gridded data (no NA handling)
# - Spatial alignment: GRID_ID must match between pheno_data and gridded_climate
# - Temporal alignment: Column naming convention (T±DOY) strictly required

# ERRORS & WARNINGS:
# - Error: Missing required columns in pheno_data (@data slot)
# - Error: GRID_ID mismatch between phenology and gridded data (merge results in 0 rows)
# - Error: No temperature columns detected (indicates data structure error)
# - Warning: If use_base_temperature = FALSE (non-standard analysis)
# - Silent constraint: Negative temperatures automatically set to 0

# ASSUMPTIONS & LIMITATIONS:
# 1. Input temperature already scaled by 10 (DWD convention)
# 2. Input DOY values valid (1-366); no validation performed
# 3. Grid cells consistent across climate data years
# 4. PLANT and PHASE uniform within input pheno_data (uses unique(...)[1])
# 5. No handling of leap year artifacts (DOY=366 edge cases)
# 6. Daylength calculation uses geosphere::daylength; assumes spherical Earth
# 7. CRS transformation to WGS84 (EPSG:4326) in all cases

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
# DEPENDENCY LOADING (Findability & Accessibility)
# ==============================================================================
ensure_packages(c("sp",
                  "geosphere"))

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

effective_temperature_calculation <- function(
    gridded_climate,
    pheno_data,
    use_base_temperature = TRUE
) {
  
  # -------------------------------------------------------------------------
  # INPUT VALIDATION
  # -------------------------------------------------------------------------
  
  message(
    "Calculating thermal time summation for phenological observations...\n",
    "Data source: ", class(pheno_data)[1], " with ",
    nrow(pheno_data), " observations"
  )
  
  # Check required attributes in spatial data
  required_attrs <- c("STATION", "GRID_ID", "YEAR", "PLANT", "PHASE", 
                      "DATE", "DOY", "DOY_START")
  missing_attrs <- setdiff(required_attrs, names(pheno_data@data))
  
  if (length(missing_attrs) > 0) {
    stop(
      "Missing required attributes in pheno_data@data: ",
      paste(missing_attrs, collapse = ", "),
      "\nExpected from couple_phenology_stations(): ",
      paste(required_attrs, collapse = ", ")
    )
  }
  
  # Verify gridded_climate is data.frame or suitable format
  if (!is.data.frame(gridded_climate) && !is(gridded_climate, "SpatialDataFrame")) {
    stop(
      "gridded_climate must be data.frame or SpatialDataFrame. ",
      "Received: ", class(gridded_climate)[1]
    )
  }
  
  # -------------------------------------------------------------------------
  # CROP CLASSIFICATION
  # -------------------------------------------------------------------------
  
  # Extract unique crop and phase from phenological data
  crop <- unique(pheno_data@data$PLANT)[1]
  phase <- unique(pheno_data@data$PHASE)[1]
  
  message("Crop ID: ", crop, " | Phase ID: ", phase)
  
  # Define crop groups
  winter_crops <- c(202, 203, 204, 205)
  summer_crops <- c(201, 207, 208, 209, 215, 231, 232, 233, 234, 250, 252, 253)
  
  # -------------------------------------------------------------------------
  # BASE TEMPERATURE SELECTION (Reusability & Interoperability)
  # -------------------------------------------------------------------------
  
  if (use_base_temperature) {
    
    # Assign crop-specific base temperature (Tb) in °C
    # Note: DWD convention uses Temp × 10, so Tb is also multiplied by 10
    if (crop %in% c(202, 203, 204, 207, 208, 215)) {
      Tb <- 5.5  # Winter cereals, spring barley, maize
    } else if (crop == 205) {
      Tb <- 5.0  # Winter rapeseed
    } else if (crop == 201 || crop == 299) {
      Tb <- 2.0  # Grassland and forage crops
    } else if (crop == 209) {
      Tb <- 6.0  # Sunflower
    } else if (crop %in% c(250, 252, 253)) {
      Tb <- 3.0  # Root crops (beet family)
    } else if (crop < 200) {
      Tb <- 0.0  # Extensive grassland
    } else if (crop > 300 && crop < 400) {
      Tb <- 0.0  # Fruits and vegetables
    } else if (crop > 400) {
      Tb <- 10.0  # Special crops
    } else {
      Tb <- 5.0  # Default for unmapped crops
    }
    
    # Scale Tb by 10 to match DWD temperature convention
    Tb_scaled <- Tb * 10
    
    message(
      "Base temperature selection: Tb = ", Tb, "°C ",
      "(scaled: ", Tb_scaled, " per DWD convention)"
    )
    
  } else {
    
    Tb_scaled <- 0
    message("Using raw temperature sum (no base temperature applied)")
  }
  
  # -------------------------------------------------------------------------
  # DATA PREPARATION: Geographic coordinates and spatial standardization
  # -------------------------------------------------------------------------
  
  message("Transforming coordinates to WGS84 (EPSG:4326)...")
  
  # Extract coordinates in WGS84 (lon, lat)
  coords_wgs84 <- data.frame(
    coordinates(
      sp::spTransform(
        pheno_data,
        sp::CRS("+proj=longlat +datum=WGS84")
      )
    )
  )
  colnames(coords_wgs84) <- c("LON", "LAT")
  
  # Reconstruct pheno_data attributes with standardized columns
  pheno_data@data <- data.frame(
    LON = coords_wgs84$LON,
    LAT = coords_wgs84$LAT,
    GRID_ID = pheno_data@data$GRID_ID,
    STATION = pheno_data@data$STATION,
    ID = seq_len(nrow(pheno_data)),
    YEAR = pheno_data@data$YEAR,
    PLANT = pheno_data@data$PLANT,
    PHASE = pheno_data@data$PHASE,
    DATE = pheno_data@data$DATE,
    DOY = pheno_data@data$DOY,
    DOY_START = pheno_data@data$DOY_START,
    stringsAsFactors = FALSE
  )
  
  # -------------------------------------------------------------------------
  # SPATIAL MERGING: Phenology + gridded climate data
  # -------------------------------------------------------------------------
  
  message("Merging phenological observations with gridded climate data...")
  
  # Merge on GRID_ID to align spatial grid cells
  temps_pheno <- merge(pheno_data, gridded_climate, by = "GRID_ID")
  
  if (nrow(temps_pheno) == 0) {
    stop(
      "Merge resulted in 0 rows. Check GRID_ID consistency between ",
      "pheno_data and gridded_climate."
    )
  }
  
  message(
    "Merged: ", nrow(temps_pheno), " observations matched to grid cells"
  )
  
  # -------------------------------------------------------------------------
  # IDENTIFY TEMPERATURE COLUMNS (Interoperability)
  # -------------------------------------------------------------------------
  
  # Temperature columns start after original pheno_data columns
  col_start_temp <- length(pheno_data@data) + 1
  col_end <- length(temps_pheno@data)
  cols_temperature <- col_start_temp:col_end
  
  # Verify temperature columns exist
  if (length(cols_temperature) == 0) {
    stop(
      "No temperature columns detected. Expected columns named T1, T2, ..., or ",
      "T-365, T-364, ..., T0, T1, ... from fLoadTemp()."
    )
  }
  
  message(
    "Temperature columns: ", length(cols_temperature), " daily values detected"
  )
  
  # -------------------------------------------------------------------------
  # APPLY BASE TEMPERATURE SUBTRACTION (Reusability)
  # -------------------------------------------------------------------------
  
  message("Subtracting base temperature from daily values...")
  
  temps_pheno@data[, cols_temperature] <- (
    temps_pheno@data[, cols_temperature] - Tb_scaled
  )
  
  # -------------------------------------------------------------------------
  # PHOTOPERIOD ADJUSTMENT (Reusability & Interoperability)
  # -------------------------------------------------------------------------
  
  message("Applying daylength weighting for photoperiod adjustment...")
  
  # Extract daylength for each grid cell and DOY
  daylengths_grid <- temps_pheno[, cols_temperature]
  latitudes <- temps_pheno$LAT
  
  # Calculate daylength for each temperature column
  for (i in seq_len(ncol(daylengths_grid))) {
    
    # Extract DOY from column name (e.g., "T123" → 123, "T-50" → -50)
    col_name <- names(daylengths_grid)[i]
    doy_value <- as.numeric(substr(col_name, start = 2, stop = 5))
    
    # Handle negative DOY (previous year)
    if (doy_value < 0) {
      doy_value <- 366 + doy_value
    }
    
    # Calculate daylength (hours) for this DOY and latitude
    # geosphere::daylength returns in hours
    daylengths_grid@data[, i] <- geosphere::daylength(latitudes, doy_value)
  }
  
  # Apply daylength weighting: Temp_adjusted = Temp × (Daylength / 24)
  temps_pheno@data[, cols_temperature] <- (
    daylengths_grid@data / 24 * temps_pheno@data[, cols_temperature]
  )
  
  message("Daylength adjustment applied")
  
  # -------------------------------------------------------------------------
  # TRUNCATE NEGATIVE VALUES (Reusability)
  # -------------------------------------------------------------------------
  
  # Set all negative values to 0 (GDD constraint)
  # Growing degree-days never negative by definition
  temps_pheno@data[temps_pheno@data < 0] <- 0
  
  message("Negative values truncated to 0 (GDD constraint)")
  
  # -------------------------------------------------------------------------
  # HANDLE WINTER CROP TEMPORAL LOGIC (Reusability)
  # -------------------------------------------------------------------------
  
  if (crop %in% winter_crops && !(phase %in% c(12, 14))) {
    
    message(
      "Winter crop (ID ", crop, ") detected: ",
      "Adjusting DOY_START for multi-year temporal alignment"
    )
    
    # For winter crops, DOY_START references previous year (negative indices)
    # Rescale: DOY_START = -366 + original_DOY_START
    # This converts previous year reference to searchable column index
    temps_pheno$DOY_START <- -366 + temps_pheno$DOY_START
  }
  
  # Special case: Phase 10 (Sowing) for winter crops
  if (phase == 10) {
    message("Phase 10 (Sowing) detected: Setting DOY_START = 1")
    temps_pheno$DOY_START <- 1
  }
  
  # Cap DOY at 365 to handle leap year edge cases
  temps_pheno$DOY <- pmin(temps_pheno$DOY, 365)
  
  # -------------------------------------------------------------------------
  # FILTER VALID OBSERVATIONS (Reusability)
  # -------------------------------------------------------------------------
  
  # Keep only observations where DOY > DOY_START (meaningful vegetation period)
  valid_obs <- which(temps_pheno$DOY > temps_pheno$DOY_START)
  
  temps_pheno <- temps_pheno[valid_obs, ]
  
  message(
    "Valid observations (DOY > DOY_START): ", nrow(temps_pheno),
    " of original ", nrow(pheno_data)
  )
  
  # -------------------------------------------------------------------------
  # CALCULATE THERMAL TIME SUMS (Reusability)
  # -------------------------------------------------------------------------
  
  message("Calculating cumulative thermal time (GDD) by row...")
  
  # Initialize thermal sum vector
  thermal_sums <- numeric(nrow(temps_pheno))
  
  # Row-wise summation from DOY_START to DOY
  for (i in seq_len(nrow(temps_pheno))) {
    
    col_start_doy <- paste0("T", temps_pheno$DOY_START[i])
    col_end_doy <- paste0("T", temps_pheno$DOY[i])
    
    # Find column indices
    idx_start <- which(names(temps_pheno) == col_start_doy)
    idx_end <- which(names(temps_pheno) == col_end_doy)
    
    # Calculate sum across columns
    if (length(idx_start) > 0 && length(idx_end) > 0) {
      thermal_sums[i] <- sum(
        temps_pheno@data[i, idx_start:idx_end],
        na.rm = TRUE
      )
    } else {
      thermal_sums[i] <- NA
    }
  }
  
  # Append thermal sum to data frame
  temps_pheno@data$T_SUMS <- thermal_sums
  
  message(
    "Thermal sums calculated. ",
    "Mean GDD: ", round(mean(thermal_sums, na.rm = TRUE), 1),
    " | Range: [",
    round(min(thermal_sums, na.rm = TRUE), 1), ", ",
    round(max(thermal_sums, na.rm = TRUE), 1), "]"
  )
  
  # -------------------------------------------------------------------------
  # RETURN VALUE (Reusability)
  # -------------------------------------------------------------------------
  
  message(
    "Thermal time calculation complete. ",
    "Output: SpatialPointsDataFrame with ",
    nrow(temps_pheno), " observations and T_SUMS column\n"
  )
  
    # Return enhanced spatial data frame invisibly
  invisible(temps_pheno)
}

################################################################################
# USAGE EXAMPLE
# ==============================================================================
# Workflow for Winter Wheat (202) GDD calculation
# library(sp)
# library(geosphere)
#
# # Step 1: Download phenology data
# pheno_raw <- download_dwd_phenology(crop = 202, combine = TRUE)
#
# # Step 2: Spatial merging with stations
# stations_wheat <- couple_phenology_stations(
#   pheno_data = pheno_raw,
#   input_dir = "./data/",
#   station_shapefile = "PHENO_STATION_EPSG31467",
#   target_phase = 18,
#   crop = 202,
#   observation_year = 2024,
#   remove_outliers = TRUE
# )
#
# # Step 3: Load temperature data aligned with vegetation period
# temps_wheat <- load_gridded_temperature(
#   pheno_data = stations_wheat,
#   input_dir = "./data/",
#   parameter = "tmit_",
#   year = 2024
# )
#
# # Step 4: Calculate GDD with crop-specific base temperature
# gdd_wheat <- effective_temperature_calculation(
#   gridded_climate = temps_wheat,
#   pheno_data = stations_wheat,
#   use_base_temperature = TRUE
# )

################################################################################
# END OF FILE
################################################################################
