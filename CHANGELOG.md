# Changelog

All notable changes to **PhenoPhaseR** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each release is also archived on Zenodo under the concept DOI
[10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008),
which always resolves to the latest version.

---

## [1.6.3] – 2026-06-03

Patch release on top of the published v1.6.2
([doi:10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008)).
Removes the AGROVOC controlled-vocabulary subject anchors after the
hand-curated URIs in `_crop_specs.R` were found to point at unrelated
concepts when resolved against `agrovoc.fao.org` (e.g. the URI
labelled "winter rye" resolved to "sawlogs"; the URI labelled
"phenology" resolved to "local authorities"; the URI labelled
"Germany" was a different geographic concept). Also makes the
auto-written PHASE README's gap-handling section honest about whether
the chain actually fired for the build at hand, by rendering a
conditional "What this deposit reports" subsection. No changes to
the publish-hook machinery, the gap-handling chain itself, the
PROV-O lineage, the DQV quality measurements, or any numerical
output for any of the eight crops in the blueprint.

### Removed

- **AGROVOC controlled-vocabulary subject anchors.** Both publish
  hooks previously emitted `schema:about` and `dct:subject` on the
  root dataset pointing at AGROVOC concept URIs (crop species,
  phenology, growing degree days, Germany, spatial interpolation),
  with one `DefinedTerm` entity per concept and a `DefinedTermSet`
  describing AGROVOC, all assembled in `build_subject_entities()` in
  `_crop_specs.R`. When the URIs were resolved against
  `agrovoc.fao.org` for the next crop in the family, all but the
  winter-wheat URI were found to point at unrelated concepts. The
  hand-curated AGROVOC table that was the v1.6.0 highlight feature
  turned out to be substantially wrong, and the bug pattern
  ("hand-typed URI silently pointing at the wrong concept") is
  exactly what controlled-vocabulary subject anchors are supposed
  to prevent.

  Rather than swap to a different vocabulary (Wikidata, GEMET) and
  inherit the same verification burden, the controlled-vocabulary
  subject layer is removed entirely. The crates retain free-text
  `schema:keywords` / `dcat:keyword` (which Zenodo, OpenAIRE,
  BonaRes, and Google Dataset Search all index) and the GeoNames
  `spatialCoverage` URI for place anchoring. The deposits remain
  valid RO-Crate 1.2 — `schema:about` and `dct:subject` are optional
  in the profile.

  Concrete code changes:

  - `_crop_specs.R`: `agrovoc_uri` and `wikidata_qid` fields removed
    from all eight crop entries; the family-wide `.VOCAB_TERMS_CORE`
    block (phenology, GDD, spatial interpolation, Germany) removed;
    the AGROVOC DefinedTerm / DefinedTermSet builders removed;
    `build_subject_entities()` rewritten as a no-op stub returning
    empty `subject_refs` / `defined_terms` / `defined_term_set`. The
    call-site interface is preserved so a future revival of a
    controlled-vocabulary subject layer only needs the function body
    changed.
  - `build_phase_cog_ro_crate.R` and
    `build_filtervariant_ro_crate.R`: `agrovoc` namespace dropped
    from `@context`. `about` and `dct:subject` attached to the
    root dataset conditionally on
    `length(subj_bundle$subject_refs)` rather than unconditionally;
    with v1.6.3's empty stub, both keys are omitted. The
    `DefinedTermSet` and `DefinedTerm` entities are no longer in
    `@graph`.
  - `README.md`: vocabulary table no longer lists AGROVOC; the
    v1.6.0 "Multi-crop blueprint" section header is preserved but
    its AGROVOC-integration bullet carries a forward-pointer to
    this entry.

  Already-published v1.6.1 and v1.6.2 crop deposits (winter wheat
  at concept DOIs `10.5281/zenodo.19483111` and
  `10.5281/zenodo.19571847`) retain their original `schema:about`
  entries on Zenodo as historical record. The cleanup lands on
  those deposits' next coordinated re-release.

### Changed

- **PHASE README gap-handling section is now build-aware.**
  `.write_crate_readme()` in `build_phase_cog_ro_crate.R` gained a
  `gap_log` parameter; its "Temporal gaps and NA bands" section
  separates the *mechanism* (unchanged in every deposit) from a new
  conditional `#### What this deposit reports` subsection. When
  `gap_log` is empty, the subsection states "no temporal gaps were
  detected" and offers an R snippet that should return zero. When
  `gap_log` has entries, the subsection lists which (layer, phase,
  years) became NA bands and the reason for each, mirroring the
  `DQ_CompletenessOmission` measurements emitted in the manifest.
  Both code paths are exercised by end-to-end synthetic builds. The
  rewrite was prompted by the v1.6.2 winter-wheat publication
  whose README described the gap mechanism as if it had fired when
  in fact the deposit had no gaps.

### Migration

No call-site change required for the typical workflow — the
`gap_log` parameter of `.write_crate_readme()` defaults to `list()`,
and `build_subject_entities()` keeps its return-shape contract. Any
external code that consumed `schema:about` or `dct:subject` from
the published manifests will need to fall back to the
`schema:keywords` list or to the GeoNames spatial-coverage URI.

For the seven crop deposits already published against v1.6.2, no
re-publication is required by v1.6.3 itself. When you re-publish
any of them for another reason (a new year of DWD data, a corrected
DFFP review, the eventual sugar-beet deposit) the manifest will
pick up the AGROVOC removal automatically.

---

## [1.6.2] – 2026-06-02

Adds one crop to the multi-crop blueprint: **sugar beet (DWD plant
ID 253)**. The deposit family now covers eight crops in total. Also
adds resilient temporal-gap handling so a failed (phase, year)
interpolation no longer aborts the run, introduces two optional
visualization helpers driven from `PhenoPhaseR.R`, and corrects an
aspirational RO-Crate profile claim from Workflow Run Crate (which
the crates did not structurally satisfy) to Process Run Crate
(which they do). No changes to the publish-hook machinery or any
output for the existing seven crops.

### Added

- **DWD plant ID 253** (sugar beet, "Zucker-Ruebe" in the DWD
  catalogue, *Beta vulgaris* ssp. *vulgaris* var. *saccharifera*,
  Altissima cultivar group) — entry in `_crop_specs.R` with the
  AGROVOC concept URI `http://aims.fao.org/aos/agrovoc/c_7499` and
  Wikidata QID `Q151964`. German label "Zuckerrübe". *(The AGROVOC
  URI carried here was later found to be the only verifiable one
  in the table; all other URIs across the eight-crop family were
  removed in v1.6.3 after verification failed for them.)*
- Active switch line `plant <- 253; target_phases <- c(10, 12, 13, 24)`
  in `PhenoPhaseR.R` (commented out alongside the other crop switches).
  The four DWD-reported observational milestones for sugar beet are:
  10 (Bestellung Beginn = sowing), 12 (Auflaufen Beginn = emergence),
  13 (Bestand geschlossen = canopy closure), 24 (Ernte = harvest) —
  the whole crop cycle in four agronomic events.
- **Optional visualization step** in `PhenoPhaseR.R` (runs after the
  Hook B publish hook) that calls two new helper scripts from
  `function/`:
  - `plot_phenology_raster_maps.R` — renders a side-by-side
    DOY-vs-BSE raster map for one (plant, phase, year) over a named
    AOI (default `"Uckermark"`).
  - `plot_phenology_window_timeseries.R` — renders an AOI-aggregated
    phase-window time-series across the full 1993–2024 axis for
    selected milestone phases (default: phase 15 *shooting* and
    phase 18 *heading*).

  The block is guarded by `file.exists()` / `dir.exists()` checks so
  it is a no-op on systems where the per-year tiles or the helper
  scripts are not yet present. It consumes the per-year working
  files under `ro_crate_phase/_per_year/cogs/` (kept on disk for
  provenance even though they are excluded from the published flat
  layout), so it must run after Hook B has produced them.

### Changed

- **Resilient temporal-gap handling chain.** A single (phase, year)
  interpolation that fails because too few stations survived
  filtering used to abort the whole loop. The fix is a three-stage
  chain where each stage owns one responsibility:
  `filter_variant_selector.R` detects and logs to
  `opt_scores/GAPS_<plant>.csv`; `spatial_interpolation.R` writes a
  full-extent NA surface and returns `status="skipped"` instead of
  calling `stop()`; `build_phase_cog_ro_crate.R` scans every
  assembled band for all-NA content and emits one ISO 19157-1
  `DQ_CompletenessOmission` `dqv:QualityMeasurement` per affected
  COG, referenced from the root dataset's
  `dqv:hasQualityMeasurement` plus a per-band GDAL description.
  Every COG remains a complete 32-band cube where band *i* maps to
  `years[i]`.
- **RO-Crate profile claim corrected from Workflow Run Crate to
  Process Run Crate** in both publish hooks. The previous claim
  was aspirational; the crates did not include a
  `ComputationalWorkflow` entity or `mainEntity` reference, so a
  validator check against the WRROC profile would have failed.
  Process Run Crate (`https://w3id.org/ro/wfrun/process/0.5`) is
  the WRROC base profile for software applications that contribute
  to the same overall computation without engine orchestration —
  semantically a better fit for an R pipeline of coordinated steps,
  and the existing `CreateAction` with `instrument` pointing to the
  PhenoPhaseR software DOI already satisfies it unchanged. A Profile
  Crate entity for Process Run Crate v0.5 is added to `@graph` per
  the WRROC convention.
- **GDAL PAM sidecars (`.tif.aux.json`, `.tif.aux.xml`)** are
  suppressed during the Hook B build and swept before packaging.
  Their content is already in the COG's TIFF tags, so this only
  removes redundant files from the Zenodo file listing.

### Fixed

- **`jsonlite` floating-point rounding** in the manifest writer
  bumped from the default 4 to 10 significant digits, so DQV
  completeness values like 31/32 are stored exactly (`0.96875`)
  rather than truncated (`0.9688`).

---

## [1.6.1] – 2026-05-22

Patch release on top of the published v1.6.0
([doi:10.5281/zenodo.18743008](https://doi.org/10.5281/zenodo.18743008)).
Fixes a runtime crash in the v1.6.0 publish hooks, adds resilient
temporal-gap handling (interpolation no longer aborts on a
too-few-samples year; gaps are detected, NA-filled, and documented
automatically), documents the intentional Schema.org `http://`
namespace choice, and switches the Hook B (PHASE) deposit to a flat
layout so downstream pipelines can stream individual COGs from Zenodo
via GDAL's `/vsicurl/`. No numerical changes to existing rasters; no
changes to v1.6.0's multi-crop blueprint or AGROVOC integration.

### Added

- **Resilient temporal-gap handling for the PHASE pipeline.** Some
  (phase, year) interpolations cannot be produced because too few
  stations survive filtering to fit a stable surface. Previously a
  single such case aborted the whole interpolation loop (a missing
  optimal shapefile triggered a fatal `stop()`), forcing the run to
  be finished by hand. The pipeline now detects, survives, and
  documents these gaps automatically across three stages:

  1. **Detection in `filter_variant_selector.R`.** At the existing
     `min_obs` / `min_cor` gate — the point where a year's filter
     variants are all rejected — the selector now writes a row to
     `opt_scores/GAPS_<plant>.csv` recording the dropped (phase,
     year) and the precise reason (`insufficient_samples (max SN=…
     < min_obs=…)` or `low_correlation (…)`). This is the
     authoritative detection point because `min_obs` is evaluated
     here against the per-variant sample count. The log is flushed
     via `on.exit`, so a later error in the run cannot discard the
     gaps already found.

  2. **Survival in `spatial_interpolation.R`.** A new
     `skip_on_missing_input = TRUE` parameter (the default) turns the
     former fatal `stop()` on an absent input shapefile into a clean
     skip: it writes a full-extent NA DOY surface (and NA uncertainty
     surface when `uncertainty = TRUE`) on the DEM grid, looks up the
     reason from `GAPS_<plant>.csv`, and returns `status = "skipped"`
     instead of throwing.

  3. **Documentation in `build_phase_cog_ro_crate.R`.** The
     aggregator scans every assembled band for all-NA content,
     catching gaps from both sources (a tile that was never written,
     and a present-but-NA tile from a skip) and emitting one ISO
     19157-1 `DQ_CompletenessOmission` `dqv:QualityMeasurement` per
     affected COG, referenced from the root dataset's
     `dqv:hasQualityMeasurement`, plus a per-band GDAL description.
     Every COG is therefore always a complete 32-band cube where
     band *i* maps to `years[i]`.

  In `PhenoPhaseR.R`, the interpolation calls are wrapped in
  `run_interpolation()` so an *unanticipated* fit failure (singular
  fit, non-convergence) also logs-and-continues rather than aborting
  the loop, and the gap reasons from `GAPS_<plant>.csv` plus any
  caught fit-failures are assembled into `gap_spec` and passed to the
  publisher automatically. Verified end-to-end for the
  insufficient-samples skip (interpolation writes NA + logs reason),
  the present-but-NA and absent-tile cases (builder detects both and
  attaches completeness metadata), and the no-gap case (no spurious
  completeness nodes).

- **`gap_spec` parameter** on `build_phase_cog_ro_crate()` for callers
  that want to supply gap reasons directly rather than via the
  `GAPS_<plant>.csv` log. Accepts `NULL` (every NA-padded gap →
  `insufficient_samples`), a single reason string, or a
  `data.frame(phase, year, reason)` where `phase`/`year` may be `NA`
  as wildcards and the most specific row wins.

  Note on scope: this NA-padding mechanism is for **within-coverage**
  gaps — years that belong to a crop's reporting period but whose
  interpolation failed. **Out-of-coverage** periods, where a crop was
  simply not part of the DWD programme for a stretch of years (e.g.
  spring barley before 2014, oats after 2022), are *not* NA-padded;
  they are handled by setting the per-crop `years` range so the
  deposit's `temporalCoverage` states the true extent. NA means "this
  year is in scope but unknown", never "this year is out of scope".

### Fixed

- **`promise already under evaluation: recursive default argument
  reference`** crash when calling `build_filtervariant_ro_crate()` or
  `build_phase_cog_ro_crate()` from a fresh R session. The v1.6.0
  signature introduced a parameter `crop_spec = crop_spec(plant)`,
  where the parameter shadowed the lookup function of the same name
  in its own default expression. R's lazy evaluator entered a
  recursive promise when the default fired. The parameter is renamed
  to `crop` across both publish hooks and the two helpers in
  `_crop_specs.R` (`build_keywords()`, `build_subject_entities()`).
  The lookup function `crop_spec()` keeps its name and public API.
  The bug was masked in v1.6.0's smoke tests because those called the
  helpers directly with explicit arguments and never exercised the
  builders' default-argument resolution path. Verified by reproducing
  the exact error from the v1.6.0 crash report and confirming the
  rename resolves it.

### Changed

- **Hook B (PHASE) layout: flat by default.** `zip_output` default
  flipped from `TRUE` to `FALSE`. The deposit is now written as a
  flat directory of per-phase multi-band COGs
  (`cogs/DOY_<plant>-<phase>.tif`, `cogs/BSE_<plant>-<phase>.tif`)
  plus per-phase wide-format CSVs plus `ro-crate-metadata.json` and
  `README.md`. The COGs themselves keep their multi-band, multi-year
  structure — only the outer-archive delivery changes.

  Why: putting the COGs inside an outer ZIP destroyed GDAL's
  HTTP-range streaming, because ZIP's central directory is at the end
  of the archive and per-entry deflate breaks the byte-offset
  linearity COGs depend on. With the flat layout, downstream
  pipelines (e.g. WeatherIndicatoR at concept DOI 19631197) can
  stream individual years and AOIs from Zenodo without downloading
  the full deposit:

  ```r
  url <- "/vsicurl/https://zenodo.org/records/<id>/files/cogs/DOY_202-15.tif"
  doy_2020 <- terra::rast(url, lyrs = "2020")
  ```

  Set `zip_output = TRUE` to *also* produce a single-file
  bulk-download ZIP alongside the flat directory for offline or
  archival use; the ZIP is a companion, not a replacement.

  Hook A (filter variants) is unchanged — it continues to ship
  per-phase ZIPs because ESRI shapefile sets are inherently multi-file
  (`.shp` + `.shx` + `.dbf` + `.prj` + `.cpg`) and have to be bundled.

- **Auto-written Hook B README** extended with both local and
  `/vsicurl/`-streaming COG access examples (R and CLI), plus a
  recommendation to use streaming for downstream pipelines. A new
  section documents the NA-band gap convention and shows how to
  detect all-NA year-bands programmatically.

- **GDAL PAM sidecars (`.tif.aux.json` / `.tif.aux.xml`) no longer
  ship in the Hook B deposit.** terra reads each COG back after
  writing (to set band descriptions), which previously left PAM
  cache files next to the COGs. `build_phase_cog_ro_crate()` now
  disables PAM via `terra::setGDALconfig("GDAL_PAM_ENABLED" = "NO")`
  for the build and sweeps any stragglers before packaging.
  Everything the sidecars cached (band statistics, NoData, band
  names) is already in the COG's TIFF tags, so this only removes
  redundant files from the Zenodo listing.

- **`PhenoPhaseR.R` run summary** updated to announce Hook A as a
  ZIP and Hook B as a flat directory, with a short paragraph
  explaining why the two hooks differ.

### Documented

- **Schema.org namespace prefix stays at `http://schema.org/`.**
  Inline comment added to both builders' `@context` blocks explaining
  why the local `schema:` prefix is mapped to the `http://` form
  rather than the visually-more-modern `https://`. The official
  RO-Crate 1.2 context loaded as the first element of the `@context`
  array maps Schema.org terms to `http://schema.org/`. Using `https`
  for the local prefix would split Schema.org into two distinct RDF
  predicates in the expanded graph (e.g. `schema:roleName` →
  `https://schema.org/roleName` while `name` → `http://schema.org/name`).
  Verified empirically with `pyld` JSON-LD expansion.

### Migration

No call-site change required for the typical workflow — `crop` and
`creators` default from `plant`. Explicit overrides that passed the
parameter by name as `crop_spec = ...` need to update to `crop = ...`.
Affected only the (briefly-public) v1.6.0; v1.5.0 and earlier did not
have the parameter.

For Hook B (PHASE), the new default produces a flat directory
instead of an outer ZIP. Upload the contents of the directory to
Zenodo as individual files; the deposit will then be streamable via
`/vsicurl/`. If your existing publishing workflow expects a single
ZIP, set `zip_output = TRUE` — the flat directory is still produced
as the canonical output, and the ZIP becomes a companion artefact
next to it.

The published winter-wheat PHASE deposit
([doi:10.5281/zenodo.19571847](https://doi.org/10.5281/zenodo.19571847))
is currently the ZIP-wrapped layout. When republished against
v1.6.1 it will become the flat layout: a content-layer-equivalent
change (the COGs inside are byte-identical), but downstream users
with old `download.file()` + `unzip()` code paths will need a small
refactor to consume the per-file URLs via `/vsicurl/` (or to keep
downloading individual files via the Zenodo REST API).

---

## [1.6.0] – 2026-05-22

Multi-crop blueprint and AGROVOC integration. The publish hooks
become parametric on a single shared crop specification, so a
per-crop deposit family for DWD plant IDs 202, 203, 204, 205, 207,
208, and 215 can be regenerated from one codebase. Domain semantics
added via AGROVOC subject terms; quality and provenance metadata
unchanged. No numerical changes to any rasters, CSVs, or model fits.

### Added

- **`_crop_specs.R`** — new shared helper file in `function/`, sourced
  automatically by both publish hooks. Single source of truth for:
  - per-crop metadata (DWD Plant ID, English + German common name,
    binomial, AGROVOC concept URI, Wikidata QID) for the seven crops
    above, behind a `crop_spec(dwd_id)` lookup
  - family-wide AGROVOC concepts (phenology, growing degree days,
    spatial interpolation, Germany)
  - the role-aware default creators list (`default_creators(artefact)`)
  - the layered keyword scheme (`build_keywords(crop_spec, artefact)`)
  - DefinedTerm / DefinedTermSet entity builders that wrap AGROVOC
    URIs as proper JSON-LD nodes (`build_subject_entities()`)
  - Person entity builder with explicit role + affiliation
    (`build_creator_entities()`)
- **`crop_spec` and `creators` parameters** on both
  `build_filtervariant_ro_crate()` and `build_phase_cog_ro_crate()`.
  Both default sensibly from `plant`. (Note: the `crop_spec` parameter
  triggers a recursive-promise crash on first use — fixed in v1.6.1
  by renaming to `crop`.)
- **AGROVOC subject terms** on the root dataset of every crate via
  `schema:about` and `dct:subject`. Each crate emits one DefinedTerm
  entity per AGROVOC concept (crop + phenology + GDD + Germany, plus
  spatial interpolation on the PHASE side) and one shared
  DefinedTermSet entity describing AGROVOC, with `skos:exactMatch`
  cross-links to Wikidata. Resolves the Layer 6 "domain semantics"
  gap in the metadata stack.
- **`agrovoc` namespace** in the `@context` of every crate
  (`http://aims.fao.org/aos/agrovoc/`), alongside the existing W3C
  and ISO namespaces.
- **Multi-creator support** with explicit DataCite-style role
  literals (`Producer`, `DataManager`). Each creator emits one
  Person entity in the `@graph` with `schema:roleName`, `prov:role`,
  and affiliation.
- **Layered keyword scheme** applied uniformly across both crate
  kinds: a mandatory family-wide core, per-crop additions, and
  artefact-specific additions. Replaces the previous hard-coded
  `"winter wheat"` literals in both builders.
- **Per-crop output directory** in `PhenoPhaseR.R`: `output_dir`
  derives from `plant` (`~/PhenoPhaseR/output/<plant>/`), so
  switching crops keeps each crop's outputs in its own tree.
- **Crop-parametric run summary** in `PhenoPhaseR.R` using
  `crop_spec(plant)` for the human-readable crop name + binomial
  in the closing message.

### Changed

- **JKI organisation entity** unified to a single canonical
  ROR-anchored form across both builders:
  `Julius Kühn-Institut (JKI) – Federal Research Centre for
  Cultivated Plants` with ROR `022d5qt08`. Resolves the
  affiliation-string drift between the existing winter-wheat
  deposits at concept DOIs `19483111`, `19571847`, and `18743008`.
- **JKI ROR** consolidated to `022d5qt08` (was `02jx3x895` in the
  builders, while the published deposits used `022d5qt08`).

### Fixed

- **`PhenoPhaseR.R` sourcing typo** removed on the Step-6-to-Hook-A
  bridge: no longer references `build_filtervariant_ro_crate (5).R`
  (a copy-paste artefact from a download). The canonical filename
  `build_filtervariant_ro_crate.R` is used. Mirrors the equivalent
  Hook B fix in v1.4.0.

### Known issue (fixed in v1.6.1)

The `crop_spec = crop_spec(plant)` default argument on both publish
hooks crashes with `promise already under evaluation: recursive
default argument reference` on first call from a fresh R session.
Upgrade to v1.6.1 before regenerating deposits.

---

## [1.5.0] – 2026-05-20

JSON-LD-correct quality metadata structure, and a working build-time
validation gate. Resolves the structural violations that previously
caused `roc-validator` to report the crate as FAILED at the REQUIRED
severity level. Numerical outputs unchanged from v1.4.0; the manifest
shape changes.

### Added

- **`.metric_entity()`** helper in both `build_phase_cog_ro_crate.R`
  and `build_filtervariant_ro_crate.R`: emits a top-level `dqv:Metric`
  entity per unique measure name in the crate. The Metric describes
  what is being measured (e.g. RMSE in days, mapped via
  `skos:closeMatch` to ISO 19157 `DQ_ThematicAccuracy`); many
  measurements share the same Metric and reference it via
  `dqv:isMeasurementOf`. Removes ~10× redundancy compared to the
  previous inlined-per-measurement form.
- **Build-time `rocrate-validator` invocation**, gated by the
  `run_roc_validator` parameter (already present in v1.4.0, now
  exercised through to a clean verdict). Captures validator name,
  version, profile applied, severity level, and verbatim output into
  the in-crate `README.md` so the deposit carries a reproducible
  validation record.

### Changed

- **Per-year quality measurements are now first-class entities in the
  `@graph`** with their own `@id` (pattern `#qm-<plant>-<phase>-<year>-<measure>`),
  rather than inline anonymous objects under
  `schema:variableMeasured`. The per-phase Datasets reference them by
  `@id` only, which is the JSON-LD-correct shape for object references
  and what `roc-validator` requires at REQUIRED severity.
- **Per-phase Dataset `@id` changed** from path-style (e.g. `phase_202-15/`)
  to hash-style contextual entity (e.g. `#phase-202-15`). The previous
  form was interpreted by `roc-validator` as a subdirectory that must
  exist as actual files on disk; the new form correctly identifies the
  Dataset as a conceptual grouping rather than a directory.
- **`.quality_element()` signature gains `qm_id` argument** to receive
  the measurement entity's `@id`; `dqv:isMeasurementOf` is now an
  `@id`-only reference to the hoisted `dqv:Metric` entity rather than
  an inline object.
- **`.phase_dataset()` return shape changed** in both hooks from a
  single Dataset list to `list(dataset = ..., measurements = ...)`.
  The main builder hoists `measurements` into the `@graph` as
  top-level entries. No effect on call sites — the main builder
  handles the new shape internally.
- **In-crate README updated** to reflect the new manifest shape: the
  validation block now records the chosen validator profile and
  explains the relationship between the crate-declared profile
  (RO-Crate 1.2 + Workflow Run Crate) and the validator-applied
  profile (`ro-crate-1.1`, the highest the bundled profile set in
  `roc-validator` 0.9.x supports).
- **Validator-stance prose dropped** all NovaCrate-specific framing.
  The README, the deposit Zenodo descriptions, and the snippets file
  (`validator_notice_snippets.md`) now state only what was validated
  and how — they do not enumerate notices from third-party validators,
  whose rule sets vary and do not define RO-Crate 1.2 conformance.

### Fixed

- **33 REQUIRED-severity violations** previously reported by
  `roc-validator` (PyPI: `roc-validator` 0.9.0) at the `ro-crate-1.1`
  profile resolved to zero substantive violations. The remaining log
  entries in environments without network access concern fetching
  `https://w3id.org/ro/crate/1.2/context` — a network reachability
  issue, not a crate defect.
- **`rocrate-validator` profile flag** now passed explicitly via the
  new `roc_validator_profile = "ro-crate-1.1"` argument on both hooks,
  rather than relying on auto-detection (which fell back to 1.1 with
  a warning, producing a confusing "FAILED" verdict because of profile
  mismatch rather than crate content).

### Migration

No API change. Downstream code that parses `ro-crate-metadata.json`
and walks `schema:variableMeasured` arrays should expect references
of the form `{"@id": "#qm-..."}` rather than inline objects with
`schema:value` properties. To resolve the actual value, look up the
referenced `@id` in the `@graph`. Per-phase Dataset `@id`s now begin
with `#phase-` (e.g. `#phase-202-15`) instead of ending with `/`
(e.g. `phase_202-15/`).

### Why this change

Without it, the v1.4.0 deposits' README files record `roc-validator`
FAILED verdicts — which is honest but undermines the value of having
embedded the validation record in the first place. v1.5.0 is the
structural fix that makes the build-time validation gate of v1.4.0
actually pass: the validation record becomes evidence rather than a
deferred problem. ESSD manuscript reviewers, downstream consumers,
and FAIR-data archives all benefit from a deposit that can be cited
with a clean validation record.

---

## [1.4.0] – 2026-05-19

Published quality artefacts (CAL, GEM), in-crate documentation, and
self-contained HTML previews. Per-deposit validation stance is now
explicit and reviewer-readable without external tooling.

### Added

- **CAL CSVs** as a published artefact family in Hook B.
  `spatial_interpolation.R` already emits per-(phase, year) BAM in-sample
  diagnostics (AIC, BIC, EDF, deviance explained) to
  `vam/CAL_<plant>-<phase>_<year>.csv`. As of v1.4.0,
  `build_phase_cog_ro_crate()` discovers, aggregates, and publishes them
  as wide-format per-phase tables `vam/CAL_<plant>-<phase>.csv` (one row
  per year) alongside the existing VAM tables.
- **GEM CSVs** as a published artefact family in Hook B. Per-(phase,
  year) spatial quantiles of the BSE uncertainty raster
  (`Quantile ∈ {0%, 25%, 50%, 75%, 100%}`) emitted by
  `spatial_interpolation.R` to `vam/GEM_<plant>-<phase>_<year>.csv` are
  now aggregated into long-format per-phase tables
  `vam/GEM_<plant>-<phase>.csv` (five rows per year, 32 × 5 = 160 rows
  per phase) and added as File entities with `hasPart` links from the
  per-phase Dataset blocks. GEM replaces the `MEAN_BSE` column that was
  previously carried inline in VAM (removed from VAM in the 2026-04-29
  spatial_interpolation patch).
- **`README.md` auto-written into every crate** by both Hook A and Hook
  B. Embeds a contents summary, an example for reading the published
  artefacts, the recommended `roc-validator` invocation, and an explicit
  notice that advisory notices from other validators (NovaCrate;
  unresolved `dffp:` namespace) do not affect RO-Crate 1.2 conformance.
  The README is added as a File entity in the manifest and referenced
  from the root dataset's `hasPart`.
- **`ro-crate-preview.html` auto-generated by both hooks.** A pure-R
  renderer (jsonlite + base R) produces a self-contained HTML preview of
  the manifest with a table of contents, per-entity property tables,
  collapsible nested arrays, and internal cross-links between entities.
  Zero external dependencies — works offline and inside Zenodo's preview
  pane. If the Node.js tool `rochtml` happens to be on PATH it is
  preferred (richer rendering); the R fallback is otherwise transparent.
- **`generate_html_preview = TRUE` parameter** added to both
  `build_filtervariant_ro_crate()` and `build_phase_cog_ro_crate()`.
  Defaults to on; pass `FALSE` to skip explicitly.

### Changed

- **`MEAN_BSE` removed from VAM column list.** The aggregated VAM CSVs
  now carry `PLANT, PHASE, YEAR, TN, ON, VN, METHOD, BAM_K, RMSE, MAE,
  MSE, R2`. The spatial-mean-BSE summary is superseded by the long-
  format GEM table, which carries the full per-year distribution of
  prediction uncertainty rather than its mean alone.
- **Hook B `_per_year/vam/` staging extended** to CAL and GEM, mirroring
  the existing VAM behaviour. After aggregation, per-year CSVs are
  *moved* (not copied) into `_per_year/vam/` to preserve the trail on
  disk without duplicating storage. The directory remains excluded from
  the published ZIP.
- **README.md and ro-crate-preview.html are included in the published
  ZIPs.** Both are part of every Zenodo deposit as of v1.4.0.

### Fixed

- **Re-run idempotency in Hook B.** A second invocation of
  `build_phase_cog_ro_crate()` after the per-year VAM files have already
  been moved into `_per_year/vam/` no longer crashes with
  `Error in !nrow(q_phase) : invalid argument type`. The function now
  normalises `quality_table` on entry, reconstructing it by scanning
  both `<results>/vam/` and `<out_dir>/_per_year/vam/` when the
  call-site `quality_table` is `NULL` or zero-row.
- **`NROW()`-based guards** in both Hook A and Hook B per-(phase, year)
  loops replace the `!nrow(...)` pattern that was vulnerable to the
  `!NULL` trap. Subset assignments use `drop = FALSE` to guarantee a
  data frame.
- **Hook A `quality_table` defensive fallback.** When called with a
  `NULL` or empty `quality_table`, `build_filtervariant_ro_crate()` now
  attempts to recover by reading `OPT_MAX_<plant>_ALL_PHASES.csv` from
  `<results_dir>/opt_scores/` before giving up.
- **`PhenoPhaseR.R` sourcing typo** removed: the Step-7-to-Hook-B bridge
  no longer references `build_phase_cog_ro_crate (12).R` (a copy-paste
  artefact from a download); the canonical filename
  `build_phase_cog_ro_crate.R` is used.

### Migration

No behaviour change for valid inputs. Consumers of the PHASE Zenodo
deposit gain two new published artefact families (CAL, GEM); the DOY
and BSE COGs are byte-identical to v1.3.0. Code that previously read
`MEAN_BSE` from a VAM CSV should now read the corresponding row from
the GEM CSV — e.g. `Quantile == "50%"` for the per-year median BSE:

``` r
gem <- read.csv2("vam/GEM_202-15.csv")
median_bse_per_year <- gem[gem$Quantile == "50%", c("YEAR", "Value")]
```

### Why this change

CAL and GEM materially strengthen the Data-Fitness-for-Purpose (DFFP)
story: model-fit diagnostics and the full spatial distribution of
uncertainty are the evidence base downstream consumers actually need to
assess fitness-for-purpose for a specific application. Publishing them
as first-class crate entities — rather than burying them in working
folders or summarising them away — makes the DFFP application matrix
directly populable from the deposit. The in-crate README and HTML
preview pre-empt validator pushback: a reviewer who runs NovaCrate on
the deposit can read why the advisory notices are not RO-Crate
violations, and can browse the manifest in any web browser without
installing tooling.

---

## [1.3.0] – 2026-05-13

Per-phase multi-band COG aggregation in Hook B, reducing the
published artefact count of the PHASE entry-date Zenodo deposit
from ~896 to 21 files while preserving full per-year provenance.

### Added

- **`.aggregate_per_phase()`** helper in `build_phase_cog_ro_crate.R`
  stacks the per-year DOY+BSE Cloud-Optimised GeoTIFFs into per-phase
  multi-band COGs (one band per year, 1993–2024, band names equal to
  years), and concatenates the per-year VAM CSVs into one wide-format
  table per phase (one row per year). Bands carry a `time` attribute
  set to `<year>-01-01` for tools that read GeoTIFF time metadata.
- **`_per_year/` working subdirectory** under `ro_crate_phase/` holds
  the per-(phase, year) intermediate inputs. Files are *moved* (not
  copied) from `cogs/` and `vam/` into `_per_year/cogs/` and
  `_per_year/vam/` during the aggregation step, so the per-year
  provenance trail is preserved on disk without duplicating storage.
  The directory is explicitly excluded from the published
  `ro_crate_phase.zip`.
- **`terra` (>= 1.7)** added as a required dependency. Used by Hook B
  for COG stacking with `filetype="COG"` and band naming.

### Changed

- **Hook B `ro-crate-metadata.json` structure**: per-(phase, year)
  `Dataset` blocks replaced by per-phase `Dataset` blocks. Each carries
  `hasPart` references to one multi-band DOY COG, one multi-band BSE
  COG, and one wide-format VAM CSV.
- **ISO 19157-1 quality elements** remain scalar (one `dqv:value` per
  metric per year, total 7 × 32 = 224 measurements per phase) and each
  now carries `schema:temporalCoverage` and `dct:temporal` set to the
  year string. DQV consumers can group or filter measurements by year
  without losing the per-year granularity.
- **`.layer_description()`** rewritten to describe the multi-band
  structure and the recommended subsetting pattern
  (`terra::rast(file, lyrs=as.character(year))` in R, or
  `gdal_translate -b N` for the corresponding band index).
- **File entity loop** in `build_phase_cog_ro_crate()` iterates over
  the 21 aggregated artefacts (14 COGs + 7 VAM CSVs) instead of the
  ~896 per-year files.
- **Hook B ZIP construction** now explicitly enumerates publishable
  files and excludes `_per_year/`, producing a compact ZIP of ~22
  entries (21 artefacts + `ro-crate-metadata.json`).

### Migration

Code that previously read `cogs/DOY_202-10_2018.tif` should now read
band `"2018"` of `cogs/DOY_202-10.tif`. The underlying numeric data is
byte-identical. In R:

``` r
# Before:
r <- terra::rast("cogs/DOY_202-10_2018.tif")
# After:
r <- terra::rast("cogs/DOY_202-10.tif", lyrs = "2018")
```

Per-year files remain available locally under
`ro_crate_phase/_per_year/cogs/` and `ro_crate_phase/_per_year/vam/`
for any workflow that depends on the previous filename pattern.

### Why this change

The Hook B Zenodo deposit (`10.5281/zenodo.19571847`) had grown to
~896 files in v1.2.0 (7 phases × 32 years × 2 raster types + 224
CSVs), which pushed against Zenodo's per-record file-count limits and
made the landing page hard to navigate. Per-phase multi-band COGs are
the standard pattern for time-series rasters in agricultural geodata
and match the layout used in the original v1.0 publication of this
dataset. The per-year accuracy elements are preserved through DQV
temporal tagging rather than per-file granularity.

---

## [1.2.0] – 2026-05-02

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
  tool.
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

[1.6.3]: https://doi.org/10.5281/zenodo.18743008
[1.6.2]: https://doi.org/10.5281/zenodo.18743008
[1.6.1]: https://doi.org/10.5281/zenodo.20407929
[1.6.0]: https://doi.org/10.5281/zenodo.18743008
[1.5.0]: https://doi.org/10.5281/zenodo.18743008
[1.4.0]: https://doi.org/10.5281/zenodo.18743008
[1.3.0]: https://doi.org/10.5281/zenodo.18743008
[1.2.0]: https://doi.org/10.5281/zenodo.18743008
[1.1.4]: https://doi.org/10.5281/zenodo.18743008
[1.1.3]: https://doi.org/10.5281/zenodo.18743008
[1.1.2]: https://doi.org/10.5281/zenodo.18743008
[1.1.1]: https://doi.org/10.5281/zenodo.18743008
[1.1.0]: https://doi.org/10.5281/zenodo.18743008
[1.0.0]: https://doi.org/10.5281/zenodo.18743008
