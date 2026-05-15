# PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![R](https://img.shields.io/badge/R-%3E%3D4.0-brightgreen.svg)](https://www.r-project.org/) [![FAIR](https://img.shields.io/badge/FAIR-compliant-green.svg)](https://doi.org/10.1038/s41597-022-01710-x) [![Software DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18743008.svg)](https://doi.org/10.5281/zenodo.18743008) [![Input data DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18594964.svg)](https://doi.org/10.5281/zenodo.18594964)

## Description

**PhenoPhaseR** is a reproducible R workflow for downloading, filtering, modelling, and spatially interpolating phenological observations provided by the German Weather Service (DWD). It implements the PHASE approach (**PH**enological model for **A**pplication in **S**patial and **E**nvironmental sciences; [Gerstmann et al. 2016](https://doi.org/10.1016/j.compag.2016.07.032)), which combines growing degree day models with geostatistical interpolation to produce area-wide phenological predictions across Germany at 1 km spatial resolution.

The workflow processes DWD phenological point observations through a seven-step pipeline: data download, station coupling, temperature extraction, effective temperature calculation, critical DOY determination, filter variant optimisation, and spatial interpolation with uncertainty quantification. Since v1.2.0, two **publish hooks** at the natural break points of the pipeline package the intermediate filter variant results and the final PHASE entry-date COGs as self-contained RO-Crate 1.2 deposits ready for Zenodo upload, with embedded W3C-anchored provenance and quality metadata. A single `PhenoPhaseR()` call regenerates all three Zenodo records (software, intermediate data, final data) in one CI run.

## What's new in v1.3.0

-   **Per-phase multi-band COG aggregation in Hook B.** `build_phase_cog_ro_crate()` now aggregates the per-(phase, year) intermediate outputs into per-phase multi-band Cloud-Optimised GeoTIFFs (one band per year, band names = years) and wide-format per-phase VAM CSVs (one row per year). The published artefact count of the PHASE entry-date Zenodo deposit drops from ~896 to 21 files.
-   **`_per_year/` working subdirectory** preserves the per-(phase, year) intermediates on disk for any workflow that depends on the previous filename pattern, while being excluded from the published `ro_crate_phase.zip`.
-   **Per-year ISO 19157-1 quality preserved.** Each scalar `dqv:QualityMeasurement` now carries `schema:temporalCoverage` and `dct:temporal` set to the year string, so DQV consumers can group or filter measurements by year without losing the per-year granularity. 7 metrics × 32 years = 224 quality measurements per phase.
-   **New dependency.** `terra` (>= 1.7) is required by Hook B for COG stacking with `filetype="COG"` and band naming.
-   **Migration.** Code that previously read `cogs/DOY_202-10_2018.tif` should now read band `"2018"` of `cogs/DOY_202-10.tif`:
    ``` r
    # Before:
    r <- terra::rast("cogs/DOY_202-10_2018.tif")
    # After:
    r <- terra::rast("cogs/DOY_202-10.tif", lyrs = "2018")
    ```

## What's new in v1.2.0

-   **Two in-pipeline publish hooks.** `build_filtervariant_ro_crate()` and `build_phase_cog_ro_crate()` package Step 6 and Step 7 outputs into Zenodo-ready RO-Crate 1.2 deposits.
-   **W3C-aligned metadata.** Datasets dual-typed as `dcat:Dataset`; quality elements as `dqv:QualityMeasurement` with `skos:closeMatch` to ISO 19157-1 dimensions; `CreateAction` blocks dual-typed as `prov:Activity`; Dublin Core Terms aliases on coverage and licensing fields.
-   **Optional DFFP integration.** Hook B embeds Data-Fitness-for-Purpose reviews per downstream paper when a `dffp_dir` is supplied (DFFP Application Matrix tool).
-   **Subfolder output layout.** `filter_variant_selector()` and `spatial_interpolation()` now route outputs into typed subfolders (`shapefiles/`, `opt_scores/`, `cogs/`, `vam/`, `splits/`); `subfolders = FALSE` reproduces the v1.1.4 flat layout.
-   **New VAM/OPT columns.** `VN`, `MEAN_BSE`, `BAM_K` (VAM) and `N_RATIO` (OPT) are emitted to populate ISO 19157-1 quality elements in the crates.
-   **New dependency.** `jsonlite` is required by both publish hooks.

## Features

-   Automated download and harmonisation of DWD phenological observations (historical + recent)
-   Station-level coupling of phenological phases with meteorological data
-   Extraction of gridded daily mean temperatures at station locations
-   Effective temperature sum calculation with configurable base temperatures
-   Critical day-of-year (DOY) determination using temperature sum thresholds
-   Adaptive filter variant optimisation with year-specific sample number weighting
-   Spatial interpolation via kriging, thin-plate splines, or `mgcv::bam` with Bayesian uncertainty surfaces
-   Automatic basis dimension selection for GAM-based interpolation
-   Cross-validation with RMSE, MAE, MSE, and R² accuracy metrics
-   **In-pipeline publishing of self-contained RO-Crate 1.2 deposits with W3C-aligned provenance (PROV-O), dataset descriptors (DCAT 3 / DCT), and quality elements (DQV with SKOS bridge to ISO 19157-1)**

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
│   ├── spatial_interpolation.R             # Step 7: Spatial interpolation/uncertainty
│   ├── build_filtervariant_ro_crate.R      # Hook A: package Step 6 outputs as RO-Crate
│   └── build_phase_cog_ro_crate.R          # Hook B: package Step 7 outputs as RO-Crate
├── data/                                   # Input data directory -> Data Availability
│   ├── tmit_YYYY.csv                       # CSV files containing mean air temperatures
│   ├── PHENO_STATION_EPSG31467.shp         # Phenological station locations
│   ├── WEATHER_GRID_EPSG31467.shp          # Germany-wide grid cells of 1 × 1 km²
│   ├── DGM1000_EPSG25832.asc               # Digital Elevation Model (1 km)
│   └── dffp/                               # Optional: DFFP application matrix outputs
├── output/                                 # Output directory (created by workflow)
│   ├── shapefiles/                         # Step 6: optimal-variant DOY shapefiles
│   ├── opt_scores/                         # Step 6: OPT_ALL/OPT_MAX/EXPONENTS tables
│   │   └── diagnostics/                    # Step 6: PDF diagnostic plots
│   ├── cogs/                               # Step 7: per-(phase, year) DOY + BSE COGs (interim)
│   ├── vam/                                # Step 7: per-year VAM accuracy tables (interim)
│   ├── splits/                             # Step 7: TRAIN/TEST shapefiles
│   ├── ro_crate_filtervariants/  + .zip    # Hook A output (publish-ready)
│   └── ro_crate_phase/                     # Hook B output (publish-ready)
│       ├── cogs/                           #   per-phase multi-band COGs (1 band/year)
│       ├── vam/                            #   per-phase wide-format VAM CSVs
│       └── _per_year/                      #   working subfolder (excluded from ZIP)
├── CITATION.cff                            # Citation metadata
├── LICENSE                                 # MIT License
├── CHANGELOG.md                            # Version history
└── README.md                               # This file
```

## Workflow & Script Structure

The repository is modular, orchestrated by a central master script to ensure transparency and reproducibility.

### Core Pipeline (PhenoPhaseR.R)

1.  **`download_dwd_phenology.R`**: Fetches raw observations from the DWD [open data portal](https://opendata.dwd.de/).
2.  **`couple_phenology_stations.R`**: Merges observations with station metadata and handles crop-specific temporal logic (e.g., winter vs. summer crops).
3.  **`load_gridded_temperature.R`**: Aligns 1 km gridded daily mean temperatures with the specific vegetation period.
4.  **`effective_temperature_calculation.R`**: Computes thermal time accumulation (Growing Degree Days) with crop-specific base temperatures.
5.  **`critical_doy_determination.R`**: Identifies optimal thermal thresholds using quantile optimization.
6.  **`filter_variant_selector.R`**: Selects the best filtering parameters per year/phase considering sample density. Outputs are routed into `output/shapefiles/` and `output/opt_scores/` (subfolder layout).
7.  **`spatial_interpolation.R`**: Generates the final 1 km grids using Generalized Additive Models, Spline, or Kriging. Outputs are routed into `output/cogs/`, `output/vam/`, and `output/splits/`.

### Publish hooks

Two hooks at the natural break points of the pipeline package outputs into Zenodo-ready RO-Crate 1.2 deposits with W3C-anchored metadata.

| Hook | Function | After step | Artifact set | Target Zenodo concept DOI |
|----|----|----|----|----|
| **A** | `build_filtervariant_ro_crate()` | 6 | `shapefiles/`, `opt_scores/` | [10.5281/zenodo.19483111](https://doi.org/10.5281/zenodo.19483111) |
| **B** | `build_phase_cog_ro_crate()` | 7 | `cogs/` (per-phase multi-band DOY+BSE), `vam/` (per-phase wide-format) | [10.5281/zenodo.19571847](https://doi.org/10.5281/zenodo.19571847) |

Both hooks emit `ro-crate-metadata.json` plus a `<crate>.zip` ready for upload as a "new version" on the corresponding Zenodo record. The crates declare `isBasedOn` / `prov:wasDerivedFrom` links so that the three Zenodo records (software → filter variants → PHASE COGs) form a connected PROV-O graph. Hook B additionally embeds DFFP `schema:Review` entries when `dffp_dir` is supplied. As of v1.3.0, Hook B aggregates the per-(phase, year) intermediate outputs from Step 7 into per-phase multi-band COGs (one band per year) and wide-format per-phase VAM CSVs (one row per year), reducing the published artefact count of the PHASE entry-date deposit from ~896 to 21 files while preserving the per-year ISO 19157-1 quality elements through DQV temporal tagging. The per-(phase, year) intermediates remain available locally under `output/ro_crate_phase/_per_year/`.

## Data Availability

The pipeline requires specific spatial and meteorological datasets for Germany. All necessary input data for the period from 1992 to 2024 are available via Zenodo.

| Record | Concept DOI | Role |
|----|----|----|
| **Input data** (DWD phenology + temperature + DEM) | [10.5281/zenodo.18594964](https://doi.org/10.5281/zenodo.18594964) | Pipeline input |
| **PhenoPhaseR software** | [10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008) | This repository |
| **Filter variant results** (Hook A output) | [10.5281/zenodo.19483111](https://doi.org/10.5281/zenodo.19483111) | Intermediate data |
| **PHASE entry-date COGs** (Hook B output) | [10.5281/zenodo.19571847](https://doi.org/10.5281/zenodo.19571847) | Final data |

**Input contents:** Station Network (`PHENO_STATION_EPSG31467`), Weather Grid (`WEATHER_GRID_EPSG31467`), interpolated daily mean temperatures (CSV), Digital Elevation Model (`DGM1000_EPSG25832`).

Place the contents of the input archive into the `./data` directory before running the scripts.

### Supported Crops and Phases

**Crops (DWD Plant IDs):**

| ID  | Crop (EN)           | Crop (DE)     |
|-----|---------------------|---------------|
| 201 | Permanent grassland | Dauergrünland |
| 202 | Winter wheat        | Winterweizen  |
| 203 | Winter rye          | Winterroggen  |
| 204 | Winter barley       | Wintergerste  |
| 205 | Winter rapeseed     | Winterraps    |
| 207 | Summer barley       | Sommergeste   |
| 208 | Oats                | Hafer         |
| 215 | Maize               | Mais          |
| 252 | Fodder beet         | Futter-Rübe   |
| 253 | Sugar beet          | Zucker-Rübe   |

### Output Files

Files are written into typed subfolders under `output/` (set `subfolders = FALSE` in `filter_variant_selector()` and `spatial_interpolation()` to reproduce the v1.1.4 flat layout). Step 7 writes per-(phase, year) intermediate files; Hook B aggregates them into per-phase multi-band products in `ro_crate_phase/`.

**Step 6 + Step 7 working outputs**

| Subfolder | File pattern | Description | Format |
|----|----|----|----|
| `shapefiles/` | `DOY_<plant>-<phase>_<year>.shp` | Optimal-variant DOY observations (Hook A input) | Shapefile |
| `opt_scores/` | `OPT_ALL_<plant>-<phase>.csv` | All filter variants with OPT scores | CSV |
| `opt_scores/` | `OPT_MAX_<plant>-<phase>.csv` | Optimal filter variants per year/phase | CSV |
| `opt_scores/` | `OPT_<plant>_EXPONENTS_ALL_PHASES.csv` | Year-specific adaptive exponents | CSV |
| `opt_scores/diagnostics/` | `OPT_<plant>-<phase>_DIAGNOSTICS.pdf` | Diagnostic plots | PDF |
| `cogs/` | `DOY_<plant>-<phase>_<year>.tif` | Per-year interpolated day-of-year prediction | Cloud-Optimized GeoTIFF |
| `cogs/` | `BSE_<plant>-<phase>_<year>.tif` | Per-year BAM posterior standard error (BSE approach) | Cloud-Optimized GeoTIFF |
| `cogs/` | `KSV_<plant>-<phase>_<year>.tif` | Kriging standard variance (alternative method) | Cloud-Optimized GeoTIFF |
| `cogs/` | `SSE_<plant>-<phase>_<year>.tif` | Spline standard error (alternative method) | Cloud-Optimized GeoTIFF |
| `vam/` | `VAM_<plant>-<phase>_<year>.csv` | Per-year cross-validation metrics (PLANT, PHASE, YEAR, TN, ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2, MEAN_BSE) | CSV |
| `vam/` | `CAL_<plant>-<phase>_<year>.csv` | Per-year calibration metrics (BAM only) | CSV |
| `vam/` | `GEM_<plant>-<phase>_<year>.csv` | Per-year global error metrics (uncertainty quantiles) | CSV |
| `splits/` | `TRAIN_<plant>-<phase>_<year>.shp` | Training stations (75% holdout split) | Shapefile |
| `splits/` | `TEST_<plant>-<phase>_<year>.shp` | Validation stations | Shapefile |

**Hook A and Hook B publish-ready outputs**

| Path | File pattern | Description | Format |
|----|----|----|----|
| `ro_crate_filtervariants.zip` | – | Hook A publish-ready RO-Crate (Zenodo upload) | ZIP |
| `ro_crate_phase/cogs/` | `DOY_<plant>-<phase>.tif` | **Aggregated** per-phase DOY raster: multi-band COG, 32 bands (one per year 1993–2024), band names = years | Cloud-Optimized GeoTIFF |
| `ro_crate_phase/cogs/` | `BSE_<plant>-<phase>.tif` | **Aggregated** per-phase BSE uncertainty raster, 32 bands matching the DOY bands | Cloud-Optimized GeoTIFF |
| `ro_crate_phase/vam/` | `VAM_<plant>-<phase>.csv` | **Aggregated** per-phase cross-validation table: one row per year, wide format | CSV |
| `ro_crate_phase/_per_year/` | various | Working subdirectory: per-(phase, year) intermediates moved here by the aggregation step. Excluded from the ZIP. | – |
| `ro_crate_phase.zip` | – | Hook B publish-ready RO-Crate (Zenodo upload), 21 artefacts + metadata | ZIP |

**Reading the aggregated COGs in R**

``` r
# Whole stack (32 bands as a SpatRaster):
stk <- terra::rast("output/ro_crate_phase/cogs/DOY_202-10.tif")
names(stk)        # "1993" "1994" ... "2024"

# A single year:
r2018 <- terra::rast("output/ro_crate_phase/cogs/DOY_202-10.tif", lyrs = "2018")
```

## Metadata standards

Crates emitted by the publish hooks use a layered, W3C-anchored vocabulary stack so that quality information can propagate to downstream catalogues (FAIRagro, BonaRes, GeoNetwork, CKAN) without requiring custom parsers.

| Vocabulary | Namespace | Role in the crate |
|----|----|----|
| **RO-Crate 1.2** (Workflow Run Crate profile) | `https://w3id.org/ro/crate/1.2/context` | Top-level container profile |
| **DCAT 3** (W3C) | `http://www.w3.org/ns/dcat#` | Dual typing on Datasets (`dcat:Dataset`) |
| **DCT** (Dublin Core Terms) | `http://purl.org/dc/terms/` | Coverage, licensing, agent aliases |
| **DQV** (W3C Data Quality Vocabulary) | `http://www.w3.org/ns/dqv#` | Quality measurements, metrics, dimensions |
| **PROV-O** (W3C Provenance Ontology) | `http://www.w3.org/ns/prov#` | Workflow provenance (`prov:Activity`, `prov:used`, `prov:wasGeneratedBy`) |
| **SKOS** (W3C) | `http://www.w3.org/2004/02/skos/core#` | Bridge from DQV metrics to ISO 19157-1 |
| **ISO 19157-1** | `http://standards.iso.org/iso/19157/-1/` | Domain quality dimensions (referenced via `skos:closeMatch`) |
| **Schema.org** | `http://schema.org/` | Carrier for entities without W3C equivalents (Person, Organization, License) |
| **SPDX** | `http://spdx.org/rdf/terms#` | File checksums |

Quality elements are exposed simultaneously through `schema:variableMeasured` (Schema.org) and `dqv:hasQualityMeasurement` (W3C DQV), referencing the same node array — no duplication, no drift.

## Citation

If you use this software in your research, please cite:

> Möller, M. & Gerstmann, H. (2026). *PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations* (v1.3.0). Zenodo. <https://doi.org/10.5281/zenodo.18743008>

If you use the published PHASE dataset, please additionally cite:

> Möller, M. & Gerstmann, H. (2026). *PHASE: Crop Phenological Development Dataset for Germany (1993–2024)*. Zenodo. <https://doi.org/10.5281/zenodo.19571847>

And the underlying PHASE methodology:

> Gerstmann, H., Doktor, D., Gläßer, C. & Möller, M. (2016). *PHASE: A geostatistical model for the Kriging-based spatial prediction of crop phenology using public phenological and climatological observations*. Computers and Electronics in Agriculture, 127, 726–738. <https://doi.org/10.1016/j.compag.2016.07.032>

See `CITATION.cff` for machine-readable citation metadata.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## FAIR and FAIR4RS compliance

**PhenoPhaseR** follows the FAIR for Research Software (FAIR4RS) principles and the FAIRagro roadmap for publishing research code FAIR.

-   **Findable**: Descriptive name, rich metadata, versioned releases, and persistent concept DOIs via Zenodo for software, intermediate data, and final data
-   **Accessible**: Public repository (Gitea/GitHub) and open dependencies from standard R package repositories
-   **Interoperable**: Uses open formats (CSV, ESRI Shapefile, Cloud-Optimized GeoTIFF, PDF, JSON-LD) and standard coordinate reference systems (EPSG codes); metadata follows W3C standards (DCAT 3, DCT, DQV, PROV-O, SKOS) with a SKOS bridge to ISO 19157-1 quality dimensions
-   **Reusable**: MIT open-source license; CC-BY-4.0 on the data deposits; code is extensively documented; users can create own variants; in-pipeline publishing guarantees that any re-run regenerates a self-contained, traceable RO-Crate

## Installation

### System Requirements

-   **R** \>= 4.0.0
-   Internet connection (for DWD data download)

### R Package Dependencies

| Package       | Purpose                                         | CRAN |
|---------------|-------------------------------------------------|------|
| sf            | Spatial data handling (modern standard)         | ✅   |
| raster        | Raster I/O and operations                       | ✅   |
| sp            | Legacy spatial classes (interoperability)       | ✅   |
| automap       | Automatic variogram fitting and kriging         | ✅   |
| fields        | Thin-plate spline interpolation                 | ✅   |
| mgcv          | GAM/BAM spatial smoothing with uncertainty      | ✅   |
| caret         | Training/test data partitioning                 | ✅   |
| MLmetrics     | Accuracy metrics (RMSE, MAE, MSE)               | ✅   |
| ggplot2       | Diagnostic visualisations                       | ✅   |
| rnaturalearth | Country boundary geometries                     | ✅   |
| **jsonlite**  | **RO-Crate JSON-LD generation (Hooks A and B)** | ✅   |
| **terra**     | **Per-phase multi-band COG stacking (Hook B, >= 1.7)** | ✅   |
| gtools        | Mixed-order sorting in filter selector          | ✅   |
| geosphere     | Photoperiod weighting (`daylength()`) in GDD    | ✅   |

All dependencies are automatically installed via the `ensure_packages()` function included in each script.

Install them via:

``` r
install.packages(c(
  "sf", "raster", "sp", "geosphere", "rnaturalearth",
  "automap", "fields", "mgcv", "caret", "MLmetrics",
  "ggplot2", "viridis", "gtools", "jsonlite", "terra"
))
```

## Usage

``` r
# Clone the repository
# git clone https://gitea.julius-kuehn.de/markus.moeller/PhenoPhaseR.git
```

### Quick Start

1.  Place input data files in the `data/` directory.
2.  (Optional) Place the DFFP application-matrix outputs in `data/dffp/` to embed Data-Fitness-for-Purpose reviews into the Hook B crate.
3.  Adjust paths in `PhenoPhaseR.R` to match your directory structure.
4.  Configure the plant and phase identifiers (see tables above).
5.  Run the wrapper script:

``` r
source("PhenoPhaseR.R")
```

A single run produces the seven-step pipeline outputs *and* the two publish-ready RO-Crate ZIPs (`ro_crate_filtervariants.zip`, `ro_crate_phase.zip`). Upload each ZIP as a "new version" on the corresponding Zenodo concept record to update the published deposits.

### Backward compatibility

`subfolders = TRUE` is the new default for both `filter_variant_selector()` and `spatial_interpolation()`. Pass `subfolders = FALSE` to reproduce the v1.1.4 flat output layout. Note that the publish hooks expect the subfolder layout — running them against a flat-layout output directory will not discover any artifacts.

## Acknowledgements

-   German Weather Service (DWD) for providing open phenological data via [DWD CDC](https://opendata.dwd.de/climate_environment/CDC/) and interpolated weather data
-   Federal Agency for Cartography and Geodesy (BKG) for the Digital Elevation Model
-   The FAIR code roadmap by FAIRagro ([doi:10.5281/zenodo.14772748](https://doi.org/10.5281/zenodo.14772748)) guided the FAIR publication of this software
-   The DFFP Application Matrix tool provides the Data-Fitness-for-Purpose layer optionally embedded in the Hook B crate
