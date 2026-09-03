# =============================================================================
# dq_vocab_core.R  --  Pragmatic blueprint: vocabulary-anchored data quality and
#                      uncertainty for geodata modelling products (RO-Crate 1.2).
# -----------------------------------------------------------------------------
# WHAT THIS IS
#   A single, DOMAIN-NEUTRAL source of truth for the data-quality (DQ) layer of
#   an RO-Crate. It replaces the three functions previously COPIED into both
#   PhenoPhaseR builders:
#       .iso19157_dimension()  .metric_entity()  .quality_element()
#   and supersedes the whole dffp_iso19157_extension_patch.R (its
#   .dimension_entities() and .with_bse_uncertainty_anchors() now live here).
#   The measure -> dimension mapping is DATA (a registry), not a hard-coded
#   switch, so a new domain (e.g. Digital Soil Mapping) is onboarded by adding
#   rows. The registry below was checked to reproduce the PHASE and FILTER
#   crates' metric/dimension graphs exactly.
#
# SCOPE NOTE
#   This file carries the QUALITY axis only (DQV / ISO 19157-1). The orthogonal
#   spatial-uncertainty EXPRESSION-PRINCIPLE axis lives in the companion
#   dq_uncertainty_principles.R. The FAIRagro Core Metadata Specification
#   (findability) is intentionally NOT addressed here.
#
# DESIGN PRINCIPLES
#   1. Honest anchoring. A measure token (cv_rmse, picp, corg_rmse, ...) is
#      OWNED locally; it is never minted as iso19157:<token>. The only link to a
#      standard is at the DIMENSION-CLASS level, via dqv:Metric -> dqv:inDimension
#      -> a node that resolves. Measures with no honest home carry NO dimension
#      and are published as evidence/provenance, not as a quality claim.
#   2. Dual typing. Every measurement is BOTH schema:PropertyValue AND
#      dqv:QualityMeasurement, so a plain Schema.org reader and a DQV-aware
#      client both see it.
#   3. Owned provisional namespace. Spatially explicit uncertainty has no element
#      in ISO 19157-1:2023; it lives under fairagrodq: (provisional, pending
#      w3id/FAIRagro registration), informed by Saeurich et al. (2026), never
#      falsely asserted as an ISO element.
#
# ADOPTION (no change to PhenoPhaseR.R)
#   Source this AFTER _crop_specs.R in both builders, then DELETE their local
#   .iso19157_dimension / .metric_entity / .quality_element. The aliases at the
#   bottom keep the old call sites (.metric_entity, .dimension_entities,
#   .with_bse_uncertainty_anchors, ...) working unchanged.
#
# Author : M. Möller, 2026.  License: MIT (script); CC-BY-4.0 (crate contents).
# =============================================================================

if (!exists("%||%")) `%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 1 && is.na(a)) return(b)
  a
}

# =============================================================================
# A.  MEASURE REGISTRY  -- the single editable table.
# -----------------------------------------------------------------------------
# One row per measure token. Fields:
#   dimension  : prefixed IRI of the ISO 19157-1 element or fairagrodq: dimension
#                the measure belongs to, or NA -> "no honest home" (evidence only)
#   unit       : default schema:unitText (a call site may still override)
#   definition : short skos:definition, attached to the dqv:Metric
# To externalise: replace .DQ_MEASURES with read.csv2("dq_measures.csv") whose
# columns are token,dimension,unit,definition -- the code below is agnostic.
#
# Dimension IRIs in use (defined as nodes in section B):
#   iso19157:QuantitativeAttributeAccuracy   genuine ISO 19157-1:2023 element
#   iso19157:CompletenessOmission            genuine ISO 19157-1:2023 element
#   iso19157:LogicalConsistency              genuine ISO 19157-1:2023 element
#   fairagrodq:NumericalSpatialUncertainty   provisional, owned (continuous)
#   fairagrodq:ClassSpatialUncertainty       provisional, owned (categorical)
# =============================================================================
# >>> v1.8.2: metric registry corrected -- honest validation basis + optimistic-bias
#     caveats. Descriptions fixed (hold-out vs in-sample vs deviance); cv_r2 is CAL
#     DEV_EXPLAINED, not a coefficient of determination. Identifiers UNCHANGED.
#     Emit via dq_describe(token) so both crate builders read one source. <<<

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
                 parameter  = "model / filter parameter",
                 count      = "sample count",
                 diagnostic = "selection diagnostic")[m$basis]
  out <- sprintf("%s [Validation basis: %s.]", m$definition, basis_lab)
  if (!is.null(m$caveat) && !is.na(m$caveat)) out <- paste(out, m$caveat)
  out
}

# -----------------------------------------------------------------------------
# A'.  DOMAIN OVERLAY EXAMPLE -- Digital Soil Mapping (SOCastR: QRF topsoil Corg).
#      The WHOLE onboarding cost for a new domain: append rows. Generic rows
#      above (picp, mpiw, cv_*) are reused verbatim. Merge with
#      dq_register(.DQ_MEASURES_DSM) before building a SOCastR crate.
# -----------------------------------------------------------------------------
.DQ_MEASURES_DSM <- list(
  corg_rmse   = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                     unit = "g/kg", definition = "Holdout RMSE of topsoil organic carbon."),
  corg_bias   = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                     unit = "g/kg", definition = "Holdout bias of topsoil organic carbon."),
  corg_r2     = list(dimension = NA, unit = NA, definition = "R2 of Corg, observed vs predicted (evidence)."),
  picp_corg   = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                     unit = NA, definition = "PICP of the QRF prediction interval for Corg (PICP/PIC)."),
  qrf_q05     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                     unit = "g/kg", definition = "5% spatial quantile of the QRF prediction interval width."),
  qrf_q50     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                     unit = "g/kg", definition = "Median spatial quantile of the QRF prediction interval width."),
  qrf_q95     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                     unit = "g/kg", definition = "95% spatial quantile of the QRF prediction interval width."),
  aoa_fraction_inside = list(dimension = "fairagrodq:ClassSpatialUncertainty",
                     unit = "ratio", definition = "Fraction of prediction grid inside the Area of Applicability (DI <= threshold).")
)

# Merge/override registry rows at runtime (idempotent).
dq_register <- function(rows, into = ".DQ_MEASURES") {
  reg <- get(into, envir = .GlobalEnv)
  for (k in names(rows)) reg[[k]] <- rows[[k]]
  assign(into, reg, envir = .GlobalEnv)
  invisible(reg)
}

# =============================================================================
# B.  DIMENSION REGISTRY  -- the nodes every dqv:inDimension target must resolve
#     to. Genuine ISO 19157-1:2023 elements carry dct:conformsTo the standard;
#     provisional fairagrodq: dimensions carry skos:note + dct:isDefinedBy the
#     informing reference. "Emit only the dimensions used (+ skos:broader
#     parents)" is preserved from the retired patch.
# =============================================================================
.DQ_DIMENSIONS <- local({
  iso_std  <- "https://www.iso.org/standard/78900.html"      # DIN EN ISO 19157-1:2023
  saeurich <- "https://doi.org/10.1016/j.ecoinf.2026.103660" # Saeurich et al. 2026
  list(
    "iso19157:QuantitativeAttributeAccuracy" = list(
      "@id" = "iso19157:QuantitativeAttributeAccuracy",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Quantitative attribute accuracy",
      "skos:definition" = paste0("Closeness of the value of a quantitative attribute to a value ",
        "accepted as or known to be true (ISO 19157-1:2023, 8.3.6). Sub-element of Thematic quality."),
      "dct:conformsTo" = list("@id" = iso_std)),
    "iso19157:CompletenessOmission" = list(
      "@id" = "iso19157:CompletenessOmission",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Completeness - omission",
      "skos:definition" = "Data absent from a dataset that should be present (ISO 19157-1:2023, 8.3.2).",
      "dct:conformsTo" = list("@id" = iso_std)),
    "iso19157:LogicalConsistency" = list(
      "@id" = "iso19157:LogicalConsistency",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Logical consistency",
      "skos:definition" = "Degree of adherence to logical rules of data structure, attribution and relationships (ISO 19157-1:2023, 8.3.3).",
      "dct:conformsTo" = list("@id" = iso_std)),
    "fairagrodq:SpatialUncertainty" = list(
      "@id" = "fairagrodq:SpatialUncertainty",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Spatial uncertainty",
      "skos:definition" = paste0("Project-defined, PROVISIONAL data-quality dimension for a spatially ",
        "explicit account of uncertainty in modelling / classification products. Informed by ",
        "Saeurich et al. (2026); NOT part of ISO 19157-1:2023. To be governed under a registered ",
        "FAIRagro namespace."),
      "skos:note" = "Provisional, project-defined; pending namespace registration.",
      "dct:isDefinedBy" = list("@id" = saeurich)),
    "fairagrodq:NumericalSpatialUncertainty" = list(
      "@id" = "fairagrodq:NumericalSpatialUncertainty",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Numerical spatial uncertainty",
      "skos:definition" = paste0("Project-defined, provisional. Spatially explicit uncertainty of a ",
        "continuous (numerical) modelled attribute: e.g. per-pixel posterior standard error and its ",
        "prediction-interval calibration (PICP, MPIW). Informed by Saeurich et al. (2026); ",
        "NOT part of ISO 19157-1:2023."),
      "skos:broader" = list("@id" = "fairagrodq:SpatialUncertainty"),
      "dct:isDefinedBy" = list("@id" = saeurich)),
    "fairagrodq:ClassSpatialUncertainty" = list(
      "@id" = "fairagrodq:ClassSpatialUncertainty",
      "@type" = c("dqv:Dimension","skos:Concept"),
      "skos:prefLabel" = "Class spatial uncertainty",
      "skos:definition" = paste0("Project-defined, provisional. Spatially explicit uncertainty of a ",
        "categorical (class) modelled attribute, e.g. a per-pixel Area-of-Applicability / ",
        "extrapolation mask. Informed by Saeurich et al. (2026); NOT part of ISO 19157-1:2023."),
      "skos:broader" = list("@id" = "fairagrodq:SpatialUncertainty"),
      "dct:isDefinedBy" = list("@id" = saeurich))
  )
})

#' Emit the dimension nodes used by this crate (plus skos:broader parents).
#' Supersedes .dimension_entities(); same contract (used = NULL -> emit all).
dq_dimension_entities <- function(used = NULL) {
  all_dims <- .DQ_DIMENSIONS
  if (is.null(used)) return(unname(all_dims))
  keep <- intersect(used, names(all_dims))
  repeat {
    par <- unlist(lapply(all_dims[keep], function(e) {
      b <- e[["skos:broader"]]; if (is.null(b)) NULL else b[["@id"]]
    }), use.names = FALSE)
    add <- setdiff(intersect(par, names(all_dims)), keep)
    if (!length(add)) break
    keep <- c(keep, add)
  }
  unname(all_dims[keep])
}

# =============================================================================
# C.  ENGINE  -- the three functions the builders call. Behaviour identical to
#     the retired copies, but sourced once and driven by the registry.
# =============================================================================

#' Dimension IRI for a measure token, or NA_character_ if it has no honest home.
#' Exact registry hit first; then a single, deliberately narrow fallback: tokens
#' that are spatial quantiles of an uncertainty raster (..._q05, ..._q50, ...)
#' are numerical spatial uncertainty. Nothing else is inferred.
dq_dimension_of <- function(measure) {
  row <- .DQ_MEASURES[[measure]]
  if (!is.null(row)) {
    d <- row$dimension
    return(if (is.null(d) || is.na(d)) NA_character_ else d)
  }
  if (grepl("_q[0-9]{1,3}$", measure))
    return("fairagrodq:NumericalSpatialUncertainty")
  NA_character_
}

#' Top-level dqv:Metric node for a measure (one per unique token in the crate).
#' Strict superset of the old node: adds skos:definition when the registry has
#' one; skos:prefLabel stays the bare token so existing references round-trip.
dq_metric_entity <- function(measure) {
  dim_iri <- dq_dimension_of(measure)
  row     <- .DQ_MEASURES[[measure]]
  ent <- list("@id" = paste0("#metric-", measure),
              "@type" = "dqv:Metric",
              "skos:prefLabel" = measure)
  if (!is.null(row) && !is.null(row$definition))
    ent[["skos:definition"]] <- row$definition
  if (!is.na(dim_iri)) ent[["dqv:inDimension"]] <- list("@id" = dim_iri)
  ent
}

#' One measurement node: dual-typed schema:PropertyValue + dqv:QualityMeasurement.
#' propertyID/name carry the bare OWNED token (never iso19157:<token>); the link
#' to a standard is made only through the referenced #metric- entity's dimension.
dq_quality_element <- function(measure, value, unit_text = NULL,
                               definition = NULL, qm_id = NULL,
                               computed_on = NULL) {
  el <- list(
    "@id"   = qm_id,
    "@type" = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = measure,
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list("@id" = paste0("#metric-", measure)))
  ut <- unit_text %||% (.DQ_MEASURES[[measure]]$unit %||% NULL)
  if (!is.null(ut) && !is.na(ut)) el[["schema:unitText"]] <- ut
  # schema:description is taken from the registry (single source of truth) for
  # every registered metric token, so hand-written descriptions at the call
  # sites cannot contradict each other across crates -- this is what caused
  # cv_rmse to read "Cross-validation ..." in the PHASE crate and "Holdout ..."
  # in the FILTER crate. EXCEPTION: picp / mpiw carry a parameterised,
  # context-specific description from the caller (the nominal coverage % and the
  # fold structure) that the static registry entry would flatten, so they are
  # left untouched. The passed `definition` is otherwise the fallback for
  # unregistered tokens. See dq_describe() / .DQ_MEASURES.
  if (!(measure %in% c("picp", "mpiw")))
    definition <- tryCatch(dq_describe(measure), error = function(e) definition)
  if (!is.null(definition)) el[["schema:description"]] <- definition
  if (!is.null(computed_on)) el[["dqv:computedOn"]] <- list("@id" = computed_on)
  el
}

# =============================================================================
# D.  SPATIAL-UNCERTAINTY HELPERS
# =============================================================================

#' Enrich the BSE (per-pixel posterior SE) COG File entity with the spatial-
#' uncertainty anchors: is-a AGROVOC statistical-uncertainty (c_28975) + spatial
#' data (c_379bbe9f); conformsTo the provisional NumericalSpatialUncertainty
#' dimension. Moved here from the retired dffp_iso19157_extension_patch.R.
.with_bse_uncertainty_anchors <- function(file_entity) {
  agrovoc <- list(
    list("@id" = "http://aims.fao.org/aos/agrovoc/c_28975"),     # statistical uncertainty
    list("@id" = "http://aims.fao.org/aos/agrovoc/c_379bbe9f")   # spatial data
  )
  file_entity[["schema:about"]]   <- agrovoc
  file_entity[["dct:subject"]]    <- agrovoc
  file_entity[["dct:conformsTo"]] <- list("@id" = "fairagrodq:NumericalSpatialUncertainty")
  file_entity
}

#' Lift the per-pixel uncertainty raster's spatial distribution (BSE/GEM
#' quantiles, or a DSM QRF interval-width quantile table) into real
#' dqv:QualityMeasurements, dqv:computedOn the uncertainty COG, under
#' fairagrodq:NumericalSpatialUncertainty -- so the spatial spread of
#' uncertainty is queryable, not buried in a sidecar CSV.
#'   quantile_tab : data.frame with columns Quantile ("5%","50%",...) and Value;
#'                  optional YEAR. token_prefix e.g. "bse_q" or "qrf_q".
#'   cog_relpath  : crate-relative @id of the uncertainty raster File.
dq_spatial_quantile_measurements <- function(quantile_tab, cog_relpath,
                                             token_prefix = "bse_q",
                                             id_stub = "spatialq",
                                             unit_text = NULL) {
  if (is.null(quantile_tab) || !nrow(quantile_tab)) return(list())
  out <- list()
  for (i in seq_len(nrow(quantile_tab))) {
    r  <- quantile_tab[i, ]
    qn <- suppressWarnings(as.integer(gsub("[^0-9]", "", as.character(r$Quantile))))
    if (is.na(qn)) next
    tok <- sprintf("%s%02d", token_prefix, qn)         # bse_q05, qrf_q95, ...
    val <- suppressWarnings(as.numeric(r$Value)); if (is.na(val)) next
    yr  <- if (!is.null(r$YEAR)) as.character(r$YEAR) else NULL
    qm_id <- if (!is.null(yr)) sprintf("#qm-%s-%s-%s", id_stub, yr, tok)
             else sprintf("#qm-%s-%s", id_stub, tok)
    e <- dq_quality_element(
      tok, val, unit_text = unit_text,
      definition = sprintf("Spatial %d%% quantile of the per-pixel uncertainty raster.", qn),
      qm_id = qm_id, computed_on = cog_relpath)
    if (!is.null(yr)) { e[["schema:temporalCoverage"]] <- yr; e[["dct:temporal"]] <- yr }
    out[[length(out) + 1]] <- e
  }
  out
}

# =============================================================================
# E.  BACK-COMPAT ALIASES  -- so the existing builders need only add the source()
#     line and remove their local copies; old names keep working unchanged.
# =============================================================================
.iso19157_dimension <- function(measure) dq_dimension_of(measure)
.metric_entity      <- function(measure) dq_metric_entity(measure)
.quality_element    <- function(measure, value, unit_text = NULL, definition = NULL,
                                qm_id = NULL, computed_on = NULL)
  dq_quality_element(measure, value, unit_text, definition, qm_id, computed_on)
.dimension_entities <- function(used = NULL) dq_dimension_entities(used)

# =============================================================================
# F.  SELF-TEST  -- run interactively: source(...); dq_selftest()
# =============================================================================
dq_selftest <- function() {
  stopifnot(dq_dimension_of("cv_rmse")  == "iso19157:QuantitativeAttributeAccuracy")
  stopifnot(dq_dimension_of("picp")     == "fairagrodq:NumericalSpatialUncertainty")
  stopifnot(is.na(dq_dimension_of("cv_r2")))
  stopifnot(dq_dimension_of("qrf_q95")  == "fairagrodq:NumericalSpatialUncertainty")  # fallback
  dq_register(.DQ_MEASURES_DSM)
  stopifnot(dq_dimension_of("corg_rmse") == "iso19157:QuantitativeAttributeAccuracy")
  stopifnot(dq_dimension_of("aoa_fraction_inside") == "fairagrodq:ClassSpatialUncertainty")
  m <- dq_metric_entity("picp")
  stopifnot(m[["dqv:inDimension"]][["@id"]] == "fairagrodq:NumericalSpatialUncertainty")
  e <- dq_quality_element("cv_rmse", 3.1, qm_id = "#qm-x")
  stopifnot(identical(e[["@type"]], c("schema:PropertyValue","dqv:QualityMeasurement")))
  stopifnot(e[["schema:unitText"]] == "days")   # default unit pulled from registry
  fe <- .with_bse_uncertainty_anchors(list("@id"="cogs/BSE.tif","@type"="File"))
  stopifnot(fe[["dct:conformsTo"]][["@id"]] == "fairagrodq:NumericalSpatialUncertainty")
  message("dq_vocab_core.R self-test passed.")
  invisible(TRUE)
}
