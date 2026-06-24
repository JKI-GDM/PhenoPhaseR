# Changelog

All notable changes to **PhenoPhaseR** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For software whose primary external contract is the **metadata it emits** (the RO-Crate structure, the vocabularies and IRIs used), versioning is applied as follows: a change to the emitted-metadata schema or vocabulary that adds terms or alters which IRIs are emitted is a **MINOR** release; a backwards-compatible fix with no schema change is a **PATCH**; an incompatible change to the R *entry-point* API would be a **MAJOR** release. Already-published deposits are immutable: superseded encodings are preserved as historical record and are only superseded in *new* builds.

Concept DOI (all versions): <https://doi.org/10.5281/zenodo.18743008>

------------------------------------------------------------------------

## [1.8.0] - 2026-06-19

**Honest anchoring of spatially explicit uncertainty: a provisional `fairagrodq:` namespace and an orthogonal expression-principle axis.**

This is a metadata-encoding / vocabulary release. There are **no numerical changes** to any raster or to the VAM / CAL / GEM / PIC quality tables; the changes are to how quality is *anchored and described* in the emitted crates.

### Added

-   **Registry-driven data-quality engine** (`dq_vocab_core.R`). A single editable measure→dimension table (`.DQ_MEASURES`, `.DQ_DIMENSIONS`) is the one place every `dqv:inDimension` / `fairagrodq:expressedBy` target resolves against, so adding a measure or a new domain (digital soil mapping, crop-type classification) touches one table rather than the builders.
-   **Orthogonal expression-principle axis** (`dq_uncertainty_principles.R`). A new `skos:ConceptScheme`, `fairagrodq:UncertaintyExpressionPrinciple`, defines eight resolvable principle concepts — `ParametricModelUncertainty`, `AnalyticalErrorPropagation`, `QuantileRegressionInterval`, `ConformalPredictionInterval`, `EnsembleSimulationSpread`, `EmpiricalCoverageCalibration`, `ApplicabilityDomain`, `FuzzyClassMembership` — each carrying a machine-readable `fairagrodq:claimStatus`, `fairagrodq:representation`, and `fairagrodq:assumes`. A new predicate `fairagrodq:expressedBy` links a measure/file to its principle. A measurement now records two orthogonal facts: *which aspect* of quality it concerns (`dqv:inDimension`) and *how it was produced and what it may claim* (`fairagrodq:expressedBy`). In the PHASE crate the BSE layer is expressed by `ParametricModelUncertainty` (model-asserted) and its PICP/MPIW calibration by `EmpiricalCoverageCalibration` (empirically-validated).
-   Provisional cross-project namespace `fairagrodq:` = `https://w3id.org/fairagro/dq#`, declared in both crate `@context`s (pending w3id registration), plus `rdf:` / `rdfs:` prefixes to type the owned predicates and the concept scheme.

### Changed

-   **Spatial-uncertainty dimensions migrated `dffp:` → provisional `fairagrodq:`.** `fairagrodq:NumericalSpatialUncertainty` (continuous attributes) and `fairagrodq:ClassSpatialUncertainty` (categorical maps), typed `dqv:Dimension` + `skos:Concept`, sit under a `fairagrodq:SpatialUncertainty` parent via `skos:broader`.
-   **`dffp:` is now used solely for the Application-Matrix review** (`schema:potentialAction` / `AssessAction`), no longer for spatial-uncertainty dimensions. In crates without populated Application-Matrix output the action is a scaffold and the `dffp:` prefix carries no graph terms.

### Fixed (honest anchoring)

-   **Removed the ISO 19157-1 conformance overclaim** on the spatial-uncertainty dimensions. ISO 19157-1:2023 does not contain a Spatial-Uncertainty element, so the dimensions no longer assert `dct:conformsTo` ISO 19157-1. They now declare `dct:isDefinedBy` Säurich et al. (2026, <doi:10.1016/j.ecoinf.2026.103660>) — the source that *proposes* the element — and are explicitly labelled *not part of ISO 19157-1:2023*. No IRI claims authority it does not hold.
-   Genuine ISO 19157-1 accuracy elements (e.g. `iso19157:QuantitativeAttributeAccuracy`) remain the `dqv:inDimension` target for accuracy metrics (`cv_rmse`, `cv_mae`); no `skos:closeMatch` to a non-existent measure concept is asserted anywhere.

### Compatibility

-   Pure metadata/vocabulary change; the R entry points (`build_phase_cog_ro_crate()`, `build_filtervariant_ro_crate()`) are unchanged.
-   Already-published crates retain their original `dffp:` IRIs as historical record; only new builds emit the `fairagrodq:` dimensions and the principle axis.
-   New references in the emitted vocabulary: Säurich et al. (2026, <doi:10.1016/j.ecoinf.2026.103660>); Meyer & Pebesma (2021, <doi:10.1111/2041-210X.13650>, the area-of-applicability principle).

------------------------------------------------------------------------

## [1.7.2] - 2026-06-14

Maintenance release on top of 1.7.0 (packaging / metadata fixes). See the Zenodo version history for the authoritative per-patch record.

## [1.7.0]

Reinstated the AGROVOC subject layer with verified URIs and a build-time guard; made all DQV quality measures anchor honestly to ISO 19157; added a validated calibration of the BSE uncertainty layer (PIC artefact). No numerical changes to any raster or to the existing VAM/CAL/GEM tables — the changes are to metadata encoding plus one new validation artefact.

## [1.6.0]

Multi-crop blueprint: a shared `_crop_specs.R` holds per-crop metadata (DWD Plant ID, binomial, AGROVOC concept URI, Wikidata QID) for seven crops (winter wheat, winter rye, winter barley, winter rapeseed, spring barley, oats, maize); a family-wide creators list with explicit DataCite roles and a layered keyword scheme; both builders are parametric on this configuration. AGROVOC subject terms (`schema:about` / `dct:subject`) with `DefinedTerm` / `DefinedTermSet` entities added to the `@graph`.

## [1.5.0]

Restructured the DQV quality metadata: each per-year quality measurement is now a first-class top-level entity in the JSON-LD `@graph` with its own `@id`, and the per-phase Datasets reference them by `@id` only — satisfying JSON-LD's node-reference rule and resolving 33 REQUIRED-severity violations previously reported by `roc-validator`.

## [1.4.0]

Added two published quality artefacts to Hook B (CAL, in-sample BAM model-fit diagnostics; GEM, spatial quantiles of the BSE uncertainty raster); auto-writes a `README.md` into each crate documenting its validation stance; generates a self-contained `ro-crate-preview.html` for browser-based inspection without external tooling.

## [1.3.0]

Hook B aggregates the per-(phase, year) intermediate outputs into per-phase multi-band Cloud-Optimised GeoTIFFs (one band per year, named by year) and wide-format per-phase VAM CSVs, reducing the published artefact count from \~896 to 21 files while preserving the per-year ISO 19157-1 quality elements through DQV temporal tagging.

## [1.2.0]

Two in-pipeline publish hooks package the intermediate filter-variant results and the final PHASE entry-date COGs as self-contained RO-Crate 1.2 deposits with W3C-anchored provenance (PROV-O), dataset descriptors (DCAT 3 / Dublin Core Terms), and quality metadata (DQV with a SKOS bridge to ISO 19157-1).

------------------------------------------------------------------------

Releases prior to 1.2.0, and the exact contents of patch releases, predate this changelog; the authoritative version history (with per-version DOIs and dates) is on Zenodo: <https://doi.org/10.5281/zenodo.18743008>.
