# PhenoPhaseR v1.8.0 — Release notes

**Honest anchoring of spatially explicit uncertainty: a provisional
`fairagrodq:` namespace and an orthogonal expression-principle axis.**

This is a **MINOR** release (new vocabulary functionality + a change to the
emitted-metadata contract). It is a metadata/vocabulary change only — **there are
no numerical changes** to any raster or to the VAM / CAL / GEM / PIC quality
tables.

## Highlights

- **New expression-principle axis.** A measurement now records two orthogonal
  facts: *which aspect* of quality it concerns (`dqv:inDimension`) and *how it
  was produced and what it may claim* (`fairagrodq:expressedBy`, into the new
  `fairagrodq:UncertaintyExpressionPrinciple` SKOS scheme of eight principle
  concepts, each with a machine-readable `claimStatus`). The BSE layer is
  *model-asserted* (`ParametricModelUncertainty`); its PICP/MPIW calibration is
  *empirically-validated* (`EmpiricalCoverageCalibration`).
- **Spatial-uncertainty dimensions moved `dffp:` → provisional `fairagrodq:`**
  (`NumericalSpatialUncertainty`, `ClassSpatialUncertainty`), under a
  `fairagrodq:SpatialUncertainty` parent.
- **Removed an ISO 19157-1 overclaim.** ISO 19157-1:2023 has no Spatial-Uncertainty
  element, so the dimensions no longer assert `conformsTo` ISO. They now declare
  `dct:isDefinedBy` Säurich et al. (2026) and are explicitly *not part of
  ISO 19157-1*. Accuracy metrics still anchor to genuine ISO accuracy elements.
- **`dffp:` retained only** for the Application-Matrix fitness-for-purpose review
  (`schema:potentialAction` / `AssessAction`).

## Why MINOR, not a patch

A patch (1.7.2) covers backwards-compatible bug fixes only. This release adds new
functionality (the principle scheme and `expressedBy` predicate) and changes
which IRIs are emitted (the `dffp:`→`fairagrodq:` dimension migration), so it is a
MINOR bump — consistent with v1.5.0 and v1.7.0, which were MINOR for comparable
metadata changes.

## Compatibility

- The R entry points (`build_phase_cog_ro_crate()`,
  `build_filtervariant_ro_crate()`) are unchanged.
- Already-published crates keep their original `dffp:` IRIs; only new builds emit
  the `fairagrodq:` dimensions and the principle axis. `fairagrodq:` =
  `https://w3id.org/fairagro/dq#` is provisional (w3id registration pending).

## New references in the emitted vocabulary

- Säurich et al. (2026) — doi:10.1016/j.ecoinf.2026.103660
- Meyer & Pebesma (2021) — doi:10.1111/2041-210X.13650

Full history: [`CHANGELOG.md`](CHANGELOG.md).
