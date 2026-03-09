################################################################################
# DWD Phenology Data Download & Visualization Function
################################################################################
#
# PURPOSE:
#   Download, process, and visualize phenological observations from the German
#   Meteorological Service (DWD) Climate Data Centre (CDC). Supports combining
#   recent and historical annual reporter data for agricultural plants.
#
# AUTHORS:
#   Markus Möller
#   ORCID: https://orcid.org/0000-0002-1918-7747
#   Affiliation: Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#   Henning Gerstmann
#   Affiliation: Federal Agency for Nature Conservation (BfN); https://www.bfn.de/

#
# DATA SOURCE:
#   DWD Climate Data Centre - Phenology Data
#   URL: https://opendata.dwd.de/climate_environment/CDC/observations_germany/phenology/
#   License: CC BY 4.0 (Creative Commons Attribution 4.0 International)
#   Reference: Deutscher Wetterdienst (DWD), 2026
#
# DEPENDENCIES:
#   - R >= 4.0.0
#   - ggplot2 (for visualization)
#
# VERSION HISTORY:
#   v1.0.0 (2025-12-11): Initial release
#
# CITATION:
#   If you use this code in your research, please cite:
#   Möller, M. & Gerstmann, H. (2025). download_dwd_phenology: DWD phenology data download tool.
#   Available at: [repository URL - add when published]
#
# LICENSE:
#   This code is provided under the MIT License
#
################################################################################

# ==============================================================================
# FUNCTION 1: ensure_packages()
# ==============================================================================
#
# PURPOSE:
#   Automatically check for required packages and install them if missing.
#   This ensures reproducibility and reduces setup errors.
#
# ARGUMENTS:
#   pkg_list (character): Vector of package names to check/install
#
# RETURNS:
#   Invisibly returns TRUE; primarily used for side effects (loading packages)
#
# NOTES:
#   - Suppresses verbose output for cleaner console messages
#   - Respects user preferences for package installation
#   - Compatible with CRAN and GitHub-hosted packages (via install.packages)
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
# Ensure ggplot2 is available before running main function
# This follows FAIR principle: code should be self-documenting and functional

ensure_packages(c("ggplot2"))

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================
#
# PURPOSE:
#   Main function to download DWD phenology data for a specific plant,
#   optionally combine recent and historical datasets, and generate
#   exploratory visualization showing temporal and phenological patterns.
#
# ARGUMENTS:
#   plant (character or numeric):
#     - DWD plant identifier (e.g., "201" for "Dauergruenland", "231" for "Kartoffel")
#     - See plant_map for complete list of valid IDs
#     - Numeric input is coerced to character
#
#   output_dir (character):
#     - Full path to directory where outputs should be saved
#     - Directory must exist and be writable
#     - Outputs: [plant]_annual.txt (data) and [plant]_annual.png (plot)
#
#   combine (logical, default = TRUE):
#     - If TRUE: Downloads and combines both "recent" and "historical" datasets
#     - If FALSE: Downloads only "recent" dataset
#     - Deduplication applied after combining
#
# RETURNS:
#   pheno_data (data.frame):
#     - Standardized phenology observations with columns:
#       * QL:     Quality level (Qualitätsniveau)
#       * STATION: Meteorological station ID (Stations_id)
#       * YEAR:    Reference year (Referenzjahr)
#       * PLANT:   plant object ID (Objekt_id)
#       * PHASE:   Phenological phase ID (Phase_id)
#       * DATE:    Observation date (Eintrittsdatum, format: YYYYMMDD)
#       * QF:      Quality flag for date (Eintrittsdatum_QB)
#       * DOY:     Day of year (Julian day, Jultag)
#     - Rows represent individual observations
#     - No duplicates retained
#
# SIDE EFFECTS:
#   1. Writes data to: [output_dir]/[plant]_annual.txt
#      Format: semicolon-delimited text file with header
#      Encoding: UTF-8 (recommended for special characters in plant names)
#
#   2. Creates plot: [output_dir]/[plant]_annual.png
#      Format: PNG raster image, 1500 x 1200 px @ 300 dpi
#      Content: Bubble plot showing year vs. phase relationships
#               Bubble size indicates observation count per year-phase combination
#               X-axis: Year (5-year intervals for readability)
#               Y-axis: Phenological phase ID
#               Alpha = 0.1 for transparency to reveal overlapping observations
#
# ERRORS & WARNINGS:
#   - Error if plant not found in plant_map (lists valid IDs)
#   - Error if no data downloaded for specified plant/directories
#   - Warning if data missing for specific directory (rare)
#   - Network errors propagate; ensure stable internet connection
#
# METADATA REFERENCE:
#   German plant names and phase codes documented in:
#   - PH_Beschreibung_Pflanze.txt (plant codebook)
#   - PH_Beschreibung_Phase.txt (phase codebook)
#   Available from: https://opendata.dwd.de/climate_environment/CDC/observations_germany/phenology/
#

# ==============================================================================

download_dwd_phenology <- function(
    plant,
    output_dir,
    combine = TRUE
) {
  
  # ---------------------------------------------------------------------------
  # SETUP: URL and Plant Mapping (Interoperability)
  # ---------------------------------------------------------------------------
  
  # Base URL for DWD Climate Data Centre phenology data
  # This endpoint provides machine-readable directory listings
  base_url <- "https://opendata.dwd.de/climate_environment/CDC/observations_germany/phenology/annual_reporters/crops"
  
  # Mapping between numeric plant IDs and DWD German plant names
  # Source: PH_Beschreibung_Pflanze.txt from DWD CDC
  # Note: German names are required to construct correct file paths on DWD server
  # This mapping ensures reproducible queries across different systems
  plant_map <- c(
    "201" = "Dauergruenland",              # Permanent grassland
    "202" = "Winterweizen",                # Winter wheat
    "203" = "Winterroggen",                # Winter rye
    "204" = "Wintergerste",                # Winter barley
    "205" = "Winterraps",                  # Winter rapeseed
    "206" = "Sommerweizen",                # Spring wheat
    "207" = "Sommergerste",                # Spring barley
    "208" = "Hafer",                       # Oats
    "209" = "Sonnenblume",                 # Sunflower
    "210" = "Mais_ohne_Sortenangabe",      # Maize (unspecified variety)
    "211" = "Mais_fruehe_Reife",           # Maize (early maturity)
    "212" = "Mais_mittelfruehe_Reife",     # Maize (medium-early maturity)
    "213" = "Mais_mittelspaete_Reife",     # Maize (medium-late maturity)
    "214" = "Mais_spaete_Reife",           # Maize (late maturity)
    "215" = "Mais",                        # Maize (generic)
    "231" = "Kartoffel",                   # Potato
    "232" = "Fruehkartoffel_vorgekeimt",   # Early potato (pre-sprouted)
    "233" = "Fruehkartoffel_nicht_vorgekeimt", # Early potato (non-pre-sprouted)
    "234" = "Spaetkartoffel",              # Late potato
    "241" = "Gruenpflueck-Bohne",          # Green bean
    "242" = "Gruenpflueck-Erbse",          # Green pea
    "243" = "Tomate",                      # Tomato
    "244" = "Weisskohl",                   # White cabbage
    "245" = "Luzerne",                     # Lucerne/Alfalfa
    "246" = "Rotklee",                     # Red clover
    "250" = "Rueben_ohne_Sortenangabe",    # Beet (unspecified variety)
    "252" = "Futter-Ruebe",                # Fodder beet
    "253" = "Zucker-Ruebe"                 # Sugar beet
  )
  
  # ---------------------------------------------------------------------------
  # VALIDATION: Check plant validity (Reusability)
  # ---------------------------------------------------------------------------
  
  # Look up plant name from ID; returns NA if not found
  plant_name <- plant_map[as.character(plant)]
  
  # Validate that plant exists; stop with informative error if not
  # This prevents silent failures and aids troubleshooting
  if (is.na(plant_name)) {
    stop(
      "Unknown plant: ", plant, ". Use one of: ",
      paste(names(plant_map), collapse = ", ")
    )
  }
  
  # ---------------------------------------------------------------------------
  # CONFIGURATION: Dataset selection (Reusability)
  # ---------------------------------------------------------------------------
  
  # Determine which DWD dataset directories to query based on 'combine' parameter
  # - "recent": current/recent observations (typically last 1-5 years)
  # - "historical": archived long-term observations (often 30+ years)
  if (combine) {
    # Combine both recent and historical for complete time series
    dirs <- c("recent", "historical")
  } else {
    # Use only recent data (e.g., for quick updates)
    dirs <- "recent"
  }
  
  # ---------------------------------------------------------------------------
  # DATA DOWNLOAD: Iterative retrieval from DWD CDC (Accessibility)
  # ---------------------------------------------------------------------------
  
  # Initialize list to store downloaded datasets
  # Using list allows flexible handling of 1-2 datasets before combining
  data_list <- list()
  
  # Loop through each dataset directory
  for (dir in dirs) {
    # Construct directory URL
    url <- paste0(base_url, "/", dir, "/")
    
    # Read HTML directory listing from DWD server
    # This provides file names and metadata about available datasets
    idx <- readLines(url, warn = FALSE)
    
    # Construct regex pattern to identify the correct file for this plant
    # Pattern format: "PH_Jahresmelder_Landwirtschaft_Kulturpflanze_[plant_name]*.txt"
    # Example: "PH_Jahresmelder_Landwirtschaft_Kulturpflanze_Dauergruenland_*.txt"
    pattern <- sprintf(
      "PH_Jahresmelder_Landwirtschaft_Kulturpflanze_%s.*\\.txt",
      plant_name
    )
    
    # Extract file name from HTML href attributes using regex matching
    # This robust approach handles various HTML formatting variations
    file_name <- sub(
      ".*href=\"([^\"]+)\".*",
      "\\1",
      grep(pattern, idx, value = TRUE, ignore.case = TRUE)
    )[1]  # [1] selects first match if multiple files found
    
    # Check if file was found; warn and skip if not
    # This allows partial data retrieval if one dataset is unavailable
    if (is.na(file_name)) {
      warning(
        "No file found for plant: ", plant, " (",
        plant_name, ") in ", dir
      )
      next
    }
    
    # Construct full URL to the specific data file
    file_url <- paste0(url, file_name)
    
    # Create temporary file for download
    # Using tempfile() ensures cleanup and avoids conflicts with existing files
    temp_file <- tempfile(fileext = ".txt")
    
    # Download data file from DWD server to temporary location
    # mode = "wb" ensures binary download (handles encoding correctly)
    # quiet = TRUE suppresses progress messages for cleaner output
    utils::download.file(
      file_url,
      destfile = temp_file,
      mode = "wb",
      quiet = TRUE
    )
    
    # Inform user of successful download
    message("Downloaded (", dir, "): ", file_name)
    
    # Read downloaded file into R data frame
    # sep = ";" matches DWD format (German locale uses semicolon)
    # stringsAsFactors = FALSE keeps columns as character (prevents auto-conversion)
    data_list[[dir]] <- read.table(
      temp_file,
      header = TRUE,
      sep = ";",
      stringsAsFactors = FALSE
    )
    
    # Clean up temporary file
    file.remove(temp_file)
  }
  
  # ---------------------------------------------------------------------------
  # DATA COMBINATION: Merge datasets and remove duplicates (Interoperability)
  # ---------------------------------------------------------------------------
  
  # Combine datasets based on 'combine' parameter and available data
  if (combine && length(data_list) > 1) {
    # Combine recent and historical data into single data frame
    # rbind stacks rows; order is [recent, historical]
    pheno_data <- do.call("rbind", data_list)
    
    # Remove duplicate rows (rows identical across all columns)
    # This handles overlaps between recent and historical datasets
    # which may contain same observations updated with newer flags
    pheno_data <- pheno_data[!duplicated(pheno_data), ]
    
  } else if (length(data_list) > 0) {
    # Use single dataset if combination not requested or only one available
    pheno_data <- data_list[[1]]
    
  } else {
    # Fail gracefully if no data was downloaded
    stop("No data downloaded. Check plant and availability.")
  }
  
  # ---------------------------------------------------------------------------
  # DATA STANDARDIZATION: Rename columns for consistency (Findability)
  # ---------------------------------------------------------------------------
  
  # Create new data frame with standardized English column names
  # This improves accessibility for international users
  # German → English mapping:
  pheno_data <- data.frame(
    QL     = pheno_data$Qualitaetsniveau,   # Quality level
    STATION = pheno_data$Stations_id,       # Station ID
    YEAR   = pheno_data$Referenzjahr,       # Reference year
    PLANT  = pheno_data$Objekt_id,          # Plant/crop object ID
    PHASE  = pheno_data$Phase_id,           # Phenological phase ID
    DATE   = pheno_data$Eintrittsdatum,     # Occurrence date (YYYYMMDD)
    QF     = pheno_data$Eintrittsdatum_QB,  # Quality flag
    DOY    = pheno_data$Jultag              # Day of year (Julian day)
  )
  
  # Remove any remaining duplicate rows (final deduplication)
  pheno_data <- pheno_data[!duplicated.data.frame(pheno_data), ]
  
  # ---------------------------------------------------------------------------
  # OUTPUT 1: Data Export (Accessibility & Findability)
  # ---------------------------------------------------------------------------
  
  # Construct output file path for data export
  output_file <- file.path(output_dir, paste0(plant, "_annual.txt"))
  
  # Export standardized data to text file
  # This allows data to be used in other applications/analyses
  # sep = ";" matches DWD format convention
  # row.names = FALSE omits row indices (not needed)
  # col.names = TRUE includes header row (essential for data documentation)
  write.table(
    pheno_data,
    output_file,
    row.names = FALSE,
    col.names = TRUE,
    sep = ";"
  )
  
  # Confirm export to user
  message("Data exported to: ", output_file)
  
  # ---------------------------------------------------------------------------
  # EXPLORATORY ANALYSIS: Aggregate data for visualization (Reusability)
  # ---------------------------------------------------------------------------
  
  # Create contingency table: count observations per year-phase combination
  # This aggregation enables pattern visualization
  year_counts <- as.data.frame(table(pheno_data$YEAR, pheno_data$PHASE))
  
  # Rename aggregated columns for clarity
  names(year_counts) <- c("YEAR", "PHASE", "N")
  
  # Convert YEAR to numeric (table() converts to factor)
  # This is necessary for proper x-axis plotting
  year_counts$YEAR <- as.numeric(as.character(year_counts$YEAR))
  
  # ---------------------------------------------------------------------------
  # OUTPUT 2: Visualization - Bubble plot (Reusability & Findability)
  # ---------------------------------------------------------------------------
  
  # Construct output file path for visualization
  output_plot <- file.path(output_dir, paste0(plant, "_PlotObservations.png"))
  
  # Open PNG graphics device for output
  # Specifications chosen for publication-ready quality:
  # - width/height: 1500 x 1200 pixels
  # - res = 300 dpi: suitable for print (150 dpi for web, 300 dpi for publications)
  # - This creates a ~5 x 4 inch figure at 300 dpi
  png(output_plot, width = 1500, height = 1200, res = 300)
  
  # Create ggplot2 bubble chart
  # Visualization parameters:
  # - x-axis: Year (temporal dimension)
  # - y-axis: Phenological phase (biological dimension)
  # - bubble size: Count of observations (data density)
  # This reveals temporal patterns, data availability, and phenological trends
  print(
    ggplot(year_counts, aes(x = YEAR, y = PHASE, size = N)) +
      # Draw points (bubbles) with transparency to show overlapping values
      geom_point(alpha = 0.1) +
      # Set axis labels for clarity
      labs(
        x = "YEAR",
        y = "PHASE"
      ) +
      # Configure bubble size scale (optional legend title removed for clarity)
      scale_size_continuous(
        name = "",
        range = c(2, 10)  # min and max bubble sizes in points
      ) +
      # Set x-axis breaks every 5 years for readability
      # seq() generates breaks; by = 5 creates 5-year intervals
      scale_x_continuous(
        breaks = seq(
          min(year_counts$YEAR, na.rm = TRUE),
          max(year_counts$YEAR, na.rm = TRUE),
          by = 5
        )
      ) +
      # Use clean, minimal theme
      theme_minimal() +
      # Rotate x-axis labels 45 degrees for readability
      # hjust = 1 (right-justifies text for rotation)
      theme(
        axis.text.x = element_text(angle = 45, hjust = 1)
      )
  )
  
  # Close graphics device and write PNG file
  dev.off()
  
  # Confirm successful visualization creation
  message("Visualization saved to: ", output_plot)
  
  # ---------------------------------------------------------------------------
  # RETURN VALUE (Reusability)
  # ---------------------------------------------------------------------------
  
  # Return the processed phenology data frame invisibly
  # invisible() prevents automatic printing in interactive sessions
  # but allows assignment: pheno_data <- download_dwd_phenology(...)
  invisible(pheno_data)
}

################################################################################
# USAGE EXAMPLE
# ==============================================================================
# Download and visualize Winter wheat (plant 202) phenology
#   pheno_data <- download_dwd_phenology(
#     plant = "202",
#     output_dir = "./phenology_data",
#     combine = TRUE
#   )
#   head(pheno_data)
#   summary(pheno_data)
#


# ################################################################################
# END OF FILE
# ################################################################################