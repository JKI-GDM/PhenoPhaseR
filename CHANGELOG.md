# Changelog

All notable changes to **PhenoPhaseR** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each release is also archived on Zenodo under the concept DOI
[10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008),
which always resolves to the latest version.

---

## [1.2.0] – 2026-04-30

In-pipeline publishing and W3C-anchored metadata. A single `PhenoPhaseR()`
call now regenerates all three associated Zenodo records (software,
intermediate data, final data) in one CI run.

### Added

- **Hook A** (`build_filtervariant_ro_crate()`) packages Step 6 outputs
  (filter-variant DOY shapefiles, OPT scoring tables, diagnostic PDFs)
  as a self-contained RO-Crate 1.2 deposit ready for upload to
  [10.5281/zenodo.19483111](https://doi.org/10.5281/zenodo.19483111).
- **Hook B** (`build_phase_cog_ro_crate()`) packages Step 7 outputs
  (DOY + BSE Cloud-Optimized GeoTIFFs, VAM cross-validation tables) as
  a self-contained RO-Crate 1.2 deposit ready for upload to
  [10.5281/zenodo.19571847](https://doi.org/10.5281/zenodo.19571847).
- **DFFP integration** (optional, Hook B only): when `dffp_dir` is
  supplied, the Hook B crate embeds `schema:potentialAction` and one
  `schema:Review` per downstream paper that consumes PHASE, with
  per-category fitness ratings sourced from the DFFP Application Matrix
  tool ([10.5281/zenodo.19693642](https://doi.org/10.5281/zenodo.19693642)).
- **W3C-anchored metadata** in both crates:
  - DCAT 3 dual typing on Datasets (`dcat:Dataset`)
  - DQV quality measurements (`dqv:hasQualityMeasurement`,
    `dqv:isMeasurementOf`, `dqv:Metric`, `dqv:inDimension`)
  - SKOS bridge from each metric to its ISO 19157-1 dimension
    (`skos:closeMatch`)
  - PROV-O dual typing on `CreateAction` blocks (`prov:Activity`)
    with explicit `prov:used`, `prov:wasGeneratedBy`,
    `prov:wasAssociatedWith`, `prov:startedAtTime`, `prov:endedAtTime`
  - Dublin Core Terms aliases on coverage and licensing
    (`dct:license`, `dct:creator`, `dct:spatial`, `dct:temporal`)
- **`subfolders` parameter** (default `TRUE`) on
  `filter_variant_selector()` and `spatial_interpolation()` routes
  outputs into typed subfolders: `shapefiles/`, `opt_scores/`,
  `opt_scores/diagnostics/`, `cogs/`, `vam/`, `splits/`.
- **New columns** in machine-readable summaries:
  - `OPT_*.csv` — `N_RATIO` (sample retention SN/SN_max)
  - `VAM_*.csv` — `VN` (validation N), `MEAN_BSE` (spatial mean of the
    BSE raster), `BAM_K` (effective basis dimension)
- **`jsonlite`** added as a required dependency (used by both publish hooks).

### Changed

- `filter_variant_selector()` now writes via `file.path()` instead of
  `paste0(out_dir, ...)`, eliminating silent path errors when `out_dir`
  lacked a trailing slash.
- `out_dir` in `filter_variant_selector()` now defaults to `in_dir`
  (the previous version errored if `out_dir` was omitted).
- `export_diagnostic_plots()` takes the PDF target directory as an
  explicit `out_pdf_dir` argument instead of relying on lexical scoping.
- Documentation and metadata consistently identify the BSE approach as
  a Bayesian additive model (BAM, `mgcv::bam`) with bivariate spatial
  smooth and basis-spline standard error.

### Notes

- Backward compatibility: the v1.1.4 flat output layout is reproducible
  via `subfolders = FALSE` on both functions. The publish hooks expect
  the subfolder layout — running them against a flat-layout output
  directory will not discover any artifacts.
- The `software_doi` argument in both hooks defaults to the concept
  DOI `10.5281/zenodo.18743008`, which always resolves to the latest
  software version on Zenodo.

---

## [1.1.4] – 2026-04-28

Incremental polish on the publishing helper.

### Changed

- Minor metadata refinements in `phase_publish.R` (descriptive text,
  field formatting).

---

## [1.1.3] – 2026-04-14

Version-string consistency and metadata cleanup for the PHASE COG
deposit.

### Changed

- Synchronised the `PhenoPhaseR` version string across all three
  metadata fields in `phase_publish.R` (`schema:version`, Zenodo record
  title, HTML description, `setVersion()` call).

### Fixed

- Self-referencing DOI placeholder, AGROVOC concept ID for *Triticum
  aestivum*, ORCIDs and affiliations for all creators, funder block
  (FAIRagro / NFDI4Agri, DFG project 501899475), MSE unit, DFFP
  namespace and resolvable category terms, full Säurich et al. 2026
  reference (Ecological Informatics 95, 103660).

---

## [1.1.2] – 2026-04-28

Metadata-only release — data files byte-identical to v1.1.1.

### Changed

- Repackaged the metadata file as a proper RO-Crate 1.2 container
  (`ro-crate-metadata.json`), aligning with the WeatherIndicatoR product
  ([10.5281/zenodo.19683199](https://doi.org/10.5281/zenodo.19683199)).

### Fixed

- Corrections that were intended for v1.1.1 but had not propagated to
  the published metadata file: unsubstituted `<RECORD_ID>` placeholder
  in download URLs, double-escaped percent signs in VAM descriptions.

---

## [1.1.1] – 2026-04-21

Documentation and methods text alignment with the actual implementation.

### Fixed

- Step 5 documentation: clarified that the parameter varying inside the
  step is the **quantile** *q*, not the filter strength `f_std`. The
  outlier criterion is the standard-deviation-based residual filter
  `|predicted DOY − observed DOY| > f_std × σ(observed DOY)`, applied
  after prediction.
- Step 6 equation corrected to the actual implementation:
  `OPT = SN^x(year) × COR` (multiplicative; uses Pearson `COR`, not
  `R²`; year-specific adaptive exponent rather than a fixed weight pair).
- Documentation of the two minimum quality constraints (`min_cor`,
  `min_obs`) added.

---

## [1.1.0] – 2026-03-31

BAM interpolation and uncertainty quantification.

### Added

- BAM (`mgcv::bam`) as a third interpolation method alongside kriging
  and thin-plate splines, with automatic basis-dimension selection and
  per-pixel posterior standard error (BSE) raster output.
- Bayesian uncertainty surfaces written as Cloud-Optimized GeoTIFFs.
- Photoperiod weighting via `geosphere::daylength()` in the GDD
  calculation.
- Quantile-binned colour scale (`scale_fill_stepsn`) for raster map
  visualisation; new `n_quantiles` argument on
  `plot_phenology_raster_maps()`.

---

## [1.0.0] – 2026-02-17

Initial public release.

### Added

- Seven-step pipeline (download → couple → temperature → GDD → critical
  DOY → filter variant → spatial interpolation).
- Kriging and thin-plate spline interpolation methods.
- Cross-validation accuracy metrics (RMSE, MAE, MSE, R²).
- Adaptive filter variant optimisation with year-specific sample-number
  weighting.
- Concept DOI on Zenodo:
  [10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008).
- MIT license; CITATION.cff metadata.

---

[1.2.0]: https://doi.org/10.5281/zenodo.18743008
[1.1.4]: https://doi.org/10.5281/zenodo.18743008
[1.1.3]: https://doi.org/10.5281/zenodo.18743008
[1.1.2]: https://doi.org/10.5281/zenodo.18743008
[1.1.1]: https://doi.org/10.5281/zenodo.18743008
[1.1.0]: https://doi.org/10.5281/zenodo.18743008
[1.0.0]: https://doi.org/10.5281/zenodo.18743008
