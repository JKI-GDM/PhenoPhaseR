# PhenoPhaseR

**Reproducible processing workflow for interpolating phenological DWD observations.**

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18743008.svg)](https://doi.org/10.5281/zenodo.18743008) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

PhenoPhaseR is a reproducible **R** workflow for downloading, filtering, modelling, and spatially interpolating phenological observations from the German Weather Service (DWD). It implements the **PHASE** approach ([Gerstmann et al. 2016](https://doi.org/10.1016/j.compag.2016.07.032)), which combines growing-degree-day models with geostatistical interpolation to produce area-wide phenological predictions across Germany at **1 km** spatial resolution.

Each run can publish its outputs as self-contained **FAIR Digital Objects** (RO-Crate 1.2) with machine-actionable provenance, dataset descriptors, and data-quality metadata — so the results travel with their lineage and their quality stance, not just as bare rasters.

------------------------------------------------------------------------

## What it does

The pipeline is a chain of quality-producing steps:

1.  **Download** DWD station phenology and the supporting weather / elevation inputs.
2.  **Filter** the station observations into candidate *filter variants*.
3.  **Model** growing-degree-day thresholds per phenological phase.
4.  **Interpolate** to a 1 km grid with a spatial generalized additive model (`mgcv::bam`, `DOY ~ s(X, Y) + DEM`), returning per-pixel fitted values and the basis-spline standard error (BSE).
5.  **Validate** out-of-sample (cross-validated accuracy, and a calibrated prediction interval for the uncertainty layer).
6.  **Publish** the intermediate and final products as RO-Crates.

### Two in-pipeline publish hooks

-   **Hook A — `build_filtervariant_ro_crate()`** packages the intermediate filter-variant results (accuracy / validation metrics).
-   **Hook B — `build_phase_cog_ro_crate()`** packages the final PHASE entry-date surfaces as per-phase, multi-band Cloud-Optimised GeoTIFFs (one band per year) together with their quality tables: **VAM** (validation), **CAL** (in-sample model fit), **GEM** (spatial quantiles of the BSE uncertainty raster), and **PIC** (validated prediction-interval calibration).

Each crate carries a `ro-crate-metadata.json` (JSON-LD), an auto-generated `README.md` describing its validation stance, and a self-contained `ro-crate-preview.html` for browser inspection.

------------------------------------------------------------------------

## The metadata stack

PhenoPhaseR does not invent bespoke metadata terms; it composes established, community-maintained vocabularies, each declared as a namespace in the crate `@context`:

| Layer | Vocabulary | Role |
|----|----|----|
| Container | Schema.org, RO-Crate 1.2, Process Run Crate 0.5 | Packaging + profile |
| Catalogue | DCAT 3, Dublin Core Terms | Dataset description |
| Provenance | PROV-O | `Activity` → `used` / `wasGeneratedBy` / agents + roles |
| Quality | DQV; ISO 19157-1; **`fairagrodq:` (provisional)** | Measurements, dimensions, principles |
| Domain | AGROVOC ↔ Wikidata (SKOS) | Subject anchoring |
| Identifiers | ORCID, ROR, DOI, DataCite, GeoNames, EPSG, SPDX | Persistent IDs |

### Honest anchoring of data quality (since v1.8.0)

The quality layer is built on one rule: **an identifier or claim in metadata must resolve to what it claims, or you say less.** Concretely:

-   **Accuracy metrics** (`cv_rmse`, `cv_mae`, …) anchor via `dqv:inDimension` to *genuine* ISO 19157-1 elements (e.g. `iso19157:QuantitativeAttributeAccuracy`).
-   **Spatially explicit uncertainty** has no native ISO element, so it uses a provisional owned dimension, `fairagrodq:NumericalSpatialUncertainty` (continuous) or `fairagrodq:ClassSpatialUncertainty` (categorical), under a `fairagrodq:SpatialUncertainty` parent. These dimensions declare `dct:isDefinedBy` Säurich et al. (2026) — the paper that *proposes* the element — and are explicitly **not part of ISO 19157-1:2023**. They do *not* claim `conformsTo` a standard that does not contain them.
-   **Two orthogonal axes.** A measurement records *which aspect* of quality it concerns (`dqv:inDimension`) and, separately, *how it was produced and what it may claim* (`fairagrodq:expressedBy`, resolving into the `fairagrodq:UncertaintyExpressionPrinciple` SKOS scheme). The BSE layer is expressed by `ParametricModelUncertainty` (model-asserted); its PICP/MPIW calibration by `EmpiricalCoverageCalibration` (empirically-validated). This is what lets a consumer filter for, say, only *validated* uncertainty layers.

`fairagrodq:` = `https://w3id.org/fairagro/dq#` is **provisional**: it is emitted in the crate but is not yet resolvable (w3id registration pending). The vocabulary is also published as a standalone deposit, generated from these same registries by [`tools/generate_fairagrodq_ttl.R`](tools/generate_fairagrodq_ttl.R) (since v1.8.1) so it cannot drift from what the crates emit. `dffp:` (the DFFP Application Matrix namespace) is retained **only** for the fitness-for-purpose review (`schema:potentialAction` / `AssessAction`).

See [`CHANGELOG.md`](CHANGELOG.md) for the full history.

------------------------------------------------------------------------

## Repository layout

```         
PhenoPhaseR/
├── _crop_specs.R                  # per-crop registry (DWD Plant ID, AGROVOC, Wikidata, roles)
├── dq_vocab_core.R                # registry-driven DQ engine: measures, dimensions, inDimension
├── dq_uncertainty_principles.R    # fairagrodq:UncertaintyExpressionPrinciple scheme + expressedBy
├── build_filtervariant_ro_crate.R # Hook A: filter-variant crate
├── build_phase_cog_ro_crate.R     # Hook B: PHASE COG crate (VAM/CAL/GEM/PIC)
├── tools/
│   └── generate_fairagrodq_ttl.R  # regenerate the standalone fairagrodq vocabulary from the registries
├── CHANGELOG.md
├── CITATION.cff
├── .zenodo.json
└── README.md
```

(Adjust to match your working tree; the data-download and modelling scripts live alongside the builders.)

## Requirements

-   R (≥ 4.2 recommended)
-   Core packages: `terra`, `sf`, `mgcv`, `ranger`, `quantregForest`, `data.table`, `jsonlite`, plus the DWD access / COG-writing helpers used by your download scripts.

## Usage (illustrative)

``` r
source("_crop_specs.R")
source("dq_vocab_core.R")
source("dq_uncertainty_principles.R")
source("build_filtervariant_ro_crate.R")
source("build_phase_cog_ro_crate.R")

# ... run the download / filter / model / interpolate steps for a crop ...

# Hook A: package the intermediate filter-variant results
build_filtervariant_ro_crate(data_dir = "...", out_dir = "crates/filter")

# Hook B: package the final PHASE entry-date COGs + quality tables
build_phase_cog_ro_crate(data_dir = "...", out_dir = "crates/phase",
                         dffp_dir = NULL)   # set to a directory to embed Application-Matrix reviews
```

Each call writes a directory containing `ro-crate-metadata.json`, `README.md`, and `ro-crate-preview.html`, ready to deposit.

------------------------------------------------------------------------

## FAIR publishing chain

Source is developed on **Codeberg**, mirrored to **GitHub** ([`JKI-GDM/PhenoPhaseR`](https://github.com/JKI-GDM/PhenoPhaseR)), and each tagged release is archived to **Zenodo** under the concept DOI [10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008), with `CITATION.cff` and `.zenodo.json` driving the citation and deposit metadata. See [`RELEASING.md`](RELEASING.md) for how a version is cut.

## Versioning

This project follows [Semantic Versioning](https://semver.org/). Changes to the emitted-metadata vocabulary (new terms, changed IRIs) are MINOR releases; the R entry-point API is stable across the 1.x line. See [`CHANGELOG.md`](CHANGELOG.md).

## Citation

If you use PhenoPhaseR, please cite it via the metadata in [`CITATION.cff`](CITATION.cff), or the concept DOI [10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008). Please also cite the method paper, Gerstmann et al. (2016), [doi:10.1016/j.compag.2016.07.032](https://doi.org/10.1016/j.compag.2016.07.032).

## License

[MIT](LICENSE) © Markus Möller, Henning Gerstmann.

## Acknowledgements

Funded by the Deutsche Forschungsgemeinschaft (DFG) within **FAIRagro** — FAIR Data Infrastructure for Agrosystems Research, project [501899475](https://gepris.dfg.de/gepris/projekt/501899475). Phenological observations © Deutscher Wetterdienst (DWD).
