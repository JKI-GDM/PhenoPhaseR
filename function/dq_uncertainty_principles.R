# =============================================================================
# dq_uncertainty_principles.R  --  Extension to dq_vocab_core.R.
# -----------------------------------------------------------------------------
# WHY
#   "Spatial uncertainty" is not one thing. A BAM posterior standard error, a
#   QRF prediction interval, a conformal interval, an ensemble of conditional
#   simulations, an Area-of-Applicability mask, and a class-probability raster
#   are produced by DIFFERENT PRINCIPLES that make DIFFERENT CLAIMS. The DQV
#   *dimension* (fairagrodq:NumericalSpatialUncertainty / ClassSpatialUncertainty)
#   says WHAT aspect of quality is meant; it does NOT say HOW the uncertainty was
#   expressed or what it asserts. This module adds that second, orthogonal axis
#   as an OWNED, PROVISIONAL SKOS scheme of uncertainty expression principles,
#   so a layer or a metric can declare its principle honestly and machine-
#   readably -- the same honest-anchoring discipline as the core, one level up.
#
# WHAT IT ADDS
#   * fairagrodq:UncertaintyExpressionPrinciple  -- a skos:ConceptScheme
#   * eight principle concepts, each annotated with three typed, controlled
#     properties so the concept itself is a specification:
#         fairagrodq:representation   how the uncertainty is stored
#         fairagrodq:claimStatus      what the number is allowed to claim
#         fairagrodq:assumes          the assumption the claim rests on
#   * fairagrodq:expressedBy          predicate linking a metric/file -> principle
#   * a token -> principle assignment, an emitter, and an attach helper.
#
# RELATION TO THE DIMENSION AXIS (kept separate on purpose)
#   dimension  = WHICH quality aspect  (DQV / ISO 19157-1 axis)   -> dqv:inDimension
#   principle  = HOW expressed + claim (this module's axis)       -> fairagrodq:expressedBy
#   A measurement keeps BOTH. Example, a QRF interval-width quantile:
#       dqv:inDimension     fairagrodq:NumericalSpatialUncertainty
#       fairagrodq:expressedBy fairagrodq:QuantileRegressionInterval
#
# HONEST SPLIT OF PRODUCTION vs VALIDATION
#   The BSE uncertainty COG is PRODUCED by parametric model uncertainty
#   (model-asserted). PICP/MPIW are an EMPIRICAL coverage check of the intervals
#   built from it. They are different principles, attached to different nodes:
#       - the BSE File entity      -> ParametricModelUncertainty
#       - the picp/mpiw measurement -> EmpiricalCoverageCalibration
#   computed_on already ties the diagnostic to the file, so a consumer can read
#   "validated-coverage diagnostic of a parametric-uncertainty raster" off the
#   graph without guessing.
#
# WIRING (no change to dq_vocab_core.R; source it AFTER the core)
#   1.  source(file.path(.this_dir, "dq_vocab_core.R"))
#       source(file.path(.this_dir, "dq_uncertainty_principles.R"))
#   2.  After building the metric nodes, annotate them:
#         metric_entities <- lapply(metric_entities, dq_attach_principle)
#   3.  Annotate the uncertainty raster File entity with its PRODUCTION principle:
#         if (identical(layer, "BSE"))
#           fe <- dq_attach_principle(fe, "fairagrodq:ParametricModelUncertainty")
#   4.  Emit the principle nodes actually used (+ the scheme):
#         used_pr <- dq_principles_used(metric_entities, extra_files = list(fe))
#         context_entities <- c(context_entities, dq_principle_entities(used_pr))
#   The fairagrodq: prefix is already in the crate @context -- no new prefix.
#
# Author : M. Möller, 2026.  License: MIT (script); CC-BY-4.0 (crate contents).
# =============================================================================

if (!exists("%||%")) `%||%` <- function(a, b) {
  if (is.null(a)) return(b)
  if (length(a) == 1 && is.na(a)) return(b)
  a
}

# =============================================================================
# A.  PRINCIPLE REGISTRY  -- the editable specification table.
# -----------------------------------------------------------------------------
# One row per principle. Fields beyond label/definition are CONTROLLED literals;
# the allowed sets are listed here so the scheme is self-documenting:
#   representation in {per-pixel-sigma, per-pixel-variance, quantile-raster,
#                      ensemble-realizations, dissimilarity-index-raster,
#                      binary-applicability-mask, class-probability-raster,
#                      scalar-diagnostic}
#   claimStatus    in {model-asserted, propagated-model-asserted,
#                      distribution-free-estimate, guaranteed-marginal-coverage,
#                      empirically-validated, trust-signal,
#                      classification-ambiguity}
#   assumes        in {model-correctness, gaussian-homoscedastic-residuals,
#                      linearization-and-known-input-variances, exchangeability,
#                      covariate-space-representativeness, variogram-correctness,
#                      representative-holdout, none-distribution-free}
# ref  : canonical citation as TEXT (skos:scopeNote). seealso: machine IRI, set
#        ONLY where verified -- mirrors the _crop_specs.R "verify before publish"
#        stance. Unverified DOIs are left out, not guessed.
# To externalise: swap .DQ_PRINCIPLES for read.csv2("dq_principles.csv").
# =============================================================================
.DQ_PRINCIPLES <- list(

  "fairagrodq:ParametricModelUncertainty" = list(
    label = "Parametric model uncertainty",
    definition = paste0("Per-pixel uncertainty taken from the fitted model's own ",
      "posterior/sampling variance (e.g. basis-spline standard error of a BAM/GAM ",
      "posterior, kriging variance, Gaussian-process posterior variance). A ",
      "model-internal spread; it does NOT by itself assert validated coverage."),
    representation = "per-pixel-sigma",
    claimStatus    = "model-asserted",
    assumes        = "model-correctness",
    ref = NA),

  "fairagrodq:AnalyticalErrorPropagation" = list(
    label = "Analytical error propagation",
    definition = paste0("Per-pixel uncertainty propagated analytically (Taylor / ",
      "quadrature) from the uncertainties of the inputs, e.g. combining a ",
      "phenology standard error and a precipitation standard error in quadrature."),
    representation = "per-pixel-sigma",
    claimStatus    = "propagated-model-asserted",
    assumes        = "linearization-and-known-input-variances",
    ref = NA),

  "fairagrodq:QuantileRegressionInterval" = list(
    label = "Quantile-regression prediction interval",
    definition = paste0("Predictive quantiles estimated directly (e.g. quantile ",
      "regression forest, quantile GAM), giving per-pixel interval bounds/width ",
      "without assuming a Gaussian error law."),
    representation = "quantile-raster",
    claimStatus    = "distribution-free-estimate",
    assumes        = "covariate-space-representativeness",
    ref = "Meinshausen (2006), Quantile Regression Forests, J. Mach. Learn. Res. 7:983-999."),

  "fairagrodq:ConformalPredictionInterval" = list(
    label = "Conformal prediction interval",
    definition = paste0("Intervals with a finite-sample marginal coverage guarantee ",
      "under exchangeability (split/inductive conformal). Coverage holds by ",
      "construction, marginally over the calibration distribution."),
    representation = "quantile-raster",
    claimStatus    = "guaranteed-marginal-coverage",
    assumes        = "exchangeability",
    ref = "Vovk, Gammerman & Shafer (2005); Lei et al. (2018), JASA 113:1094-1111."),

  "fairagrodq:EnsembleSimulationSpread" = list(
    label = "Ensemble / simulation spread",
    definition = paste0("Uncertainty as the spread across an ensemble of equiprobable ",
      "realizations (geostatistical conditional simulation, bootstrap, Monte Carlo). ",
      "Represented by the realizations or their per-pixel spread, not a single sigma."),
    representation = "ensemble-realizations",
    claimStatus    = "model-asserted",
    assumes        = "variogram-correctness",
    ref = "Goovaerts (1997), Geostatistics for Natural Resources Evaluation."),

  "fairagrodq:EmpiricalCoverageCalibration" = list(
    label = "Empirical coverage calibration",
    definition = paste0("A held-out check of whether stated prediction intervals ",
      "actually cover the truth at the nominal rate: prediction-interval coverage ",
      "probability (PICP) and mean interval width (MPIW). Characterises intervals ",
      "produced by ANY principle above; the only one of these that is empirically ",
      "validated rather than asserted."),
    representation = "scalar-diagnostic",
    claimStatus    = "empirically-validated",
    assumes        = "representative-holdout",
    ref = NA),

  "fairagrodq:ApplicabilityDomain" = list(
    label = "Applicability domain",
    definition = paste0("A spatially explicit trust signal based on dissimilarity of ",
      "each prediction location to the training data in (weighted) covariate space ",
      "-- the dissimilarity index (DI) and its binary Area of Applicability (AOA). ",
      "Flags extrapolation; it is a reliability/extrapolation signal, NOT a ",
      "magnitude of error."),
    representation = "dissimilarity-index-raster",
    claimStatus    = "trust-signal",
    assumes        = "covariate-space-representativeness",
    ref = "Meyer & Pebesma (2021), Methods Ecol. Evol. 12:1620-1633.",
    seealso = "https://doi.org/10.1111/2041-210X.13650"),   # VERIFIED 2026-06

  "fairagrodq:FuzzyClassMembership" = list(
    label = "Fuzzy class membership",
    definition = paste0("For categorical products: per-pixel class-membership ",
      "probabilities and their summaries (confusion index, Shannon entropy of the ",
      "class-probability vector). Expresses classification ambiguity."),
    representation = "class-probability-raster",
    claimStatus    = "classification-ambiguity",
    assumes        = "none-distribution-free",
    ref = NA)
)

# Scheme-level informing reference (kept from the core's provisional dimension).
.DQ_PRINCIPLE_SCHEME_REF <- "https://doi.org/10.1016/j.ecoinf.2026.103660"  # Saeurich et al. 2026

# =============================================================================
# B.  TOKEN -> PRINCIPLE assignment. Only SPATIAL-UNCERTAINTY measures get a
#     principle; accuracy/evidence measures (cv_rmse, cv_r2, ...) get NONE -- a
#     principle is meaningless for them, and asserting one would be dishonest.
# =============================================================================
.DQ_PRINCIPLE_OF <- c(
  mean_bse            = "fairagrodq:ParametricModelUncertainty",
  picp                = "fairagrodq:EmpiricalCoverageCalibration",
  mpiw                = "fairagrodq:EmpiricalCoverageCalibration",
  picp_corg           = "fairagrodq:EmpiricalCoverageCalibration",
  qrf_q05             = "fairagrodq:QuantileRegressionInterval",
  qrf_q50             = "fairagrodq:QuantileRegressionInterval",
  qrf_q95             = "fairagrodq:QuantileRegressionInterval",
  aoa_fraction_inside = "fairagrodq:ApplicabilityDomain"
)

#' Register/override token -> principle assignments (idempotent).
dq_set_principle <- function(map) {
  for (k in names(map)) .DQ_PRINCIPLE_OF[[k]] <<- map[[k]]
  invisible(.DQ_PRINCIPLE_OF)
}

#' Principle IRI for a measure token, or NA_character_ if none applies.
#' Exact assignment first; then narrow representation-based fallbacks:
#'   *_q<NN> on a BSE/posterior raster -> parametric; qrf_*  -> quantile.
dq_principle_of <- function(measure) {
  # .DQ_PRINCIPLE_OF is a NAMED VECTOR, so a missing name must be guarded with
  # %in%: vec[["absent"]] errors ("subscript out of bounds"), unlike a list.
  # Accuracy/evidence tokens (cv_rmse, cv_r2, training_n, ...) are deliberately
  # absent and MUST return NA, not error -- this path runs for every metric.
  if (length(measure) == 1L && !is.na(measure) &&
      measure %in% names(.DQ_PRINCIPLE_OF)) {
    p <- .DQ_PRINCIPLE_OF[[measure]]
    if (!is.null(p) && !is.na(p)) return(p)
  }
  if (grepl("^qrf_q[0-9]{1,3}$", measure)) return("fairagrodq:QuantileRegressionInterval")
  if (grepl("^bse_q[0-9]{1,3}$", measure)) return("fairagrodq:ParametricModelUncertainty")
  NA_character_
}

# =============================================================================
# C.  NODE EMISSION  -- principle concepts (+ scheme) for the principles used.
# =============================================================================
.dq_principle_scheme_node <- function() {
  list("@id" = "fairagrodq:UncertaintyExpressionPrinciple",
       "@type" = "skos:ConceptScheme",
       "skos:prefLabel" = "Spatial-uncertainty expression principles",
       "skos:definition" = paste0("Owned, PROVISIONAL scheme distinguishing the ",
         "principles by which spatially explicit uncertainty of a modelling / ",
         "classification product can be expressed and what each is allowed to ",
         "claim. Orthogonal to the DQV quality dimension. Pending FAIRagro/w3id ",
         "registration."),
       "skos:note" = "Provisional, project-defined; pending namespace registration.",
       "dct:isDefinedBy" = list("@id" = .DQ_PRINCIPLE_SCHEME_REF))
}

.dq_principle_node <- function(iri) {
  r <- .DQ_PRINCIPLES[[iri]]; if (is.null(r)) return(NULL)
  node <- list(
    "@id" = iri,
    "@type" = "skos:Concept",
    "skos:inScheme" = list("@id" = "fairagrodq:UncertaintyExpressionPrinciple"),
    "skos:prefLabel" = r$label,
    "skos:definition" = r$definition,
    "fairagrodq:representation" = r$representation,
    "fairagrodq:claimStatus"    = r$claimStatus,
    "fairagrodq:assumes"        = r$assumes)
  if (!is.null(r$ref) && !is.na(r$ref)) node[["skos:scopeNote"]] <- r$ref
  if (!is.null(r$seealso))             node[["rdfs:seeAlso"]] <- list("@id" = r$seealso)
  node
}

#' Lightweight rdf:Property definitions so the owned predicates are self-
#' describing in the crate (kept terse; honest about being provisional).
.dq_principle_predicate_nodes <- function() list(
  list("@id" = "fairagrodq:expressedBy", "@type" = "rdf:Property",
       "rdfs:label" = "expressed by (uncertainty principle)",
       "rdfs:comment" = "Links a quality metric or an uncertainty layer to the principle by which its spatial uncertainty is expressed. Provisional, owned."),
  list("@id" = "fairagrodq:representation", "@type" = "rdf:Property",
       "rdfs:label" = "uncertainty representation",
       "rdfs:comment" = "How an uncertainty is stored (per-pixel-sigma, quantile-raster, ensemble-realizations, dissimilarity-index-raster, binary-applicability-mask, class-probability-raster, scalar-diagnostic). Provisional, owned."),
  list("@id" = "fairagrodq:claimStatus", "@type" = "rdf:Property",
       "rdfs:label" = "uncertainty claim status",
       "rdfs:comment" = "What the uncertainty is allowed to claim (model-asserted, distribution-free-estimate, guaranteed-marginal-coverage, empirically-validated, trust-signal, classification-ambiguity). Provisional, owned."),
  list("@id" = "fairagrodq:assumes", "@type" = "rdf:Property",
       "rdfs:label" = "uncertainty assumption",
       "rdfs:comment" = "The assumption the claim rests on. Provisional, owned.")
)

#' Emit the principle concept nodes used (+ scheme + predicate definitions).
#' used = NULL -> emit all (back-compat / full catalogue).
dq_principle_entities <- function(used = NULL) {
  iris <- if (is.null(used)) names(.DQ_PRINCIPLES)
          else intersect(unique(used), names(.DQ_PRINCIPLES))
  if (!length(iris)) return(list())
  c(list(.dq_principle_scheme_node()),
    .dq_principle_predicate_nodes(),
    Filter(Negate(is.null), lapply(iris, .dq_principle_node)))
}

# =============================================================================
# D.  ATTACH  -- add fairagrodq:expressedBy to a metric node or a File node.
#     For a metric node (has skos:prefLabel = token), the principle is derived
#     from the token if not given. For a File (uncertainty raster), pass the
#     PRODUCTION principle explicitly (a path is not a token).
# =============================================================================
dq_attach_principle <- function(node, principle = NULL) {
  if (is.null(principle)) {
    tok <- node[["skos:prefLabel"]]
    if (is.null(tok)) return(node)              # not a metric; nothing to derive
    principle <- dq_principle_of(tok)
    if (is.na(principle)) return(node)          # no principle applies -> unchanged
  }
  node[["fairagrodq:expressedBy"]] <- list("@id" = principle)
  node
}

#' Collect the principle IRIs referenced by a set of metric nodes (and any extra
#' nodes already annotated, e.g. the BSE File), for dq_principle_entities().
dq_principles_used <- function(metric_nodes, extra_files = list()) {
  pick <- function(n) {
    e <- n[["fairagrodq:expressedBy"]]
    if (!is.null(e) && !is.null(e[["@id"]])) return(e[["@id"]])
    tok <- n[["skos:prefLabel"]]
    if (!is.null(tok)) { p <- dq_principle_of(tok); if (!is.na(p)) return(p) }
    NA_character_
  }
  vals <- c(vapply(metric_nodes, pick, character(1)),
            vapply(extra_files,  function(f) {
              e <- f[["fairagrodq:expressedBy"]]
              if (!is.null(e) && !is.null(e[["@id"]])) e[["@id"]] else NA_character_
            }, character(1)))
  unique(vals[!is.na(vals)])
}

# =============================================================================
# E.  SELF-TEST  -- source the core first, then this file, then dq_principles_selftest()
# =============================================================================
dq_principles_selftest <- function() {
  stopifnot(dq_principle_of("mean_bse") == "fairagrodq:ParametricModelUncertainty")
  stopifnot(dq_principle_of("picp")     == "fairagrodq:EmpiricalCoverageCalibration")
  stopifnot(dq_principle_of("qrf_q95")  == "fairagrodq:QuantileRegressionInterval")
  stopifnot(dq_principle_of("aoa_fraction_inside") == "fairagrodq:ApplicabilityDomain")
  stopifnot(is.na(dq_principle_of("cv_rmse")))     # accuracy measure: no principle
  # metric annotation derives the principle from the token
  if (exists("dq_metric_entity")) {
    m <- dq_attach_principle(dq_metric_entity("picp"))
    stopifnot(m[["fairagrodq:expressedBy"]][["@id"]] == "fairagrodq:EmpiricalCoverageCalibration")
    stopifnot(m[["dqv:inDimension"]][["@id"]] == "fairagrodq:NumericalSpatialUncertainty")  # both axes
  }
  # file annotation takes an explicit production principle
  fe <- dq_attach_principle(list("@id"="cogs/BSE_202-10.tif","@type"="File"),
                            "fairagrodq:ParametricModelUncertainty")
  stopifnot(fe[["fairagrodq:expressedBy"]][["@id"]] == "fairagrodq:ParametricModelUncertainty")
  used <- dq_principles_used(list(dq_attach_principle(dq_metric_entity("picp"))),
                             extra_files = list(fe))
  stopifnot(length(dq_principle_entities(used)) >= 2)
  message("dq_uncertainty_principles.R self-test passed.")
  invisible(TRUE)
}
