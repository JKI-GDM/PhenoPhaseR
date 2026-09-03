# PhenoPhaseR v1.9.1 — Release notes

**The measure IRIs the crates emit now resolve.** The generated `fairagrodq`
vocabulary published dimensions and expression principles but not the measures
that sit between them, so a consumer following a measure IRI out of a crate
arrived at nothing.

This is a **PATCH** release for the pipeline. The RO-Crates it emits are
**unchanged** — no PhenoPhaseR measurement uses the added tokens or the added
`basis` label, so re-running against unchanged data reproduces byte-identical
crate metadata. The standalone `fairagrodq` vocabulary advances **0.1.0 → 0.3.0**
on its own version line.

## What was missing

The registered route has three levels: a **dimension** (which aspect of quality
is meant), an **expression principle** (how the number was produced and what it
may claim), and the **measure** itself. Since v1.8.0 the vocabulary emitted the
first two. The third was only ever a key in `.DQ_MEASURES` — real inside the R
session, absent from the published Turtle.

The consequence was narrow but real: a crate emits `fairagrodq:picp`, a consumer
dereferences `https://w3id.org/fairagro/dq#picp`, and the vocabulary has no
statement about it. The definition existed, in the registry, in prose, in the
crate's own README — everywhere except the one place a machine would look. For a
project whose argument is that quality claims should be resolvable rather than
asserted, that gap sat in the wrong place.

Separately, the `w3id.org/fairagro/dq` registration completed, so the "pending"
qualifier in the README was stale.

## What changed

- **`tools/generate_fairagrodq_ttl.R` gains step 5b.** Every registry measure
  whose `dimension` is `fairagrodq:`-owned is emitted as a
  `dqv:Metric`/`skos:Concept` node with `skos:prefLabel`, `skos:definition`,
  `dqv:inDimension`, `skos:note` (unit, where set) and `dct:isDefinedBy` (where
  set). Where the measure's `basis` maps onto an expression principle, the node
  also carries `fairagrodq:expressedBy`: `propagated` →
  `AnalyticalErrorPropagation`, `cross-validation` / `validation` →
  `EmpiricalCoverageCalibration`. Measures on ISO-anchored dimensions are
  excluded by construction, as before — the vocabulary still declares only what
  it owns.
- **Three propagated-uncertainty measures** are registered (`u_pheno`,
  `u_precip`, `u_total`) in both `dq_vocab_core.R` and `dq_measures_registry.R`,
  each declaring `dct:isDefinedBy` WeatherIndicatoR (10.5281/zenodo.19631197).
  PhenoPhaseR does not compute them. They are here because the vocabulary is
  generated from this registry and the registry is the shared source of truth
  across the two pipelines; a term used in a WeatherIndicatoR crate has to
  resolve too.
- **A `propagated` basis label**, rendered as "analytical error propagation
  (model-asserted, unvalidated)". The parenthetical is the point: a propagated σ
  is a model assertion, not a coverage check, and saying so at the point of use
  keeps the distinction from resting on the expression-principle axis alone.
- **`fairagrodq.ttl` is vendored at the repository root** (v0.3.0, generated
  2026-08-20). Previously a build artefact only. Shipping it makes the terms
  readable without running R and makes vocabulary drift visible in a diff.
- **Two standalone figure scripts** (`plot_accuracies_per-crop.R`,
  `plot_winterwheat_accuracy_uncertainty.R`). Not wired into the driver.
- **README** records the resolved namespace and an accurate repository layout;
  **`.zenodo.json`**, which had been left at v1.8.1 describing v1.8.0, is brought
  up to the 1.9.x line.

## Why patch, not minor

The versioning policy treats a change that adds vocabulary terms or alters which
IRIs are emitted as MINOR. This release adds terms — so the reading matters, and
it is recorded here rather than left implicit.

Scoped to **the crates**, nothing changed: no PhenoPhaseR measurement uses
`u_pheno`, `u_precip`, `u_total` or the `propagated` basis, the builders are
untouched, and a re-run emits byte-identical metadata. Scoped to **the generated
vocabulary**, terms and a new node class were added, which under the letter of
the policy is MINOR.

The crate-scoped reading is taken because the crates are the external contract
consumers resolve against, and the vocabulary carries its own `owl:versionInfo`
(0.1.0 → 0.3.0) precisely so it can move independently. If that reading is
rejected, the same content is **1.10.0** and only four strings change:
`CITATION.cff:version`, `.zenodo.json:version`, the CHANGELOG heading, and the
`isSupplementTo` tree link.

## What is deferred

- The `cv_*` identifiers remain wrong-but-stable, as recorded in the v1.9.0
  notes. Renaming them is still a **major** change, still deferred, still to be
  retired with `owl:deprecated` + `dct:isReplacedBy`.
- `is_rmse` / `is_mae` / `is_cor` sit on ISO-anchored dimensions and are
  therefore *not* emitted as owned measure concepts by step 5b. Their IRIs are
  ISO-anchored, so this is correct by construction — but it means the registered
  route is complete only for the `fairagrodq:`-owned half of the registry.

## Before you tag

- **Regenerate `fairagrodq.ttl` from the tagged tree** and confirm it is
  byte-identical to the vendored copy. The file carries a "GENERATED FILE, do not
  hand-edit" banner; a vendored artefact that no longer matches its generator is
  worse than no vendored artefact.
- **Check `%||%` under R ≥ 4.4.** `dq_vocab_core.R` and
  `dq_uncertainty_principles.R` define theirs behind `if (!exists("%||%"))`.
  Base R gained a `%||%` in 4.4.0 that returns `b` only for `NULL`, not for a
  length-1 `NA`. On R ≥ 4.4 the guard therefore finds the base operator and skips
  the NA-aware definition, so `m$unit %||% NULL` and similar fall through
  differently than on R 4.3. `build_phase_cog_ro_crate.R` and (as of this
  release) `generate_fairagrodq_ttl.R` define theirs unconditionally and are
  unaffected. Making the two registry files unconditional as well would remove an
  R-version dependency from emitted metadata.
- **Confirm the `basis → principle` mapping is exhaustive** for the measures
  actually emitted. `holdout`, `in-sample`, `deviance`, `parameter`, `count` and
  `diagnostic` have no entry in `basis_principle`, so those nodes are emitted
  without `fairagrodq:expressedBy`. That is intended — they are not uncertainty
  expressions — but it should be a stated decision, not a silent gap.
- `README.md` links to `RELEASING.md`, which is not in the repository. Either add
  it or drop the link.
