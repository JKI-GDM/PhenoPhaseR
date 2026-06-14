# PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) [![R](https://img.shields.io/badge/R-%3E%3D4.0-brightgreen.svg)](https://www.r-project.org/) [![FAIR](https://img.shields.io/badge/FAIR-compliant-green.svg)](https://doi.org/10.1038/s41597-022-01710-x) [![Software DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18743008.svg)](https://doi.org/10.5281/zenodo.18743008) [![Input data DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.18594964.svg)](https://doi.org/10.5281/zenodo.18594964)

## Description

**PhenoPhaseR** is a reproducible R workflow for downloading, filtering, modelling, and spatially interpolating phenological observations provided by the German Weather Service (DWD). It implements the PHASE approach (**PH**enological model for **A**pplication in **S**patial and **E**nvironmental sciences; [Gerstmann et al. 2016](https://doi.org/10.1016/j.compag.2016.07.032)), which combines growing degree day models with geostatistical interpolation to produce area-wide phenological predictions across Germany at 1 km spatial resolution.

The workflow processes DWD phenological point observations through a seven-step pipeline: data download, station coupling, temperature extraction, effective temperature calculation, critical DOY determination, filter variant optimisation, and spatial interpolation with uncertainty quantification. Since v1.2.0, two **publish hooks** at the natural break points of the pipeline package the intermediate filter variant results and the final PHASE entry-date COGs as self-contained RO-Crate 1.2 deposits ready for Zenodo upload, with embedded W3C-anchored provenance and quality metadata. Since v1.4.0, every deposit also carries an auto-written `README.md` documenting its validation stance and a self-contained `ro-crate-preview.html` for browser-based inspection without external tooling. Since v1.6.0, both publish hooks are parametric on a single shared `_crop_specs.R` configuration, so a per-crop deposit family for DWD plant IDs 202, 203, 204, 205, 207, 208, and 215 can be regenerated from one codebase. Since v1.6.1, the PHASE deposit additionally ships as a flat directory of multi-band COGs that downstream pipelines can stream directly from Zenodo via GDAL's `/vsicurl/` without downloading the full deposit. Since v1.6.2, sugar beet (DWD plant ID 253) is also supported, corresponding to the DWD post-year-end variety-specific assignment of the generic beet observations. A single `PhenoPhaseR()` call regenerates all three Zenodo records (software, intermediate data, final data) in one CI run.

## What's new in v1.7.2

-   **Sugar beet (DWD Plant ID 253) added (patch).** Completes the eight-crop
    family — winter wheat, winter rye, winter barley, winter rapeseed, spring
    barley, oats, maize, and now sugar beet (*Beta vulgaris*; phases 10, 12,
    13, 24). Anchored to AGROVOC `sugar beet` (`c_7499`), build-verified. No
    API or behavioural change; the workflow already handled any crop in the
    table.

## What's new in v1.7.1

-   **Deposit keyword corrections (patch).** PHASE deposits gain
    validated-uncertainty and method keywords (`uncertainty quantification`,
    `predictive uncertainty`, `prediction interval`, `cross-validation`,
    `calibration`, `GAM`, `COG`) matching the calibrated uncertainty layer from
    1.7.0; filter-variant deposits gain intermediate-product terms (`station
    filtering`, `outlier detection`) but no uncertainty/COG terms they do not
    contain. The inaccurate `BBCH` keyword is removed (DWD phase codes are
    crop-specific, not BBCH), and the temporal keyword is now derived from each
    deposit's actual year range instead of a hard-coded span. No code or
    numerical changes.

## What's new in v1.7.0

-   **AGROVOC subject layer reinstated — this time verified.** The v1.6.3 release removed AGROVOC after discovering most of the hand-typed URIs were wrong. v1.7.0 brings it back with every URI resolved against `agrovoc.fao.org` and corrected, plus a build-time guard (`verify_agrovoc_uris()`) that resolves each URI against the live catalogue and reports any that no longer match the concept they claim. Of the original ten URIs, only winter wheat and maize had been correct; the other seven (winter rye, both barleys, rapeseed, oats, phenology, growing degree days, Germany) are now fixed. Winter rye and winter rapeseed anchor to the generic species concept because AGROVOC has no winter-specific entry — the season is carried by the DWD Plant ID and the keyword (`agrovoc_is_generic = TRUE`). "Spatial interpolation" has no AGROVOC concept and stays a free-text keyword. PHASE deposits additionally anchor `spatial data` (family) and `statistical uncertainty` (for the BSE layer). The verifier is throttled and 429-aware, so a busy AGROVOC server can never make a correct URI look broken; `PhenoPhaseR.R` runs it report-only by default and CI can set it to halt on mismatch.
-   **Honest DQV measure anchoring.** Quality measures no longer mint `iso19157:cv_rmse`-style property IDs — there is no `cv_rmse` (or `picp`, `training_n`, …) concept in ISO 19157, so those IRIs resolved to nothing. `schema:propertyID` now carries the bare measure token and the only ISO IRIs referenced are the genuine dimension *classes* (`DQ_ThematicAccuracy`, `DQ_UsabilityElement`, `DQ_CompletenessOmission`, `DQ_LogicalConsistency`), linked via `dqv:inDimension` on the metric entity. Applied uniformly across both publish hooks, so the encoding stays coherent while every IRI resolves to something real. This is the "own the measure, anchor the dimension class" posture — adopted as a principle without committing to any unregistered namespace.
-   **Validated calibration of the BSE uncertainty layer (PIC), k-fold cross-validated.** The BSE COG is the posterior standard error of the BAM fit — a *model-internal* statistical uncertainty, honestly anchored to AGROVOC `statistical uncertainty`. v1.7.0 adds a separate, *validated* statement of how well-calibrated that layer is, computed by a dedicated k-fold cross-validation (default 5 folds) that is independent of the production fit. The published DOY/BSE rasters are built from all stations; the calibration holds each station out exactly once across the folds, refits the BAM on the rest, predicts at the held-out stations with `se.fit`, and pools the out-of-fold results — so the product is never degraded to obtain the calibration. `spatial_interpolation.R` writes `PIC_<plant>-<phase>_<year>.csv` with **PICP** (pooled out-of-fold coverage at nominal 90%) and **MPIW** (mean interval width). The interval combines each fold's `se.fit` with the production all-data residual variance (`1.645·√(se_fit² + σ²)`), because the SE alone is the SE of the *fitted mean* and omits the residual scatter individual stations exhibit — using it alone would understate coverage and mislabel a confidence interval as a prediction interval. New `calibrate` (default TRUE for BAM, independent of `validation`/`uncertainty`) and `n_folds` (default 5) arguments control it. `build_phase_cog_ro_crate.R` surfaces `picp`/`mpiw` as DQV measurements under `DQ_UsabilityElement`, each tied to the BSE COG via `dqv:computedOn`. So a consumer can distinguish *what the layer is* (model-internal uncertainty) from *how well-calibrated it turned out* (validated coverage) — two honest statements at the right levels.
-   **Honest DQV measure anchoring.** Quality measures no longer mint `iso19157:cv_rmse`-style property IDs — there is no `cv_rmse` (or `picp`, `training_n`, …) concept in ISO 19157, so those IRIs resolved to nothing. `schema:propertyID` now carries the bare measure token and the only ISO IRIs referenced are the genuine dimension *classes* (`DQ_ThematicAccuracy`, `DQ_UsabilityElement`, `DQ_CompletenessOmission`, `DQ_LogicalConsistency`), linked via `dqv:inDimension` on the metric entity. Applied uniformly across both publish hooks, so the encoding stays coherent while every IRI resolves to something real.
-   **No numerical changes** to any raster or to the VAM/CAL/GEM tables. Already-published deposits are immutable and keep their original encoding as historical record; future builds emit the v1.7.0 metadata, and the existing records pick it up when re-published in the coordinated ESSD release.

## What's new in v1.6.3

-   **AGROVOC controlled-vocabulary subject anchors removed.** The v1.6.0 highlight feature — `schema:about` / `dct:subject` on the root dataset pointing at AGROVOC concept URIs (crop species, phenology, GDD, Germany, spatial interpolation) with one `DefinedTerm` entity per concept and a shared `DefinedTermSet` describing AGROVOC — turned out to be substantially wrong when the URIs were resolved against `agrovoc.fao.org`: the URI labeled "winter rye" resolved to "sawlogs"; the one labeled "phenology" resolved to "local authorities"; the one labeled "Germany" was a different geography. Only the winter-wheat URI verified correctly. Rather than swap to a different vocabulary (Wikidata, GEMET) and inherit the same verification burden — controlled-vocabulary subject anchoring is supposed to *prevent* exactly the typo-points-at-wrong-concept bug we found — the entire subject-anchor layer is removed. The crates retain free-text `keywords` / `dcat:keyword` (which Zenodo, OpenAIRE, BonaRes, and Google Dataset Search all index) and the GeoNames `spatialCoverage` URI for place anchoring. The deposits remain valid RO-Crate 1.2; `schema:about` and `dct:subject` are optional in the profile. Concretely: `agrovoc_uri` and `wikidata_qid` fields are removed from every crop entry in `_crop_specs.R`; the family-wide AGROVOC concepts block, the `DefinedTerm` / `DefinedTermSet` builders, and the `agrovoc` namespace in both builders' `@context` are all removed; `build_subject_entities()` is preserved as a no-op stub returning empty bundles so the call-site interface stays stable in case a future release re-introduces a verified subject vocabulary. Already-published v1.6.1 and v1.6.2 crop deposits retain their original `schema:about` entries on Zenodo as historical record; the cleanup will land on their next coordinated re-release.
-   **Auto-written PHASE README's gap-handling section is now build-aware.** `.write_crate_readme()` in `build_phase_cog_ro_crate.R` separates the gap-handling *mechanism* (unchanged in every deposit) from a conditional "What this deposit reports" subsection. When the gap log is empty, the subsection states "no temporal gaps were detected" and offers a verification R snippet that should return zero; when the gap log has entries, it lists which (layer, phase, year) combinations became NA bands and the reason for each, mirroring the `DQ_CompletenessOmission` measurements emitted in the manifest. The rewrite was prompted by the v1.6.2 winter-wheat publication whose auto-written README described the gap mechanism as if it had fired, when in fact the deposit had no gaps.
-   **No numerical changes** to any output for any crop. No changes to the publish-hook machinery, the gap-handling chain, the PROV-O lineage, or the DQV quality measurements.

## What's new in v1.6.2

-   **Resilient temporal-gap handling.** A (phase, year) whose interpolation fails because too few stations survived filtering no longer aborts the run. The filter-variant selector logs the dropped cell and its reason to `opt_scores/GAPS_<plant>.csv`; `spatial_interpolation()` skips a missing input cleanly (writing a full-extent NA surface instead of calling `stop()`); and the Hook B publisher detects every all-NA band and records it as an ISO 19157-1 `DQ_CompletenessOmission` measurement. Every COG stays a complete 32-band cube with band *i* mapping to year *i*, so `terra::rast(file, lyrs = "2020")` returns a clean NA layer rather than throwing. *Within-coverage* failures (a year that belongs to the crop's reporting period) become NA bands; *out-of-coverage* periods (a crop simply not reported for a stretch of years) are instead handled by setting the per-crop `years` range, so `temporalCoverage` states the true extent. NA always means "in scope but unknown", never "out of scope".
-   **Sugar beet (DWD plant ID 253) added** to the multi-crop blueprint, bringing the deposit family to eight crops. Four DWD-reported observational milestones: 10 (Bestellung Beginn = sowing), 12 (Auflaufen Beginn = emergence), 13 (Bestand geschlossen = canopy closure), 24 (Ernte = harvest). DWD's authoritative phase catalogue (`PH_Beschreibung_PflanzePhase.txt`) maps plant ID 252 to *Futter-Ruebe* (fodder beet) and 253 to *Zucker-Ruebe* (sugar beet); fodder beet is not included in this release.
-   **RO-Crate profile claim corrected to Process Run Crate.** The previous claim (Workflow Run Crate) was aspirational — the crates did not include a `ComputationalWorkflow` entity or `mainEntity` reference, so a `roc-validator --profile workflow-run-crate` check would have failed. Process Run Crate (`https://w3id.org/ro/wfrun/process/0.5`) is the WRROC base profile for "execution of one or more software applications that contribute to the same overall computation, but are not necessarily coordinated by a top-level workflow or script" — semantically a better fit for an R pipeline of coordinated steps, and the existing `CreateAction` with `instrument` pointing to the PhenoPhaseR software DOI already satisfies it unchanged. A Profile Crate entity for Process Run Crate v0.5 is added to `@graph` per the WRROC convention. Upgrading to Workflow Run Crate proper remains mechanical if it ever becomes useful (FAIRagro's planned predefined-workflow platform is the most plausible trigger).
-   **GDAL PAM sidecars suppressed.** `.tif.aux.json` and `.tif.aux.xml` no longer ship in the Hook B deposit — their content (band statistics, NoData, band names) is already in the COG's TIFF tags. PAM is disabled during the build via `terra::setGDALconfig("GDAL_PAM_ENABLED" = "NO")` and any straggler files are swept before packaging.
-   **DQV completeness fractions stored exactly.** The manifest writer's `jsonlite::write_json` digits parameter is bumped from the default to 10, so values like 31/32 are written as `0.96875` rather than truncated to `0.9688`.
-   **Optional visualization step** in `PhenoPhaseR.R` (runs after Hook B), with two new helper scripts in `function/`: `plot_phenology_raster_maps.R` for a side-by-side DOY/BSE map over a named AOI, and `plot_phenology_window_timeseries.R` for an AOI-aggregated phase-window time-series across 1993–2024. The block is guarded by `file.exists()` checks so it is a no-op when the inputs or helpers are absent.
-   **DWD phase IDs ≠ BBCH numbers** — added clarifying documentation throughout. DWD phase IDs are operational observation codes from `PH_Beschreibung_Phase.txt`, with codes meaning the same observational event across crops (10 = sowing, 12 = emergence, 24 = harvest universally). They *correspond* to BBCH numerically for many cereal stages but are not identical. A downstream user mapping PHASE COGs to BBCH for cross-dataset analysis should use `PH_Beschreibung_Phase.txt` as the translation table.
-   **No numerical changes** to existing rasters from v1.6.1 for any of the seven crops already published; no changes to the PROV-O chain or v1.6.1's flat Hook B layout.

## What's new in v1.6.1

-   **Bug fix.** The v1.6.0 publish hooks crashed on first call from a fresh R session with `promise already under evaluation: recursive default argument reference` — the `crop_spec = crop_spec(plant)` default shadowed the helper function in its own default expression. The parameter is renamed to `crop`; existing call sites that rely on the default need no change.
-   **Hook B (PHASE) ships flat by default.** `zip_output` now defaults to `FALSE`. The deposit is a flat directory of per-phase multi-band COGs + CSVs + `ro-crate-metadata.json`, uploaded to Zenodo as individual files. This preserves GDAL `/vsicurl/` streaming for downstream pipelines like WeatherIndicatoR — they can read one year or one AOI without downloading the full deposit. Multi-band, multi-year COG structure unchanged; only the outer-archive delivery changes. Set `zip_output = TRUE` to also produce a single-file bulk-download ZIP next to the flat directory. Hook A continues to use per-phase ZIPs because ESRI shapefile sets are inherently multi-file.
-   **Schema.org namespace prefix documented as `http://schema.org/`** intentionally, with an inline comment in both builders. The official RO-Crate 1.2 context loaded above uses the `http://` form, so a local `https://` prefix would split Schema.org into two distinct RDF predicates in the expanded graph. Verified empirically with `pyld`.
-   **Auto-written Hook B README** extended with both local and `/vsicurl/`-streaming COG access examples (R and CLI), plus a recommendation to use streaming for downstream pipelines.
-   **No numerical changes** to existing rasters from v1.6.0. The changes are the `crop_spec`→`crop` parameter rename, Hook B's outer file layout, and documentation.

## What's new in v1.6.0

-   **Multi-crop blueprint via `_crop_specs.R`.** A new shared helper file in `function/` holds per-crop metadata (DWD Plant ID, English + German common name, binomial) for the seven crops above, the family-wide creators list, and the layered keyword scheme. Both publish hooks source it automatically. Switching crops is now a single-line edit at the top of `PhenoPhaseR.R`; the whole pipeline — including crate metadata — reconfigures consistently. *(v1.6.0 also added AGROVOC URI and Wikidata QID fields per crop; these were removed in v1.6.3 — see the v1.6.3 entry above for why.)*
-   **AGROVOC subject terms** added to the root dataset of every crate via `schema:about` and `dct:subject`, with one `DefinedTerm` entity per AGROVOC concept (crop + phenology + GDD + Germany, plus spatial interpolation on the PHASE side) and a shared `DefinedTermSet` entity describing AGROVOC, with `skos:exactMatch` cross-links to Wikidata. *(**Removed in v1.6.3** after the hand-curated URIs were found to point at unrelated concepts on resolution. The v1.6.3 deposits use only free-text keywords and the GeoNames spatial-coverage URI for subject anchoring. See the v1.6.3 entry above for full rationale.)*
-   **Multi-creator support** with explicit DataCite-style role literals. Each creator emits one `Person` entity with `schema:roleName`, `prov:role`, and ROR-anchored affiliation. Resolves the previous asymmetry between the filter-variant and PHASE deposits (one vs. three creators on the same campaign).
-   **Layered keyword scheme** applied uniformly across both crate kinds: a mandatory family-wide core, per-crop additions, and artefact-specific additions. Replaces the previous hard-coded `"winter wheat"` literals in both builders.
-   **Per-crop output directory** in `PhenoPhaseR.R`: `output_dir` derives from `plant` (`~/PhenoPhaseR/output/<plant>/`), so switching crops keeps each crop's outputs in its own tree.
-   **JKI organisation entity unified** to the canonical ROR-anchored form `Julius Kühn-Institut (JKI) – Federal Research Centre for Cultivated Plants` (ROR `022d5qt08`) across both builders. Resolves the affiliation-string drift between the existing winter-wheat deposits.
-   **`PhenoPhaseR.R` sourcing typo** removed on the Step-6-to-Hook-A bridge (`build_filtervariant_ro_crate (5).R` → `build_filtervariant_ro_crate.R`), mirroring the v1.4.0 fix on the Hook B side.
-   **No numerical changes.** DOY, BSE, VAM, CAL, GEM, and OPT CSV contents are byte-identical to v1.5.0. The change is purely in `ro-crate-metadata.json`'s subject layer, creator structure, and keyword set.

## What's new in v1.5.0

-   **JSON-LD-correct quality metadata.** Per-year quality measurements (RMSE, MAE, R², BSE quantiles, OPT scores, etc.) are now first-class entities in the `@graph` of `ro-crate-metadata.json` with their own `@id` (pattern `#qm-<plant>-<phase>-<year>-<measure>`). Per-phase Datasets reference them by `@id` only, which is the shape JSON-LD and `roc-validator` require for object references. The previous v1.4.0 inline-anonymous-object form caused 33 REQUIRED-severity validator violations; v1.5.0 resolves them all.
-   **Build-time `roc-validator` gate now passes.** The validation record embedded in each crate's `README.md` (introduced in v1.4.0) now reads PASSED rather than FAILED, with full version + profile + verbatim output for verification.
-   **Hoisted `dqv:Metric` entities.** One Metric per unique measure name in the crate, shared by all measurements via `dqv:isMeasurementOf`. Removes \~10× redundancy in the JSON and gives DQV consumers a stable identifier to group by.
-   **Per-phase Dataset `@id`s use the hash-prefixed contextual-entity form** (`#phase-202-15`) instead of the path-suffixed form (`phase_202-15/`). The previous form was interpreted by validators as a subdirectory expected to exist on disk; the hash form correctly identifies the Dataset as a conceptual grouping.
-   **Validator-stance prose is tool-agnostic.** The README, the Zenodo deposit description text, and the validator-notice snippets file no longer single out any third-party validator. The deposit states which validator + version + severity + profile was applied, embeds the verbatim output, and disclaims responsibility for advisory notices from tools whose rule sets vary.
-   **No numerical changes.** DOY, BSE, VAM, CAL, and GEM CSV contents are byte-identical to v1.4.0. The change is purely in `ro-crate-metadata.json`'s structure.

## What's new in v1.4.0

-   **CAL and GEM published as first-class crate artefacts.** Hook B now discovers, aggregates, and publishes the per-(phase, year) BAM in-sample diagnostics (`vam/CAL_<plant>-<phase>_<year>.csv`) and BSE spatial quantiles (`vam/GEM_<plant>-<phase>_<year>.csv`) emitted by `spatial_interpolation.R`. Each per-phase Dataset block gains two new `hasPart` entries: a wide-format CAL table (one row per year, columns `BAM_K, AIC, BIC, EDF, DEV_EXPLAINED`) and a long-format GEM table (five rows per year, columns `YEAR, Quantile, Value`). DOY and BSE rasters are byte-identical to v1.3.0.
-   **In-crate README.md.** Both hooks auto-write a `README.md` into the deposit at build time, documenting the contents, a worked example for reading the artefacts, and an explicit validation stance (`roc-validator` REQUIRED-clean; advisory notices from NovaCrate are not RO-Crate 1.2 violations).
-   **`ro-crate-preview.html` shipped with every deposit.** A pure-R renderer (`jsonlite` + base R) produces a self-contained, browser-renderable HTML preview of the manifest with a table of contents, per-entity property tables, and internal cross-links. Zero external dependencies — works offline, in any browser, and inside Zenodo's preview pane.
-   **`MEAN_BSE` removed from VAM**, superseded by GEM. The full per-year distribution of prediction uncertainty (quantiles 0/25/50/75/100%) replaces the scalar spatial mean. To recover the per-year median BSE, read the GEM CSV and filter `Quantile == "50%"`.
-   **Hardened build hooks.** Re-runs of `build_phase_cog_ro_crate()` are now idempotent — the previously crashing `Error in !nrow(q_phase) : invalid argument type` after the per-year files had been moved into `_per_year/vam/` is fixed by reconstructing `quality_table` from disk. Hook A gains the same defensive fallback (reads `OPT_MAX_<plant>_ALL_PHASES.csv` if no `quality_table` is supplied).
-   **New parameter** `generate_html_preview = TRUE` on both hooks; pass `FALSE` to skip the HTML preview generation explicitly.

## What's new in v1.3.0

-   **Per-phase multi-band COG aggregation in Hook B.** `build_phase_cog_ro_crate()` now aggregates the per-(phase, year) intermediate outputs into per-phase multi-band Cloud-Optimised GeoTIFFs (one band per year, band names = years) and wide-format per-phase VAM CSVs (one row per year). The published artefact count of the PHASE entry-date Zenodo deposit drops from \~896 to 21 files.
-   **`_per_year/` working subdirectory** preserves the per-(phase, year) intermediates on disk for any workflow that depends on the previous filename pattern, while being excluded from the published `ro_crate_phase.zip`.
-   **Per-year ISO 19157-1 quality preserved.** Each scalar `dqv:QualityMeasurement` now carries `schema:temporalCoverage` and `dct:temporal` set to the year string, so DQV consumers can group or filter measurements by year without losing the per-year granularity. 7 metrics × 32 years = 224 quality measurements per phase.
-   **New dependency.** `terra` (\>= 1.7) is required by Hook B for COG stacking with `filetype="COG"` and band naming.
-   **Migration.** Code that previously read `cogs/DOY_202-10_2018.tif` should now read band `"2018"` of `cogs/DOY_202-10.tif`: `r     # Before:     r <- terra::rast("cogs/DOY_202-10_2018.tif")     # After:     r <- terra::rast("cogs/DOY_202-10.tif", lyrs = "2018")`

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
│   ├── build_phase_cog_ro_crate.R          # Hook B: package Step 7 outputs as RO-Crate
│   └── _crop_specs.R                       # Shared crop specs, creators, keywords
                                            #   (auto-sourced by both publish hooks; v1.6.0+)
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
| **A** | `build_filtervariant_ro_crate()` | 6 | `shapefiles/`, `opt_scores/`, in-crate `README.md` + `ro-crate-preview.html` | [10.5281/zenodo.19483111](https://doi.org/10.5281/zenodo.19483111) |
| **B** | `build_phase_cog_ro_crate()` | 7 | `cogs/` (per-phase multi-band DOY+BSE), `vam/` (per-phase wide-format VAM+CAL, long-format GEM), in-crate `README.md` + `ro-crate-preview.html` | [10.5281/zenodo.19571847](https://doi.org/10.5281/zenodo.19571847) |

Both hooks emit `ro-crate-metadata.json`, an in-crate `README.md` documenting the deposit and its validation stance, a self-contained `ro-crate-preview.html` (browser-renderable, zero external dependencies), plus a `<crate>.zip` ready for upload as a "new version" on the corresponding Zenodo record. The crates declare `isBasedOn` / `prov:wasDerivedFrom` links so that the three Zenodo records (software → filter variants → PHASE COGs) form a connected PROV-O graph. Hook B additionally embeds DFFP `schema:Review` entries when `dffp_dir` is supplied. As of v1.3.0, Hook B aggregates the per-(phase, year) intermediate outputs from Step 7 into per-phase multi-band COGs (one band per year) and wide-format per-phase VAM CSVs (one row per year). As of v1.4.0, the same aggregation pattern is extended to the CAL (in-sample BAM diagnostics) and GEM (BSE spatial quantiles) CSV families emitted by `spatial_interpolation.R`, and every crate ships with an in-crate `README.md` and a self-contained `ro-crate-preview.html`. The per-(phase, year) intermediates remain available locally under `output/ro_crate_phase/_per_year/`.

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
| 207 | Spring barley       | Sommergerste  |
| 208 | Oats                | Hafer         |
| 215 | Maize               | Mais          |
| 253 | Sugar beet          | Zuckerrübe    |

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
| `vam/` | `VAM_<plant>-<phase>_<year>.csv` | Per-year holdout cross-validation metrics (`PLANT, PHASE, YEAR, TN, ON, VN, METHOD, BAM_K, RMSE, MAE, MSE, R2`) | CSV |
| `vam/` | `CAL_<plant>-<phase>_<year>.csv` | Per-year BAM in-sample diagnostics (`PLANT, PHASE, YEAR, BAM_K, AIC, BIC, EDF, DEV_EXPLAINED`); emitted on every BAM run | CSV |
| `vam/` | `GEM_<plant>-<phase>_<year>.csv` | Per-year spatial quantiles of the BSE uncertainty raster (`Quantile, Value`; five rows: 0/25/50/75/100%); emitted when `uncertainty = TRUE` | CSV |
| `splits/` | `TRAIN_<plant>-<phase>_<year>.shp` | Training stations (75% holdout split) | Shapefile |
| `splits/` | `TEST_<plant>-<phase>_<year>.shp` | Validation stations | Shapefile |

**Hook A and Hook B publish-ready outputs**

| Path | File pattern | Description | Format |
|----|----|----|----|
| `ro_crate_filtervariants.zip` | – | Hook A publish-ready RO-Crate (Zenodo upload) | ZIP |
| `ro_crate_phase/cogs/` | `DOY_<plant>-<phase>.tif` | **Aggregated** per-phase DOY raster: multi-band COG, 32 bands (one per year 1993–2024), band names = years | Cloud-Optimized GeoTIFF |
| `ro_crate_phase/cogs/` | `BSE_<plant>-<phase>.tif` | **Aggregated** per-phase BSE uncertainty raster, 32 bands matching the DOY bands | Cloud-Optimized GeoTIFF |
| `ro_crate_phase/vam/` | `VAM_<plant>-<phase>.csv` | **Aggregated** per-phase holdout cross-validation table: one row per year, wide format | CSV |
| `ro_crate_phase/vam/` | `CAL_<plant>-<phase>.csv` | **Aggregated** per-phase BAM in-sample diagnostics: one row per year, wide format (v1.4.0+) | CSV |
| `ro_crate_phase/vam/` | `GEM_<plant>-<phase>.csv` | **Aggregated** per-phase BSE spatial quantiles: five rows per year (32 × 5 = 160), long format (v1.4.0+) | CSV |
| `ro_crate_phase/` | `README.md` | In-crate contents summary and validation-stance notice (v1.4.0+) | Markdown |
| `ro_crate_phase/` | `ro-crate-preview.html` | Self-contained browser-renderable preview of the RO-Crate manifest (v1.4.0+) | HTML |
| `ro_crate_phase/_per_year/` | various | Working subdirectory: per-(phase, year) intermediates moved here by the aggregation step. Excluded from the ZIP. | – |
| `ro_crate_phase.zip` | – | Hook B publish-ready RO-Crate (Zenodo upload), 35 artefacts + README + preview + metadata | ZIP |

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
| **RO-Crate 1.2** (Process Run Crate profile) | `https://w3id.org/ro/crate/1.2/context` | Top-level container profile |
| **DCAT 3** (W3C) | `http://www.w3.org/ns/dcat#` | Dual typing on Datasets (`dcat:Dataset`) |
| **DCT** (Dublin Core Terms) | `http://purl.org/dc/terms/` | Coverage, licensing, agent aliases |
| **DQV** (W3C Data Quality Vocabulary) | `http://www.w3.org/ns/dqv#` | Quality measurements, metrics, dimensions |
| **PROV-O** (W3C Provenance Ontology) | `http://www.w3.org/ns/prov#` | Workflow provenance (`prov:Activity`, `prov:used`, `prov:wasGeneratedBy`) |
| **SKOS** (W3C) | `http://www.w3.org/2004/02/skos/core#` | `skos:prefLabel` on DQV metrics; `skos:exactMatch` from AGROVOC `DefinedTerm`s to Wikidata where applicable |
| **ISO 19157-1** | `http://standards.iso.org/iso/19157/-1/` | Quality *dimension classes* only (`DQ_ThematicAccuracy`, `DQ_UsabilityElement`, `DQ_CompletenessOmission`, `DQ_LogicalConsistency`), referenced via `dqv:inDimension`. As of v1.7.0 no `iso19157:<measure>` IRIs are minted — measures are owned locally; only the real dimension classes are referenced |
| **Schema.org** | `http://schema.org/` | Carrier for entities without W3C equivalents (Person, Organization, License) |
| **SPDX** | `http://spdx.org/rdf/terms#` | File checksums |
| **GeoNames** | `https://www.geonames.org/` | Place identifier on `spatialCoverage` |
| **AGROVOC** (FAO) | `http://aims.fao.org/aos/agrovoc/` | Subject anchors (`schema:about` / `dct:subject`) for crop species, phenology, GDD, spatial data, statistical uncertainty, Germany. Every URI verified against the live catalogue at build time (`verify_agrovoc_uris()`); reinstated in v1.7.0 |

Quality elements are exposed simultaneously through `schema:variableMeasured` (Schema.org) and `dqv:hasQualityMeasurement` (W3C DQV), referencing the same node array — no duplication, no drift.

## Citation

If you use this software in your research, please cite:

> Möller, M. & Gerstmann, H. (2026). *PhenoPhaseR: Reproducible processing workflow for interpolating phenological DWD observations* (v1.7.2). Zenodo. <https://doi.org/10.5281/zenodo.18743008>

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

| Package       | Purpose                                                 | CRAN |
|---------------|---------------------------------------------------------|------|
| sf            | Spatial data handling (modern standard)                 | ✅   |
| raster        | Raster I/O and operations                               | ✅   |
| sp            | Legacy spatial classes (interoperability)               | ✅   |
| automap       | Automatic variogram fitting and kriging                 | ✅   |
| fields        | Thin-plate spline interpolation                         | ✅   |
| mgcv          | GAM/BAM spatial smoothing with uncertainty              | ✅   |
| caret         | Training/test data partitioning                         | ✅   |
| MLmetrics     | Accuracy metrics (RMSE, MAE, MSE)                       | ✅   |
| ggplot2       | Diagnostic visualisations                               | ✅   |
| rnaturalearth | Country boundary geometries                             | ✅   |
| **jsonlite**  | **RO-Crate JSON-LD generation (Hooks A and B)**         | ✅   |
| **terra**     | **Per-phase multi-band COG stacking (Hook B, \>= 1.7)** | ✅   |
| gtools        | Mixed-order sorting in filter selector                  | ✅   |
| geosphere     | Photoperiod weighting (`daylength()`) in GDD            | ✅   |

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
