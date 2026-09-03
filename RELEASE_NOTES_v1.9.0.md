# PhenoPhaseR v1.9.0 — Release notes

**Honest validation basis for every accuracy metric.** The emitted quality
metadata no longer conflates three different validation regimes under one, and in
two cases incorrect, label.

This is a **MINOR** release. It adds vocabulary terms (`is_rmse`, `is_mae`,
`is_cor`) and changes which metric IRIs the FilterVariant crate emits. The PHASE
crate's metric IRIs are unchanged (`cv_*` retained), so already-published PHASE
deposits do not dangle. **No data files change** — re-emit crate metadata against
the unchanged data.

## What was wrong

Three regimes, described as one:

- **VAM `RMSE` / `MAE` / `MSE` / `R2`** are **hold-out** (a single `ON = TN + VN`
  split) — but were emitted as *"Cross-validation …"*.
- **`cv_r2`** is the VAM **`R2`** column — a **hold-out coefficient of
  determination** on the withheld partition, companion to `cv_rmse` / `cv_mae`; the
  in-sample CAL **`DEV_EXPLAINED`** is a separate file-level diagnostic. `cv_r2` was
  emitted as *"coefficient of determination, observed vs predicted"* without stating
  that it is hold-out.
- The **`critical_doy_determination()`** metrics are **in-sample (resubstitution),
  optimistically biased** (target leakage: `T_SUMS` encodes each station's
  observed date; outliers removed before scoring; the reported quantile minimises
  MAE on the same data). They were emitted through the hold-out token `cv_rmse`.

Because each builder wrote its own text, the identifier `cv_rmse` read
*"Cross-validation RMSE of DOY"* in the PHASE crate and *"Holdout RMSE of the
modelled attribute"* in the FilterVariant crate — a flat contradiction.

## What changed

- A single **metric registry** (`.DQ_MEASURES`) now records, per metric, its
  **validation basis** and — for the optimistic in-sample metrics — an explicit
  **caveat** (the function header's own admission, carried into the metadata).
  This is the accuracy-metric analogue of the vocabulary's uncertainty
  claim-status axis.
- **Both builders read their metric descriptions from that one source**
  (`dq_describe()`), so the descriptions can no longer diverge across crates.
- `picp` / `mpiw` are the deliberate exception and keep their parameterised
  descriptions (nominal coverage %, k-fold-CV fold structure) — those genuinely
  come from a dedicated k-fold cross-validation and were already correct.
- New tokens `is_rmse` / `is_mae` / `is_cor` carry the in-sample critical_doy
  metrics honestly; the FilterVariant builder now uses them.

## Why minor, not patch

The versioning policy treats a change that **adds vocabulary terms or alters which
IRIs are emitted** as minor. This release does both (new `is_*` tokens; the
FilterVariant crate emits different metric IRIs). Description-only corrections
would have been a patch; the token additions raise it to minor.

## What is deferred

The retained `cv_*` identifiers are **wrong-but-stable**: their descriptions are
now honest, but the tokens still read "cv". Renaming them to regime-honest
identifiers (`ho_rmse`, `dev_expl`, …) is a **breaking** change and is deferred to
the next **major** release, where the old IRIs will be retired with
`owl:deprecated` + `dct:isReplacedBy` so nothing already published is orphaned.

## Before you tag

- Confirm the value fed into `cv_r2` (PHASE builder) is the VAM `R2` column, as the
  corrected description now states (the builder column map shows `cv_r2 ← R2`); the
  CAL `DEV_EXPLAINED` is emitted only at file level.
- Confirm `picp` is computed on the withheld set (`# CONFIRM` note in the
  registry).
- Re-emit the crate metadata (PHASE + FilterVariant) against the **unchanged**
  data; for any already-published deposit this is a metadata-only new version.
