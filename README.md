# PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![R](https://img.shields.io/badge/R-%3E%3D4.0-brightgreen.svg)](https://www.r-project.org/) [![FAIR](https://img.shields.io/badge/FAIR-compliant-green.svg)](https://doi.org/10.1038/s41597-022-01710-x) [![Data DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18594964.svg)](https://doi.org/10.5281/zenodo.18594964)

## Description

**PhenoPhaseR** is a reproducible R workflow for downloading, filtering, modelling, and spatially interpolating phenological observations provided by the German Weather Service (DWD). It implements the PHASE approach (**PH**enological model for **A**pplication in **S**patial and **E**nvironmental sciences; [Gerstmann et al. 2016](https://doi.org/10.1016/j.compag.2016.07.032)), which combines growing degree day models with geostatistical interpolation to produce area-wide phenological predictions across Germany at 1 km spatial resolution.

The workflow processes DWD phenological point observations through a seven-step pipeline: data download, station coupling, temperature extraction, effective temperature calculation, critical DOY determination, filter variant optimisation, and spatial interpolation with uncertainty quantification.

## Features

-   Automated download and harmonisation of DWD phenological observations (historical + recent)
-   Station-level coupling of phenological phases with meteorological data
-   Extraction of gridded daily mean temperatures at station locations
-   Effective temperature sum calculation with configurable base temperatures
-   Critical day-of-year (DOY) determination using temperature sum thresholds
-   Adaptive filter variant optimisation with year-specific sample number weighting
-   Spatial interpolation via kriging, thin-plate splines, or mgcv::bam with Bayesian uncertainty surfaces
-   Automatic basis dimension selection for GAM-based interpolation
-   Cross-validation with RMSE, MAE, MSE, and R² accuracy metrics

## Repository Structure

```         
PhenoPhaseR/
├── PhenoPhaseR.R                           # Main wrapper script (entry point)
├── function/
│   ├── download_dwd_phenology.R            # Step 1: Download DWD phenology data
│   ├── couple_phenology_stations.R         # Step 2: Couple observations with stations
│   ├── load_gridded_temperature.R          # Step 3: Extract gridded temperatures
│   ├── effective_temperature_calculation.R # Step 4: Calculate effective temperatures
│   ├── critical_doy_determination.R        # Step 5: Determine critical DOY thresholds
│   ├── filter_variant_selector.R           # Step 6: Optimise filter variants
│   └── spatial_interpolation.R             # Step 7: Spatial interpolation/uncertainty
├── data/                                   # Input data directory -> Data Availability
│   ├── tmit_YYYY.csv                       # CSV files containing mean air temperatures
│   ├── PHENO_STATION_EPSG31467.shp         # Phenological station locations
│   ├── WEATHER_GRID_EPSG31467.shp          # Germany-wide grid cells of 1 × 1 km²
│   └── DGM1000_EPSG25832.asc               # Digital Elevation Model (1 km)
├── output/                                 # Output directory (created by workflow)
├── CITATION.cff                            # Citation metadata
├── LICENSE                                 # MIT License
├── CHANGELOG.md                            # Version history
└── README.md                               # This file
```

## Features

-   Automated download and harmonization of phenology annual reporter data for selected crops (plant IDs) provided by the DWD.
-   Coupling of phenological observations with station coordinates and reference phases, including winter/summer crop handling and outlier removal.
-   Loading of gridded daily mean temperature and computation of cumulative effective temperature (GDD) at station locations.
-   Determination of critical DOY via temperature-sum quantile thresholds across multiple filter strengths.
-   Adaptive optimization of filter variants using sample-number-weighted scoring and accuracy metrics.
-   Spatial interpolation of optimal DOY to 1 km grids using kriging, thin-plate splines, or generalized additive modelling, with optional validation and uncertainty estimation.

## Workflow & Script Structure

The repository is modular, orchestrated by a central master script to ensure transparency and reproducibility.

### Core Pipeline (PhenoPhaseR.R)

1.  **`download_dwd_phenology.R`**: Fetches raw observations from the DWD [open data portal](https://opendata.dwd.de/).
2.  **`couple_phenology_stations.R`**: Merges observations with station metadata and handles crop-specific temporal logic (e.g., winter vs. summer crops).
3.  **`load_gridded_temperature.R`**: Aligns 1 km gridded daily mean temperatures with the specific vegetation period.
4.  **`effective_temperature_calculation.R`**: Computes thermal time accumulation (Growing Degree Days) with crop-specific base temperatures.
5.  **`critical_doy_determination.R`**: Identifies optimal thermal thresholds using quantile optimization.
6.  **`filter_variant_selector.R`**: Selects the best filtering parameters per year/phase considering sample density.
7.  **`spatial_interpolation.R`**: Generates the final 1 km grids using Generalized Additive Modells, Spline or Kriging.

You may additionally organize:

-   `data/`: Input data (e.g. `PHENO_STATION_EPSG31467.shp`, `DGM1000_EPSG25832.asc`, `tmit_YYYY.csv`).
-   `output/`: Derived station shapefiles, OPT tables, rasters, and diagnostics.
-   `docs/`: Extended workflow documentation and method descriptions.

## Data Availability

The pipeline requires specific spatial and meteorological datasets for Germany. All necessary input data for the period from 1992 to 2022 are available via Zenodo:

**Reference:** [10.5281/zenodo.18594964](https://doi.org/10.5281/zenodo.18594964) **Contents:** - **Station Network**: Shapefiles for phenological observer locations (`PHENO_STATION_EPSG31467`). - **Weather Grid**: Structured 1 km spatial reference for Germany (`WEATHER_GRID_EPSG31467`). - **Climate Data**: Interpolated daily mean temperatures (1992–2022) in CSV format. - **DEM**: Digital Elevation Model for Germany (`DGM1000_EPSG25832`).

Place the contents of the Zenodo archive into the `./data` directory before running the scripts.

### Supported Crops and Phases

**Crops (DWD Plant IDs):**

| ID  | Crop (EN)           | Crop (DE)     |
|-----|---------------------|---------------|
| 201 | Permanent grassland | Dauergrünland |
| 202 | Winter wheat        | Winterweizen  |
| 203 | Winter rye          | Winterroggen  |
| 204 | Winter barley       | Wintergerste  |
| 205 | Winter rapeseed     | Winterraps    |
| 208 | Oats                | Hafer         |
| 215 | Maize               | Mais          |
| 252 | Fodder beet         | Futter-Rübe   |
| 253 | Sugar beet          | Zucker-Rübe   |

### Output Files

| File Pattern | Description | Format |
|---------------------------|---------------------------|------------------|
| `DOY_<plant>-<phase>_<year>.tif` | Interpolated day-of-year prediction | GeoTIFF |
| `BSE_<plant>-<phase>_<year>.tif` | BAM posterior standard error (uncertainty) | GeoTIFF |
| `KSV_<plant>-<phase>_<year>.tif` | Kriging standard variance (uncertainty) | GeoTIFF |
| `SSE_<plant>-<phase>_<year>.tif` | Spline standard error (uncertainty) | GeoTIFF |
| `VAM_<plant>-<phase>_<year>.csv` | Validation accuracy metrics | CSV |
| `GEM_<plant>-<phase>_<year>.csv` | Global error metrics (uncertainty quantiles) | CSV |
| `OPT_ALL_<plant>_ALL_PHASES.csv` | All filter variants with OPT scores | CSV |
| `OPT_MAX_<plant>_ALL_PHASES.csv` | Optimal filter variants per year/phase | CSV |

## Citation

If you use this software in your research, please cite:

> Möller, M. & Gerstmann, H. (2026). *PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations* (v1.0.0). Zenodo. [https://doi.org/10.5281/zenodo.XXXXXXX](https://doi.org/10.5281/zenodo.XXXXXXX%5Bfile:6)

And the underlying PHASE methodology:

> Gerstmann, H., Doktor, D., Gläßer, C. & Möller, M. (2016). *PHASE: A geostatistical model for the Kriging-based spatial prediction of crop phenology using public phenological and climatological observations*. Computers and Electronics in Agriculture, 127, 726–738. [https://doi.org/10.1016/j.compag.2016.07.032](https://doi.org/10.1016/j.compag.2016.07.032)

See `CITATION.cff` for machine-readable citation metadata.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## FAIR and FAIR4RS compliance

**PhenoPhaseR** follows the FAIR for Research Software (FAIR4RS) principles and the FAIRagro roadmap for publishing research code FAIR.

-   **Findable**: Descriptive name, rich metadata, versioned releases, and a persistent DOI via Zenodo
-   **Accessible**: Public repository (Gitea/GitHub) and open dependencies from standard R package repositories
-   **Interoperable**: Uses open formats (CSV, ESRI Shapefile, GeoTIFF, PDF) and standard coordinate reference systems (EPSG codes)

## Installation

### System Requirements

-   **R** \>= 4.0.0
-   Internet connection (for DWD data download)

### R Package Dependencies

| Package       | Purpose                                    | CRAN |
|---------------|--------------------------------------------|------|
| sf            | Spatial data handling (modern standard)    | ✅   |
| raster        | Raster I/O and operations                  | ✅   |
| sp            | Legacy spatial classes (interoperability)  | ✅   |
| automap       | Automatic variogram fitting and kriging    | ✅   |
| fields        | Thin-plate spline interpolation            | ✅   |
| mgcv          | GAM/BAM spatial smoothing with uncertainty | ✅   |
| caret         | Training/test data partitioning            | ✅   |
| MLmetrics     | Accuracy metrics (RMSE, MAE, MSE)          | ✅   |
| ggplot2       | Diagnostic visualisations                  | ✅   |
| rnaturalearth | Country boundary geometries                | ✅   |

All dependencies are automatically installed via the `ensure_packages()` function included in each script.

Install them via:

\`\`\`r install.packages(c( "sf", "raster", "sp", "geosphere", "rnaturalearth", "automap", "fields", "mgcv", "caret", "MLmetrics", "ggplot2", "viridis", "gtools" ))

## Usage

``` r
# Clone the repository
# git clone https://gitea.julius-kuehn.de/markus.moeller/PhenoPhaseR.git
```

### Quick Start

1.  Place input data files in the `data/` directory.
2.  Adjust paths in `PhenoPhaseR.R` to match your directory structure.
3.  Configure the plant and phase identifiers (see tables below).
4.  Run the wrapper script:

``` r
source("PhenoPhaseR.R")
```

## Acknowledgements

- German Weather Service (DWD) for providing open phenological via [DWD CDC](https://opendata.dwd.de/climate_environment/CDC/) and interpolated climatological data
- Federal Agency for Cartography and Geodesy (BKG) for the Digital Elevation Model
- The FAIR code roadmap by FAIRagro ([doi:10.5281/zenodo.14772748](https://doi.org/10.5281/zenodo.14772748)) guided the FAIR publication of this software
