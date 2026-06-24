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
.DQ_MEASURES <- list(

  # ---- generic, reusable across every modelling domain ----------------------
  cv_rmse  = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", definition = "Holdout RMSE of the modelled attribute."),
  cv_mae   = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", definition = "Holdout MAE of the modelled attribute."),
  cv_bias  = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", definition = "Holdout mean signed error (bias)."),
  mae_days = list(dimension = "iso19157:QuantitativeAttributeAccuracy",
                  unit = "days", definition = "Mean absolute error in days."),
  picp     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = NA,    definition = "Prediction-interval coverage probability (calibration of predictive uncertainty)."),
  mpiw     = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "days", definition = "Mean prediction-interval width at nominal coverage."),
  mean_bse = list(dimension = "fairagrodq:NumericalSpatialUncertainty",
                  unit = "days", definition = "Spatial mean of the per-pixel posterior standard error raster."),

  # ---- evidence / provenance: NO dimension (published, not claimed) ---------
  cv_r2                  = list(dimension = NA, unit = NA,      definition = "Coefficient of determination, observed vs predicted (evidence)."),
  correlation            = list(dimension = NA, unit = "r",     definition = "Pearson correlation, predicted vs observed (evidence)."),
  training_n             = list(dimension = NA, unit = "count", definition = "Number of samples used to fit the model (evidence)."),
  validation_n           = list(dimension = NA, unit = "count", definition = "Number of withheld samples in validation (evidence)."),
  sample_number          = list(dimension = NA, unit = "count", definition = "Station/sample count after filtering (evidence)."),
  bam_k                  = list(dimension = NA, unit = "rank",  definition = "Effective basis dimension of the smooth (model hyperparameter)."),
  gdd_quantile_threshold = list(dimension = NA, unit = "ratio", definition = "GDD quantile threshold (filter parameter)."),
  adaptive_exponent_x    = list(dimension = NA, unit = NA,      definition = "Adaptive-filter exponent (filter parameter)."),
  residual_sd_cutoff     = list(dimension = NA, unit = "sigma", definition = "Residual SD cutoff (filter parameter)."),
  OPT_score              = list(dimension = NA, unit = NA,      definition = "Station-selection optimisation score."),
  OPT_score_normalized   = list(dimension = NA, unit = "ratio", definition = "Normalised station-selection score."),
  n_ratio                = list(dimension = NA, unit = "ratio", definition = "Retained/total sample ratio (selection diagnostic).")
)

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
