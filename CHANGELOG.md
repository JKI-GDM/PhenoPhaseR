# Changelog

All notable changes to **PhenoPhaseR** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

For software whose primary external contract is the **metadata it emits**
(the RO-Crate structure, the vocabularies and IRIs used), versioning is applied
as follows: a change to the emitted-metadata schema or vocabulary that adds terms
or alters which IRIs are emitted is a **MINOR** release; a backwards-compatible
fix with no schema change is a **PATCH**; an incompatible change to the R
*entry-point* API would be a **MAJOR** release. Already-published deposits are
immutable: superseded encodings are preserved as historical record and are only
superseded in *new* builds.

Concept DOI (all versions): <https://doi.org/10.5281/zenodo.18743008>

---

## [1.9.0] - 2026-07-15

**Honest validation basis for every accuracy metric; the emitted metadata no
longer conflates hold-out, in-sample, and deviance-explained under one label.**

A **MINOR** release: it adds vocabulary terms (`is_rmse`, `is_mae`, `is_cor`) and
alters which metric IRIs the FilterVariant crate emits. Per the versioning policy
above, that is a minor change. The PHASE crate's emitted metric IRIs are
**unchanged** (`cv_*` identifiers are retained), so already-published PHASE
deposits do not dangle. **No data files change** — this is an emitted-metadata
correction only; re-emit crate metadata against the unchanged data.

### Background

An audit found three distinct validation regimes described under a single, and in
two cases incorrect, label:

- **VAM accuracy metrics** (`RMSE`, `MAE`, `MSE`, `R2`) are **hold-out** (a single
  `ON = TN + VN` train/test split) but were emitted as "Cross-validation ...".
- **`cv_r2`** is the VAM **`R2`** column — a **hold-out** coefficient of
  determination on the withheld partition, companion to `cv_rmse` / `cv_mae` — but
  was emitted as "coefficient of determination, observed vs predicted" without
  stating that it is hold-out. (The in-sample **`DEV_EXPLAINED`** diagnostic in the
  CAL file is a *separate* quantity, published only as a file-level model-fit
  statistic, never as this metric.)
- The **`critical_doy_determination()`** metrics are **in-sample (resubstitution)
  with target leakage and selection bias**, and were emitted through the hold-out
  token `cv_rmse` in the FilterVariant crate.

The same identifier `cv_rmse` was consequently described as "Cross-validation RMSE
of DOY" by the PHASE builder and "Holdout RMSE of the modelled attribute" by the
FilterVariant builder — a contradiction caused by each builder hand-writing its
own description text.

### Added

- **`basis` and `caveat` fields in the metric registry** (`.DQ_MEASURES`,
  `dq_vocab_core.R`). Every measure records the regime that produced it
  (`holdout`, `in-sample`, `deviance`, `parameter`, `count`, `diagnostic`,
  `validation`) and, where a number is optimistically biased, a caveat stating
  why. `basis` is the accuracy-metric analogue of the vocabulary's uncertainty
  claim-status axis.
- **In-sample metric tokens** `is_rmse`, `is_mae`, `is_cor` for the
  `critical_doy_determination()` outputs.
- **`dq_describe(token)`** emitter: returns the honest `schema:description`
  (definition + validation basis + caveat). Both builders read from it, so metric
  descriptions cannot diverge across crates.
- **`tools/run_zenodo_deposit.R`** — maintainer runner for the metadata-only Zenodo
  deposit workflow (drafts only; publish is manual). Reads `ZENODO_TOKEN` from the
  environment and aborts if unset; paths and crop list are parameters. Unrelated to
  the metric correction; newly tracked (replaces an untracked ad-hoc driver that
  carried a hardcoded token placeholder and absolute paths).

### Changed

- **`schema:description` for metric measurements is sourced from the registry via
  `dq_describe()`** (in `dq_quality_element()`), not hand-written per call site.
  `picp` / `mpiw` are the deliberate exception: they keep their parameterised
  description (nominal coverage %, k-fold-CV fold structure), which a static
  registry entry would flatten.
- **FilterVariant builder** emits its in-sample critical_doy metrics under
  `is_rmse` / `is_mae` / `is_cor` instead of the hold-out tokens `cv_rmse` /
  `mae_days` / `correlation`.

### Fixed

- **`cv_r2` description** — corrected to "hold-out coefficient of determination on
  the withheld validation partition" (it is the VAM `R2` column, companion to
  `cv_rmse` / `cv_mae`). It is NOT the in-sample CAL `DEV_EXPLAINED` diagnostic,
  which is published separately as a file-level model-fit statistic.
- **VAM accuracy-metric descriptions** — "Cross-validation ..." corrected to
  hold-out throughout, including the VAM file-level description and the
  self-contradictory "holdout cross-validation" phrasing.
- **Cross-crate description drift** — `cv_rmse` and every shared metric token is
  now described identically in both crates.

### Removed

- **The `wikidata_qid` field and its emitted `skos:exactMatch → Wikidata` link**, from
  `_crop_specs.R` and both crate builders. AGROVOC does not publish Wikidata matches for
  these crop concepts (verified via the AGROVOC SPARQL endpoint: winter wheat `c_8412`
  links only to USDA NAL, the World Bank thesaurus, and DBpedia), and the hand-added QIDs
  were unverifiable — on checking, all eight were wrong (e.g. winter wheat pointed at
  maize, sugar beet at Valletta). The verified AGROVOC concept URIs are retained as the
  authoritative subject anchor; per honest-anchoring, no unbacked second identifier is
  asserted in their place.

### Deferred

- The **regime-honest rename of the retained `cv_*` identifiers** (`cv_rmse` →
  `ho_rmse`, `cv_r2` → `ho_r2`, …) is deferred to the next **MAJOR** release,
  which will retire the old IRIs with `owl:deprecated` + `dct:isReplacedBy` rather
  than overwrite them. Until then the `cv_*` tokens are wrong-but-stable with
  honest descriptions attached.

### Verify before release

- Confirm the value fed into `cv_r2` (PHASE builder) is the VAM `R2` column, as the
  corrected description now states — the builder's column map (line ~35) shows
  `cv_r2 ← R2`, so this holds; the CAL `DEV_EXPLAINED` is emitted only at file level.
- Confirm `picp` is computed on the withheld set (registry `basis` marked
  `validation` with a `# CONFIRM` note).

## [1.8.1] - 2026-06-24

**Maintainer tooling: regenerate the standalone `fairagrodq` vocabulary from the
data-quality registries.**

A **PATCH** release. There is **no change** to pipeline behaviour, to the R
entry-point API, or to the metadata any crate emits. This release only adds a
build script.

### Added

- `tools/generate_fairagrodq_ttl.R` — generates the standalone `fairagrodq`
  SKOS/DQV vocabulary (Turtle) directly from the data-quality registries
  (`.DQ_DIMENSIONS` in `dq_vocab_core.R`; the scheme, owned predicates and
  principle concepts in `dq_uncertainty_principles.R`), reusing the same emitter
  functions (`dq_dimension_entities()`, `dq_principle_entities()`) the crate
  builders call. The published vocabulary is therefore a build artefact of the
  pipeline and cannot drift from the terms the crates emit. Only the
  `fairagrodq:`-owned terms are written; genuine ISO 19157-1 elements are
  excluded by construction. Base R only. The script underpins the separate
  `fairagrodq` vocabulary deposit.

## [1.8.0] - 2026-06-19

**Honest anchoring of spatially explicit uncertainty: a provisional
`fairagrodq:` namespace and an orthogonal expression-principle axis.**

This is a metadata-encoding / vocabulary release. There are **no numerical
changes** to any raster or to the VAM / CAL / GEM / PIC quality tables; the
changes are to how quality is *anchored and described* in the emitted crates.

### Added
- **Registry-driven data-quality engine** (`dq_vocab_core.R`). A single editable
  measure→dimension table (`.DQ_MEASURES`, `.DQ_DIMENSIONS`) is the one place
  every `dqv:inDimension` / `fairagrodq:expressedBy` target resolves against, so
  adding a measure or a new domain (digital soil mapping, crop-type
  classification) touches one table rather than the builders.
- **Orthogonal expression-principle axis** (`dq_uncertainty_principles.R`). A new
  `skos:ConceptScheme`, `fairagrodq:UncertaintyExpressionPrinciple`, defines eight
  resolvable principle concepts — `ParametricModelUncertainty`,
  `AnalyticalErrorPropagation`, `QuantileRegressionInterval`,
  `ConformalPredictionInterval`, `EnsembleSimulationSpread`,
  `EmpiricalCoverageCalibration`, `ApplicabilityDomain`, `FuzzyClassMembership` —
  each carrying a machine-readable `fairagrodq:claimStatus`,
  `fairagrodq:representation`, and `fairagrodq:assumes`. A new predicate
  `fairagrodq:expressedBy` links a measure/file to its principle. A measurement
  now records two orthogonal facts: *which aspect* of quality it concerns
  (`dqv:inDimension`) and *how it was produced and what it may claim*
  (`fairagrodq:expressedBy`). In the PHASE crate the BSE layer is expressed by
  `ParametricModelUncertainty` (model-asserted) and its PICP/MPIW calibration by
  `EmpiricalCoverageCalibration` (empirically-validated).
- Provisional cross-project namespace `fairagrodq:` =
  `https://w3id.org/fairagro/dq#`, declared in both crate `@context`s (pending
  w3id registration), plus `rdf:` / `rdfs:` prefixes to type the owned predicates
  and the concept scheme.

### Changed
- **Spatial-uncertainty dimensions migrated `dffp:` → provisional `fairagrodq:`.**
  `fairagrodq:NumericalSpatialUncertainty` (continuous attributes) and
  `fairagrodq:ClassSpatialUncertainty` (categorical maps), typed
  `dqv:Dimension` + `skos:Concept`, sit under a `fairagrodq:SpatialUncertainty`
  parent via `skos:broader`.
- **`dffp:` is now used solely for the Application-Matrix review**
  (`schema:potentialAction` / `AssessAction`), no longer for spatial-uncertainty
  dimensions. In crates without populated Application-Matrix output the action is
  a scaffold and the `dffp:` prefix carries no graph terms.

### Fixed (honest anchoring)
- **Removed the ISO 19157-1 conformance overclaim** on the spatial-uncertainty
  dimensions. ISO 19157-1:2023 does not contain a Spatial-Uncertainty element, so
  the dimensions no longer assert `dct:conformsTo` ISO 19157-1. They now declare
  `dct:isDefinedBy` Säurich et al. (2026, doi:10.1016/j.ecoinf.2026.103660) — the
  source that *proposes* the element — and are explicitly labelled *not part of
  ISO 19157-1:2023*. No IRI claims authority it does not hold.
- Genuine ISO 19157-1 accuracy elements (e.g.
  `iso19157:QuantitativeAttributeAccuracy`) remain the `dqv:inDimension` target
  for accuracy metrics (`cv_rmse`, `cv_mae`); no `skos:closeMatch` to a
  non-existent measure concept is asserted anywhere.

### Compatibility
- Pure metadata/vocabulary change; the R entry points
  (`build_phase_cog_ro_crate()`, `build_filtervariant_ro_crate()`) are unchanged.
- Already-published crates retain their original `dffp:` IRIs as historical
  record; only new builds emit the `fairagrodq:` dimensions and the principle
  axis.
- New references in the emitted vocabulary: Säurich et al. (2026,
  doi:10.1016/j.ecoinf.2026.103660); Meyer & Pebesma (2021,
  doi:10.1111/2041-210X.13650, the area-of-applicability principle).

---

## [1.7.2] - 2026-06-14

Maintenance release on top of 1.7.0 (packaging / metadata fixes). See the Zenodo
version history for the authoritative per-patch record.

## [1.7.0]

Reinstated the AGROVOC subject layer with verified URIs and a build-time guard;
made all DQV quality measures anchor honestly to ISO 19157; added a validated
calibration of the BSE uncertainty layer (PIC artefact). No numerical changes to
any raster or to the existing VAM/CAL/GEM tables — the changes are to metadata
encoding plus one new validation artefact.

## [1.6.0]

Multi-crop blueprint: a shared `_crop_specs.R` holds per-crop metadata (DWD Plant
ID, binomial, AGROVOC concept URI, Wikidata QID) for seven crops (winter wheat,
winter rye, winter barley, winter rapeseed, spring barley, oats, maize); a
family-wide creators list with explicit DataCite roles and a layered keyword
scheme; both builders are parametric on this configuration. AGROVOC subject terms
(`schema:about` / `dct:subject`) with `DefinedTerm` / `DefinedTermSet` entities
added to the `@graph`.

## [1.5.0]

Restructured the DQV quality metadata: each per-year quality measurement is now a
first-class top-level entity in the JSON-LD `@graph` with its own `@id`, and the
per-phase Datasets reference them by `@id` only — satisfying JSON-LD's
node-reference rule and resolving 33 REQUIRED-severity violations previously
reported by `roc-validator`.

## [1.4.0]

Added two published quality artefacts to Hook B (CAL, in-sample BAM model-fit
diagnostics; GEM, spatial quantiles of the BSE uncertainty raster); auto-writes a
`README.md` into each crate documenting its validation stance; generates a
self-contained `ro-crate-preview.html` for browser-based inspection without
external tooling.

## [1.3.0]

Hook B aggregates the per-(phase, year) intermediate outputs into per-phase
multi-band Cloud-Optimised GeoTIFFs (one band per year, named by year) and
wide-format per-phase VAM CSVs, reducing the published artefact count from ~896 to
21 files while preserving the per-year ISO 19157-1 quality elements through DQV
temporal tagging.

## [1.2.0]

Two in-pipeline publish hooks package the intermediate filter-variant results and
the final PHASE entry-date COGs as self-contained RO-Crate 1.2 deposits with
W3C-anchored provenance (PROV-O), dataset descriptors (DCAT 3 / Dublin Core
Terms), and quality metadata (DQV with a SKOS bridge to ISO 19157-1).

---

Releases prior to 1.2.0, and the exact contents of patch releases, predate this
changelog; the authoritative version history (with per-version DOIs and dates) is
on Zenodo: <https://doi.org/10.5281/zenodo.18743008>.
