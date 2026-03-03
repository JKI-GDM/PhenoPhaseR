################################################################################
# Merge DWD phenological observations with spatial station information
################################################################################
#
# PURPOSE:
#   Merge phenological observations from function download_dwd_phenology() 
#   with spatial station information, handling temporal logic for winter vs. 
#   summer crops, removing outliers, and returning spatial objects 
#   (SpatialPointsDataFrame) with complete observation history for a given crop, 
#   phase, and year.
#
# AUTHORS:
#   Markus Möller
#   ORCID: https://orcid.org/0000-0002-1918-7747
#   Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#   Henning Gerstmann
#   Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/

# DATA SOURCE:
#   Input: Phenological observations (from download_dwd_phenology)
#          and station shapefile (from data folder)
#   URL: https://opendata.dwd.de/climate_environment/CDC/observations_germany/phenology/
#   License: CC BY 4.0 (Creative Commons Attribution 4.0 International)
#
# DEPENDENCIES:
#   - R >= 4.0.0
#   - sp (for spatial data handling)
#   - raster (for shapefile operations)
#
# VERSION HISTORY:
#   v1.0.0 (2025-12-11): Initial release
#
# CITATION:
#   If you use this code in your research, please cite:
#   Möller, M. & Gerstmann, H. (2025). couple_phenology_sdtations: DWD phenology station-phase coupling tool.
#   Available at: [repository URL - add when published]
#
# LICENSE:
#   This code is provided under the MIT License
#
################################################################################

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================
#
# ARGUMENTS:
#   input_dir (character):
#     - Full path to directory containing phenological station shapefile
#     - Station shapefile must have column "STATION" matching pheno_data$STATION
#     - Supports standard ESRI shapefiles (.shp, .dbf, .shx, etc.)
#
#   station_shapefile (character):
#     - File name of phenological station shapefile (without .shp extension)
#     - Example: "DWD_Phenology_Stations_2025"
#     - Located in input_dir
#
#   target_phase (numeric):
#     - DWD phenological phase ID to analyze (e.g., 10 = sowing, 25 = heading)
#     - Must be present in pheno_data$PHASE
#     - See https://opendata.dwd.de/climate_environment/CDC/observations_germany/phenology/
#
#   plant (numeric):
#     - DWD crop identifier (e.g., 202 = Winter wheat)
#     - Must be present in pheno_data$PLANT
#     - Critical for determining temporal logic (winter vs. summer crops)
#     - Winter crops (202, 203, 204, 205): sowing date from previous year
#     - Summer crops (201,207, 208, 209, 215, 231-234, 250, 252, 253): sowing date from current year
#
#   observation_year (numeric):
#     - Calendar year for the target phase observation
#     - For winter crops, start date retrieved from observation_year - 1
#     - Affects which records are selected from function download_dwd_phenology()
#
#   start_phase (numeric, default = 10):
#     - Reference phenological phase for temporal summation baseline
#     - Typically sowing phase (10), but can be customized
#     - Used to calculate Growing Degree Days (GDD) from start to target phase
#
#   start_doy (numeric, default = 1):
#     - Start day-of-year if start_phase is not found in data
#     - Default 1 = January 1st
#     - Allows handling of missing start phase data
#
#   remove_outliers (logical, default = TRUE):
#     - If TRUE: removes outliers using Interquartile Range (IQR) criterion
#     - IQR method: keeps observations within [Q1 - 1.5*IQR, Q3 + 1.5*IQR]
#     - If FALSE: retains all valid observations (not recommended)
#
#   output_dir (character, optional):
#     - Path to directory for saving output shapefile
#     - If provided, writes [plant]-[phase]_[year].shp
#     - If NULL or missing, no file saved (only returns object)
#
# RETURNS:
#   SpatialPointsDataFrame (from sp package):
#     - Spatial object with merged phenology + station data
#     - Columns include:
#       * STATION: Station ID
#       * DOY:     Day of year for target phase
#       * DOY_START: Day of year for start phase (reference)
#       * YEAR:    Observation year
#       * PHASE:   Target phase ID
#       * PLANT:   Crop ID
#       * [geometry]: Geographic coordinates (longitude, latitude)
#     - Rows represent individual stations with valid observations
#     - Sorted by STATION ID
#
# SIDE EFFECTS:
#   1. If output_dir provided: writes shapefile to
#      [output_dir]/DOY_[plant]-[target_phase]_[observation_year].shp
#      (with accompanying .dbf, .shx, .prj files)
#
#   2. Console messages: reports processing steps, crop type, output location
#
# CROP TYPE LOGIC:
#   Winter crops (sow in autumn):
#     - Codes: 202 (Winter wheat), 203 (Winter rye),
#              204 (Winter barley), 205 (Winter rapeseed)
#     - Sowing date retrieved from YEAR - 1
#     - DOY_START reflects previous calendar year
#     - Example: 2024 harvest → sowing in autumn 2023 (DOY from 2023)
#
#   Summer crops (sow in spring):
#     - Codes: 207 (Summer barley), 208 (Oat), 209 (Sunflower),
#              215 (Maize), 231-234 (Patato), 250/252/253 (Sugar beet)
#     - Sowing date retrieved from YEAR (same calendar year)
#     - DOY_START reset to start_doy if phase not found
#     - Example: 2024 harvest → sowing in spring 2024
#
# OUTLIER REMOVAL DETAILS:
#   - Q1: First quartile (25th percentile) of DOY values
#   - Q3: Third quartile (75th percentile) of DOY values
#   - IQR = Q3 - Q1 (interquartile range, robust to skewness)
#   - Outlier bounds: [Q1 - 1.5*IQR, Q3 + 1.5*IQR]
#   - Removes ~0.7% of normally distributed data
#   - Common in statistical outlier detection (e.g., box plots)
#
# ERRORS & WARNINGS:
#   - Warning: "Winter crop: Start DOY in previous year" (informational)
#   - Error if STATION column missing in phenology data
#   - Error if station shapefile not found in input_dir
#   - Error if no valid stations after merging (check filters/data)
#
# SPATIAL REFERENCE SYSTEM:
#   - Output SpatialPointsDataFrame inherits CRS from input station shapefile
#   - Coordinates represent meteorological station locations
#
# Inspect spatial data
#   str(stations_winter_wheat)
#   plot(stations_winter_wheat)
#   head(stations_winter_wheat@data)
#
# ==============================================================================

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
# DEPENDENCY LOADING
# ==============================================================================
ensure_packages(c("ggplot2",
                  "rnaturalearth",
                  "sf"))


# ==============================================================================
# MAIN FUNCTION
# ==============================================================================
couple_phenology_stations <- function(
    input_dir,
    station_shapefile,
    target_phase,
    plant,
    observation_year,
    start_phase = 10,
    start_doy = 1,
    remove_outliers = TRUE,
    output_dir = NULL
) {
  
  # ---------------------------------------------------------------------------
  # INPUT VALIDATION
  # ---------------------------------------------------------------------------
  
  message("Coupling phenological observations with meteorological stations")
  
  # Check required columns in phenology data
  required_cols <- c("STATION", "PHASE", "YEAR", "PLANT", "DOY", "DATE")
  missing_cols <- setdiff(required_cols, names(pheno_data))
  if (length(missing_cols) > 0) {
    stop(
      "Missing required columns in pheno_data: ",
      paste(missing_cols, collapse = ", "),
      "\nExpected columns (from fDownloadDwdPhenology): ",
      paste(required_cols, collapse = ", ")
    )
  }
  
  # ---------------------------------------------------------------------------
  # Load station shapefile
  # ---------------------------------------------------------------------------
  
  message("Loading phenological station shapefile...")
  
  # Construct full path to shapefile
  station_file <- file.path(input_dir, station_shapefile)
  
  # Import shapefile using raster/sp packages
  # This preserves spatial reference system (CRS)
  stations <- raster::shapefile(station_file)
  
  # Import phenological observations from function download_dwd_phenology()
  pheno_data <- read.csv2(file.path(output_dir,paste0(plant,"_annual.txt")))
  # Ensure STATION column is numeric for merging
  pheno_data$STATION <- as.numeric(pheno_data$STATION)
  
  # ---------------------------------------------------------------------------
  # DATA FILTERING: Select relevant phases and years
  # ---------------------------------------------------------------------------
  
  # Filter phenology data: keep records for target phase OR start phase
  # This allows calculation of duration between start and target phase
  pheno_filtered <- pheno_data[
    which(pheno_data$PHASE == target_phase | pheno_data$PHASE == start_phase),
  ]
  
  
  # ---------------------------------------------------------------------------
  # CROP-SPECIFIC TEMPORAL LOGIC
  # ---------------------------------------------------------------------------
  
  # Define crop groups:
  # Winter cereals: sown in autumn of previous year
  winter_crops <- c(202, 203, 204, 205)
  # Summer crops: sown in spring of current year
  summer_crops <- c(201, 207, 208, 209, 215, 231, 232, 233, 234, 250, 252, 253)
  
  # Determine if crop is winter type
  is_winter_crop <- is.element(plant, winter_crops)
  
  # Special case: Winter crops at sowing phase (phase 10)
  # Sowing always occurs in previous calendar year
  if (is.element(plant, winter_crops) &
      is.element(target_phase, c(10))) {
    
    message("Winter crop at sowing phase: using data from year ", observation_year)
    
    # Select sowing data from previous year for winter crops
    pheno_filtered <- pheno_filtered[
      which(pheno_filtered$PHASE == start_phase &
              pheno_filtered$YEAR == observation_year),
    ]
    
    # Set reference start DOY manually
    pheno_filtered$DOY_START <- start_doy
    
    # Remove duplicate stations (keep first occurrence)
    stations <- stations[!duplicated(stations$STATION), ]
    
    # Merge station attributes with phenology data
    stations <- sp::merge(
      stations,
      pheno_filtered,
      by = "STATION",
      all.x = FALSE,
      duplicateGeoms = TRUE,
      no.dups = FALSE
    )
    
    message("Merged with target phase data (n = ", nrow(stations), " stations)")
    
  } else {
    
    # General case: most observations (non-sowing winter crops, summer crops)
    
    # Determine temporal reference for start DOY
    is_winter_winter <- is.element(plant, winter_crops) &
      !is.element(target_phase, c(12, 14))
    
    message(
      "Winter crop with non-sowing phase: ",
      "Start DOY from previous year -> ",
      is_winter_winter
    )
    
    # ---------------------------------------------------------------------------
    # START PHASE EXTRACTION
    # ---------------------------------------------------------------------------
    
    if (is_winter_winter) {
      # Winter crops: get start date from previous year
      message("Extracting start phase from year ", observation_year - 1)
      
      pheno_start <- pheno_filtered[
        which(pheno_filtered$PHASE == start_phase &
                pheno_filtered$YEAR == observation_year - 1),
      ]
      
    } else {
      # Summer crops or when start phase not found: get from current year
      message("Extracting start phase from year ", observation_year)
      
      if (!is.element(start_phase, pheno_filtered$PHASE)) {
        # Start phase not available: create synthetic entry with start_doy
        message("Start phase ", start_phase, " not found in data. Using start_doy = ",
                start_doy)
        
        pheno_start <- pheno_filtered
        pheno_start$DOY <- start_doy
        
      } else {
        # Start phase found: use it as reference
        pheno_start <- pheno_filtered[
          which(pheno_filtered$PHASE == start_phase &
                  pheno_filtered$YEAR == observation_year),
        ]
      }
    }
    
    # Rename DOY column to DOY_START for clarity
    colnames(pheno_start)[which(names(pheno_start) == "DOY")] <- "DOY_START"
    
    # ---------------------------------------------------------------------------
    # TARGET PHASE EXTRACTION
    # ---------------------------------------------------------------------------
    
    # Select observations for target phase in specified year
    pheno_target <- pheno_filtered[
      which(pheno_filtered$PHASE == target_phase &
              pheno_filtered$YEAR == observation_year),
    ]
    
    message("Extracted ", nrow(pheno_target), " target phase observations")

    # ---------------------------------------------------------------------------
    # MATCHING: Keep only stations with both start and target data 
    # ---------------------------------------------------------------------------
    
    # Use station ID matching to create aligned datasets
    # match() returns indices; nomatch=0 returns 0 for non-matches (excluded)
    pheno_start_matched <- pheno_start[
      match(pheno_target$STATION, pheno_start$STATION, nomatch = 0),
    ]
    
    pheno_target_matched <- pheno_target[
      match(pheno_start_matched$STATION, pheno_target$STATION, nomatch = 0),
    ]
    
    # Remove any duplicate stations (keep first occurrence only)
    pheno_target_dedup <- pheno_target_matched[
      !duplicated(pheno_target_matched$STATION),
    ]
    
    pheno_start_dedup <- pheno_start_matched[
      !duplicated(pheno_start_matched$STATION),
    ]
    
    # Remove duplicates from station shapefile
    # Use sp::remove.duplicates() if available, fallback to base method
    stations <- tryCatch(
      sp::remove.duplicates(stations),
      error = function(e) {
        stations[!duplicated(stations$STATION), ]
      }
    )
    
    message(
      "Matched stations: ", nrow(pheno_target_dedup),
      " stations with both start and target phase data"
    )
    
    # ---------------------------------------------------------------------------
    # SPATIAL MERGING (Interoperability)
    # ---------------------------------------------------------------------------
    
    # Merge station geometry with target phase observations
    stations <- sp::merge(stations, pheno_target_dedup, by = "STATION", all.x = FALSE)
    
    # Merge with start phase DOY data
    stations <- merge(
      stations,
      pheno_start_dedup[, c("STATION", "DOY_START")],
      by = "STATION",
      all.x = FALSE
    )
    
    # Reset start DOY for summer crops (not applicable)
    if (is.element(plant, summer_crops)) {
      message("Summer crop detected: resetting DOY_START to ", start_doy)
      stations$DOY_START <- start_doy
    }
  }
  
  # ---------------------------------------------------------------------------
  # OUTLIER REMOVAL: Interquartile Range (IQR) method (Reusability)
  # ---------------------------------------------------------------------------
  
  if (remove_outliers) {
    
    message("Removing outliers using IQR criterion (1.5 × IQR)...")
    
    # Calculate quartiles and IQR for DOY observations
    Q1 <- quantile(stations$DOY, probs = 0.25, na.rm = TRUE)
    Q3 <- quantile(stations$DOY, probs = 0.75, na.rm = TRUE)
    IQR_val <- IQR(stations$DOY, na.rm = TRUE)
    
    # Define outlier bounds
    lower_bound <- Q1 - 1.5 * IQR_val
    upper_bound <- Q3 + 1.5 * IQR_val
    
    message(
      "DOY range: [", lower_bound, ", ", upper_bound, "] ",
      "(Q1=", Q1, ", Q3=", Q3, ", IQR=", IQR_val, ")"
    )
    
    # Subset to keep only observations within bounds
    n_before <- nrow(stations)
    stations <- subset(
      stations,
      stations$DOY > lower_bound & stations$DOY < upper_bound
    )
    n_removed <- n_before - nrow(stations)
    
    message(
      "Outlier removal: removed ", n_removed, " stations ",
      "(", round(100 * n_removed / n_before, 1), "%)"
    )
    
  } else {
    message("Outlier removal disabled (keeping all observations)")
  }
  
  # ---------------------------------------------------------------------------
  # OUTPUT: Spatial visualization and summary (Accessibility)
  # ---------------------------------------------------------------------------
  message("Final dataset: ", nrow(stations), " stations with valid observations")
  
    # Convert sp object to sf (modern standard)
    stations_sf <- st_as_sf(stations)
    
    # Retrieve Germany background map
    germany <- ne_countries(scale = "medium", country = "Germany", returnclass = "sf")
    
    # Create high-quality map
    p <- ggplot() +
      # Background map
      geom_sf(data = germany, fill = "#f0f0f0", color = "#d0d0d0") +
      # Station points colored by DOY
      geom_sf(data = stations_sf, aes(color = DOY), size = 3, alpha = 0.8) +
      # Color scale (Viridis is colorblind-friendly)
      scale_color_viridis_c(
        option = "viridis", 
        name = "DOY",
        direction = -1 # Darker colors = later dates (optional)
      ) +
      # Labels and Metadata
      labs(
        title = paste("Phenology Stations - Crop", plant),
        subtitle = paste("Phase:", target_phase, "| Year:", observation_year),
        caption = paste("Source: DWD Phenology | n =", nrow(stations_sf)),
        x = NULL, 
        y = NULL
      ) +
      # Theme adjustments
      theme_minimal() +
      theme(
        plot.title = element_text(face = "bold", size = 14),
        plot.subtitle = element_text(size = 14, color = "gray30"),
        text = element_text(size = 14),
        axis.text = element_text(size = 14),
        legend.position = "right",
        panel.grid.major = element_line(color = "gray90", linetype = "dashed")
      )
    
    # Print plot to device
    print(p)
    
    # ---------------------------------------------------------------------------
    # FILE EXPORT
    # ---------------------------------------------------------------------------
    # 1. Save Plot Image
    plot_filename <- paste0(plant, "_", target_phase, "_", observation_year, "_MapObservation.png")
    print(ggsave(
      filename = file.path(output_dir, plot_filename),
      plot = p,
      width = 6, 
      height = 8, 
      dpi = 300,
      bg = "white"
    ))
    
    message("Plot image saved to: ", file.path(output_dir, plot_filename))
    # 2. Save Shapefile (Original functionality)
      output_filename <- paste0("DOY_", plant, "-", target_phase, "_", observation_year, ".shp")
      output_path <- file.path(output_dir, output_filename)
      message("Writing shapefile to: ", output_path)
      raster::shapefile(stations, output_path, overwrite = TRUE)
      return(stations)
}

################################################################################
# USAGE EXAMPLE
# ==============================================================================
## Parametrisize Winter wheat (202) shooting date (phase 15) in 2024
#   stations_winter_wheat <- couple_phenology_stations(
#     input_dir = "./data",
#     station_shapefile = "PHENO_STATION_EPSG31467",
#     target_phase = 15,
#     plant = 202,
#     observation_year = 2024,
#     start_phase = 10,
#     start_doy = 1,
#     remove_outliers = TRUE,
#     output_dir = "./output"
#   )
# ################################################################################
# END OF FILE
# ################################################################################

