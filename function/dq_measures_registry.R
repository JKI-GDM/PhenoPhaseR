# =============================================================================
# dq_measures_registry.R
# Authoritative accuracy / quality-metric registry for the PhenoPhaseR pipeline
#   concept DOI 10.5281/zenodo.18743008
#
# This block replaces the `.DQ_MEASURES` definition in dq_vocab_core.R. It is
# the SINGLE SOURCE from which BOTH crate builders must read their metric
# descriptions. The reason `cv_rmse` is described as "Cross-validation ..." in
# the PHASE crate but "Holdout ..." in the FILTER crate is that the PHASE
# builder writes its descriptions by hand instead of reading this list; once it
# reads from here, the two crates cannot disagree (the same guarantee the
# .ttl generator gives the vocabulary).
#
# CHANGE (v0.2.1 -- wording + validation basis; NON-BREAKING):
#   * New field `basis`  : the validation regime a number was produced under.
#                          RMSE = 8 is meaningless without it; this records it.
#                          It is the accuracy-metric analogue of the vocabulary's
#                          uncertainty claim-status axis.
#   * New field `caveat` : present only where a number is optimistically biased;
#                          it must travel with the number (scheme a: keep + flag).
#   * Definitions corrected where they asserted a regime that did not occur:
#       - cv_r2 was "coefficient of determination, observed vs predicted"; it is
#         in fact CAL DEV_EXPLAINED, i.e. IN-SAMPLE deviance explained.
#       - cv_rmse / cv_mae are HOLD-OUT (single ON = TN + VN train/test split,
#         VAM_*.csv), not cross-validation.
#
# IDENTIFIERS ARE UNCHANGED (wrong-but-stable). `cv_rmse` stays `cv_rmse` so
# that already-published PHASE deposits do not dangle. The regime-honest rename
# (cv_ -> ho_ / is_ / dev_) is deferred to the next MAJOR version (v1.0, gated
# by the vocabulary paper), where the old IRIs will be retired with
# owl:deprecated + dct:isReplacedBy rather than silently overwritten.
#
# `basis` controlled values:
#   "holdout"    single train/test split; out-of-sample estimate
#   "in-sample"  resubstitution; the same data fit the model and scored it
#   "deviance"   in-sample GAM deviance explained (goodness of fit, not skill)
#   "parameter"  a fitted model / filter parameter (not an accuracy metric)
#   "count"      a sample count (not an accuracy metric)
#   "diagnostic" a selection / retention ratio (not an accuracy metric)
#   "validation" an empirical coverage check of predictive uncertainty (PICP)
#
# To externalise: read.csv2("dq_measures.csv") with columns
#   token,dimension,unit,basis,definition,caveat
# =============================================================================

# Optimistic-bias caveat, verbatim to the intent of the critical_doy_determination()
# header ("No cross-validation or independent test set (same data for calibration)").
.LEAK_CAVEAT <- paste0(
  "In-sample (resubstitution): the temperature-sum threshold is derived from ",
  "the same stations on which it is then scored, and because T_SUMS encodes ",
  "each station's observed date, the calibration target leaks into the ",
  "threshold. Outliers are removed before scoring, and the reported model is ",
  "the quantile that minimises MAE on that same data. This value is therefore ",
  "optimistically biased and must not be read as an estimate of out-of-sample ",
  "predictive skill."
)

.DQ_MEASURES <- list(

  # ---- HOLD-OUT accuracy (BAM/GAM phenology model; VAM_*.csv, validation
  #      partition of size VN from a single ON = TN + VN split) ---------------
  cv_rmse  = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", basis = "holdout", caveat = NA,
                  definition = "Root-mean-square error of predicted vs observed DOY on the withheld validation partition (single train/test split)."),
  cv_mae   = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", basis = "holdout", caveat = NA,
                  definition = "Mean absolute error of predicted vs observed DOY on the withheld validation partition (single train/test split)."),
  cv_bias  = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", basis = "holdout", caveat = NA,
                  definition = "Mean signed error (bias) of predicted vs observed DOY on the withheld validation partition."),

  # ---- IN-SAMPLE fit statistic (CAL_*.csv DEV_EXPLAINED) --------------------
  #      This is what the crate previously mislabelled cv_r2 /
  #      "coefficient of determination, observed vs predicted". It is neither.
  cv_r2    = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = NA, basis = "holdout", caveat = NA,
                  definition = "Coefficient of determination of predicted vs observed DOY on the withheld validation partition (single train/test split); the VAM R2 column, companion to cv_rmse / cv_mae. NOTE: distinct from the in-sample CAL DEV_EXPLAINED diagnostic (summary(bam)$dev.expl), which is published only as a file-level model-fit statistic, not as this metric."),

  # ---- IN-SAMPLE, optimistic accuracy (critical_doy_determination();
  #      thermal-threshold / filter variant) ----------------------------------
  #      Scheme (a): kept and emitted, but caveated. Prefer these is_* tokens in
  #      the FILTER builder. NOTE: the FILTER crate currently writes its
  #      in-sample RMSE into `cv_rmse` (a HOLD-OUT token) -- repoint it to
  #      is_rmse so the emitted basis matches how the number was computed.
  is_rmse  = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", basis = "in-sample", caveat = .LEAK_CAVEAT,
                  definition = "Root-mean-square error of the critical-DOY prediction, computed in-sample."),
  is_mae   = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", basis = "in-sample", caveat = .LEAK_CAVEAT,
                  definition = "Mean absolute error of the critical-DOY prediction, computed in-sample."),
  is_cor   = list(dimension = NA, unit = "r", basis = "in-sample", caveat = .LEAK_CAVEAT,
                  definition = "Pearson correlation of predicted vs observed DOY, computed in-sample (evidence)."),

  # ---- LEGACY in-sample tokens (critical_doy). Kept and now annotated
  #      honestly for any FILTER crate already emitted with them; new builds
  #      should use the is_* tokens above. -----------------------------------
  mae_days    = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                     unit = "days", basis = "in-sample", caveat = .LEAK_CAVEAT,
                     definition = "Mean absolute error in days of the critical-DOY prediction, computed in-sample."),
  correlation = list(dimension = NA, unit = "r", basis = "in-sample", caveat = .LEAK_CAVEAT,
                     definition = "Pearson correlation, predicted vs observed, computed in-sample (evidence)."),

  # ---- PREDICTIVE-UNCERTAINTY measures (owned fairagrodq dimension). Their
  #      claim status is carried by the expression-principle axis; `basis` here
  #      records only whether the number is an empirical check or a model output.
  picp     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = NA, basis = "cross-validation", caveat = NA,
                  definition = "Prediction-interval coverage probability: pooled out-of-fold share of observations falling inside the nominal interval, from a dedicated k-fold cross-validation of the BSE calibration (the production model is fit on all observations, so coverage cannot be measured in-sample)."),
  mpiw     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "days", basis = "parameter", caveat = NA,
                  definition = "Mean prediction-interval width at nominal coverage (model output)."),
  mean_bse = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "days", basis = "parameter", caveat = NA,
                  definition = "Spatial mean of the per-pixel basis-spline posterior standard-error raster (model output)."),

  # ---- FITTED PARAMETERS / COUNTS / DIAGNOSTICS -- NOT accuracy -------------
  training_n             = list(dimension = NA, unit = "count", basis = "count", caveat = NA,
                                definition = "Number of samples used to fit the model."),
  validation_n           = list(dimension = NA, unit = "count", basis = "count", caveat = NA,
                                definition = "Number of withheld samples in the validation partition."),
  sample_number          = list(dimension = NA, unit = "count", basis = "count", caveat = NA,
                                definition = "Station / sample count after outlier filtering."),
  bam_k                  = list(dimension = NA, unit = "rank", basis = "parameter", caveat = NA,
                                definition = "Effective basis dimension of the GAM smooth (model hyperparameter)."),
  u_pheno  = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "mm", basis = "propagated", caveat = NA,
                  defined_by = "https://doi.org/10.5281/zenodo.19631197",
                  definition = "1-sigma uncertainty contribution of phenological-window placement, computed as (WI_max - WI_min)/2 from windows shifted by the propagated phase-entry BSE."),
  u_precip = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "mm", basis = "propagated", caveat = NA,
                  defined_by = "https://doi.org/10.5281/zenodo.19631197",
                  definition = "1-sigma uncertainty contribution of precipitation: square root of the summed daily E-OBS ensemble variance over the phenological window."),
  u_total  = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "mm", basis = "propagated", caveat = NA,
                  defined_by = "https://doi.org/10.5281/zenodo.19631197",
                  definition = "Total 1-sigma uncertainty of the weather index: quadrature combination sqrt(u_pheno^2 + u_precip^2) of the phenological and precipitation contributions."),
  gdd_quantile_threshold = list(dimension = NA, unit = "ratio", basis = "parameter", caveat = NA,
                                definition = "Selected GDD quantile threshold q* (fitted filter parameter)."),
  adaptive_exponent_x    = list(dimension = NA, unit = NA, basis = "parameter", caveat = NA,
                                definition = "Adaptive-filter exponent (fitted filter parameter)."),
  residual_sd_cutoff     = list(dimension = NA, unit = "sigma", basis = "parameter", caveat = NA,
                                definition = "Residual standard-deviation cutoff for outlier removal (filter parameter)."),
  OPT_score              = list(dimension = NA, unit = NA, basis = "diagnostic", caveat = NA,
                                definition = "Station-selection optimisation score."),
  OPT_score_normalized   = list(dimension = NA, unit = "ratio", basis = "diagnostic", caveat = NA,
                                definition = "Normalised station-selection score."),
  n_ratio                = list(dimension = NA, unit = "ratio", basis = "diagnostic", caveat = NA,
                                definition = "Retained / total sample ratio (selection diagnostic).")
)

# -----------------------------------------------------------------------------
# Emitter helper. Returns the honest, human-readable string that goes into
# schema:description for a measure, appending the validation basis and, when
# present, the optimistic-bias caveat. Both crate builders should set
# schema:description = dq_describe(token) instead of writing their own text.
# (Machine-readable `basis` as its own property, e.g. fairagrodq:validationBasis
# tied to the claim-status axis, is a v1.0 vocabulary addition; for now the
# basis is carried in the description so it is at least never silent.)
# -----------------------------------------------------------------------------
dq_describe <- function(token, reg = .DQ_MEASURES) {
  m <- reg[[token]]
  if (is.null(m)) stop(sprintf("Unknown measure token: %s", token))
  basis_lab <- c(holdout            = "hold-out (out-of-sample)",
                 `in-sample`        = "in-sample (resubstitution)",
                 deviance           = "in-sample deviance explained",
                 `cross-validation` = "k-fold cross-validation",
                 validation         = "empirical coverage check",
                 propagated         = "analytical error propagation (model-asserted, unvalidated)",
                 parameter  = "model / filter parameter",
                 count      = "sample count",
                 diagnostic = "selection diagnostic")[m$basis]
  out <- sprintf("%s [Validation basis: %s.]", m$definition, basis_lab)
  if (!is.null(m$caveat) && !is.na(m$caveat)) out <- paste(out, m$caveat)
  out
}
