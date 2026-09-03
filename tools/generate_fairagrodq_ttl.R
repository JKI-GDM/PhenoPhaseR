#!/usr/bin/env Rscript
# =============================================================================
# generate_fairagrodq_ttl.R
#   Generate the standalone fairagrodq SKOS/DQV vocabulary (Turtle) DIRECTLY
#   from the registries in dq_vocab_core.R and dq_uncertainty_principles.R, so
#   the published vocabulary is a build artefact of the pipeline and can never
#   drift from the terms the PhenoPhaseR RO-Crate builders emit.
#
#   Only the OWNED terms are emitted: the fairagrodq: spatial-uncertainty
#   DIMENSIONS (dq_vocab_core.R) and the UncertaintyExpressionPrinciple scheme,
#   its four owned predicates and its eight principle concepts
#   (dq_uncertainty_principles.R). Genuine ISO 19157-1 elements are NOT emitted
#   -- they belong to the iso19157: namespace, not ours (honest anchoring).
#
#   The term triples come from the SAME emitter functions the builders call
#   (dq_dimension_entities(), dq_principle_entities()). The script only adds the
#   vocabulary-level owl:Ontology header (publication metadata) and the @prefix
#   block. DO NOT hand-edit the generated .ttl -- edit the R registries and
#   re-run this script.
#
# USAGE
#   Rscript generate_fairagrodq_ttl.R [src_dir] [out_file]
#       src_dir  directory holding the two R files   (default ".")
#       out_file output path                         (default "fairagrodq.ttl")
#   or source() it and call generate_fairagrodq_ttl(src_dir, out_file, ...).
#
#   Base R only -- nothing to install.
#
# Author: M. Möller, 2026.  License: MIT (script); CC-BY-4.0 (the vocabulary).
# =============================================================================


# ---- 1. Configuration -------------------------------------------------------

.FAIRAGRODQ_PREFIXES <- c(
  fairagrodq = "https://w3id.org/fairagro/dq#",
  dqv        = "http://www.w3.org/ns/dqv#",
  skos       = "http://www.w3.org/2004/02/skos/core#",
  dct        = "http://purl.org/dc/terms/",
  rdf        = "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
  rdfs       = "http://www.w3.org/2000/01/rdf-schema#",
  owl        = "http://www.w3.org/2002/07/owl#",
  xsd        = "http://www.w3.org/2001/XMLSchema#",
  vann       = "http://purl.org/vocab/vann/"
)

# Vocabulary-level metadata (the publication layer; NOT part of the crate
# emission). Bump `version` / `date` per release; the rest is stable. The
# informing reference (dct:source) is pulled from the registry, not set here.
.FAIRAGRODQ_META <- list(
  version       = "0.3.0",
  date          = "2026-08-20",          # release date; pin for reproducible builds
  title         = "FAIRagro data-quality vocabulary for spatially explicit uncertainty (fairagrodq)",
  description   = paste0(
    "A provisional, project-defined vocabulary that extends the W3C Data Quality ",
    "Vocabulary (DQV) for spatially explicit uncertainty in modelling and ",
    "classification products, for which ISO 19157-1:2023 provides no quality ",
    "element. It supplies spatial-uncertainty quality dimensions (which aspect of ",
    "quality is meant) and an orthogonal SKOS scheme of uncertainty expression ",
    "principles (how an uncertainty was produced and what it may claim). Genuine ",
    "ISO 19157-1 elements are referenced from their own namespace and are NOT ",
    "redefined here; no term asserts conformance to a standard that does not ",
    "contain it."),
  creator_orcid = "https://orcid.org/0000-0002-1918-7747",
  publisher     = "FAIRagro / Julius Kuehn-Institut (JKI)",
  license       = "https://creativecommons.org/licenses/by/4.0/",
  comment       = paste0(
    "PROVISIONAL. The https://w3id.org/fairagro/dq namespace is not yet ",
    "registered as a resolvable w3id redirect; this document is the authoritative ",
    "definition pending that registration. Term IRIs are stable and are intended ",
    "to be carried unchanged into the registered namespace.")
)

# Predicates whose objects are natural-language prose (eligible for a language
# tag when `lang` is given). Controlled-token predicates (representation /
# claimStatus / assumes) are codes and are NEVER language-tagged.
.FAIRAGRODQ_PROSE_PREDICATES <- c(
  "skos:prefLabel", "skos:definition", "skos:note", "skos:scopeNote",
  "rdfs:label", "rdfs:comment", "dct:title", "dct:description", "rdfs:comment"
)


# ---- 2. Turtle serialisation (base R) --------------------------------------

.fdq_is_full_iri <- function(x) grepl("://", x, fixed = TRUE)

# IRI-or-CURIE reference -> Turtle term. Full IRIs are wrapped in <>; CURIEs
# (prefix:local, where the prefix is declared above) pass through unchanged.
.fdq_ref <- function(x) if (.fdq_is_full_iri(x)) paste0("<", x, ">") else x

# Escape a Turtle short-string literal. Backslash first.
.fdq_esc <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE)
  s <- gsub("\"", "\\\"", s, fixed = TRUE)
  s <- gsub("\r", "\\r",  s, fixed = TRUE)
  s <- gsub("\n", "\\n",  s, fixed = TRUE)
  s <- gsub("\t", "\\t",  s, fixed = TRUE)
  s
}

`%||%` <- function(a, b) if (is.null(a) || (length(a)==1 && is.na(a))) b else a

.fdq_literal <- function(s, lang = NULL) {
  out <- paste0("\"", .fdq_esc(s), "\"")
  if (!is.null(lang) && nzchar(lang)) out <- paste0(out, "@", lang)
  out
}

# Serialise one JSON-LD-style node (named list) to a Turtle block. Properties
# are emitted in registry insertion order; @type becomes `a A, B`.
.fdq_node_to_ttl <- function(node, lang = NULL) {
  preds <- character(0)
  types <- node[["@type"]]
  if (!is.null(types))
    preds <- c(preds, paste0("a ", paste(vapply(as.character(types), .fdq_ref, ""),
                                          collapse = ", ")))
  for (k in names(node)) {
    if (k %in% c("@id", "@type")) next
    v <- node[[k]]
    if (is.list(v) && !is.null(v[["@id"]])) {
      obj <- .fdq_ref(v[["@id"]])                       # IRI / CURIE reference
    } else {
      lg  <- if (k %in% .FAIRAGRODQ_PROSE_PREDICATES) lang else NULL
      obj <- .fdq_literal(as.character(v)[1], lg)        # literal (token or prose)
    }
    preds <- c(preds, paste0(k, " ", obj))
  }
  paste0(.fdq_ref(node[["@id"]]), "\n    ",
         paste(preds, collapse = " ;\n    "), " .\n")
}


# ---- 3. Header + banners ----------------------------------------------------

.fdq_prefix_block <- function() {
  nm <- paste0(names(.FAIRAGRODQ_PREFIXES), ":")
  w  <- max(nchar(nm))
  paste(sprintf("@prefix %-*s <%s> .", w, nm, unname(.FAIRAGRODQ_PREFIXES)),
        collapse = "\n")
}

.fdq_banner <- function(title)
  paste0("#", strrep("#", 76), "\n#  ", title, "\n#", strrep("#", 76), "\n")

.fdq_autogen_notice <- function() paste0(
  "# fairagrodq vocabulary -- GENERATED FILE, do not hand-edit.\n",
  "# Source of truth: dq_vocab_core.R + dq_uncertainty_principles.R\n",
  "# Regenerate with: Rscript generate_fairagrodq_ttl.R\n\n")

.fdq_header_block <- function(saeurich_doi, lang = NULL) {
  m        <- .FAIRAGRODQ_META
  onto_iri <- sub("#$", "", .FAIRAGRODQ_PREFIXES[["fairagrodq"]])
  paste0(
    "<", onto_iri, ">\n",
    "    a owl:Ontology ;\n",
    "    dct:title ", .fdq_literal(m$title, lang), " ;\n",
    "    dct:description ", .fdq_literal(m$description, lang), " ;\n",
    "    dct:creator <", m$creator_orcid, "> ;\n",
    "    dct:publisher ", .fdq_literal(m$publisher), " ;\n",
    "    dct:license <", m$license, "> ;\n",
    "    dct:source <", saeurich_doi, "> ;\n",
    "    dct:modified \"", m$date, "\"^^xsd:date ;\n",
    "    owl:versionInfo ", .fdq_literal(m$version), " ;\n",
    "    vann:preferredNamespaceUri ", .fdq_literal(.FAIRAGRODQ_PREFIXES[["fairagrodq"]]), " ;\n",
    "    vann:preferredNamespacePrefix ", .fdq_literal("fairagrodq"), " ;\n",
    "    rdfs:comment ", .fdq_literal(m$comment, lang), " .\n")
}

.fdq_count_triples <- function(nodes)
  sum(vapply(nodes, function(n)
    length(n[["@type"]]) + sum(!(names(n) %in% c("@id", "@type"))),
    integer(1)))


# ---- 4. Driver --------------------------------------------------------------

#' Generate fairagrodq.ttl from the pipeline registries.
#'
#' @param src_dir  directory holding dq_vocab_core.R + dq_uncertainty_principles.R
#' @param out_file output Turtle path
#' @param version,date  override the publication version / release date
#' @param lang     language tag for PROSE literals (prefLabel/definition/...).
#'                 NULL (default) emits plain literals, byte-identical to the
#'                 crate emission. Set "en" for language-tagged prose labels in
#'                 the standalone vocabulary (controlled tokens stay plain
#'                 either way).
generate_fairagrodq_ttl <- function(src_dir  = ".",
                                     out_file = "fairagrodq.ttl",
                                     version  = .FAIRAGRODQ_META$version,
                                     date     = .FAIRAGRODQ_META$date,
                                     lang     = NULL) {
  .FAIRAGRODQ_META$version <<- version
  .FAIRAGRODQ_META$date    <<- date

  core <- file.path(src_dir, "dq_vocab_core.R")
  prin <- file.path(src_dir, "dq_uncertainty_principles.R")
  if (!file.exists(core)) stop("not found: ", core)
  if (!file.exists(prin)) stop("not found: ", prin)

  # Source the registries (self-contained; core first, then its extension).
  env <- new.env(parent = globalenv())
  sys.source(core, envir = env)
  sys.source(prin, envir = env)

  # Collect OWNED nodes only. Drop the genuine ISO 19157-1 dimensions: they are
  # external terms, not ours, and re-stating them here would overclaim.
  all_dims  <- env$dq_dimension_entities(NULL)
  fdq_dims  <- Filter(function(n) startsWith(n[["@id"]], "fairagrodq:"), all_dims)
  prin_ents <- env$dq_principle_entities(NULL)   # scheme + 4 predicates + 8 concepts
  if (!length(fdq_dims))
    stop("no fairagrodq: dimensions found -- did dq_vocab_core.R source correctly?")

  # Informing reference straight from the registry (header stays in sync).
  saeurich_doi <- fdq_dims[[1]][["dct:isDefinedBy"]][["@id"]]

  blocks_dims <- vapply(fdq_dims,  .fdq_node_to_ttl, "", lang = lang)
  blocks_prin <- vapply(prin_ents, .fdq_node_to_ttl, "", lang = lang)

  ttl <- paste0(
    .fdq_autogen_notice(),
    .fdq_prefix_block(), "\n\n",
    .fdq_banner("Vocabulary description"),
    .fdq_header_block(saeurich_doi, lang), "\n",
    .fdq_banner("Quality dimensions (extend dqv:Dimension; ISO 19157-1 elements stay external)"),
    paste(blocks_dims, collapse = "\n"), "\n",
    .fdq_banner("Expression principles: scheme, owned predicates, eight concepts"),
    paste(blocks_prin, collapse = "\n"))

  # ---- 5b. Owned measure concepts (registered-route step 2) -----------------
  meas_tab <- tryCatch(get(".DQ_MEASURES"), error = function(e) NULL)
  if (is.null(meas_tab)) {
    src_env <- new.env()
    sys.source(file.path(src_dir, "dq_vocab_core.R"), envir = src_env)
    meas_tab <- get(".DQ_MEASURES", envir = src_env)
  }
  basis_principle <- c(propagated         = "fairagrodq:AnalyticalErrorPropagation",
                       `cross-validation` = "fairagrodq:EmpiricalCoverageCalibration",
                       validation         = "fairagrodq:EmpiricalCoverageCalibration")
  meas <- Filter(function(m) is.list(m) && is.character(m[["dimension"]]) &&
                   !is.na(m[["dimension"]][1]) &&
                   startsWith(m[["dimension"]][1], "fairagrodq:"), meas_tab)
  if (length(meas)) {
    ttl <- paste0(ttl, "\n", .fdq_banner("Owned measure concepts (dqv:Metric)"))
    for (tok in names(meas)) {
      m    <- meas[[tok]]
      node <- list("@id" = paste0("fairagrodq:", tok),
                   "@type" = c("dqv:Metric", "skos:Concept"),
                   "skos:prefLabel"  = tok,
                   "skos:definition" = m$definition,
                   "dqv:inDimension" = list("@id" = m$dimension))
      pr <- basis_principle[m$basis %||% ""]
      if (length(pr) == 1 && !is.na(pr))
        node[["fairagrodq:expressedBy"]] <- list("@id" = unname(pr))
      if (is.character(m$unit) && !is.na(m$unit))
        node[["skos:note"]] <- paste0("Unit: ", m$unit, ".")
      if (is.character(m$defined_by))
        node[["dct:isDefinedBy"]] <- list("@id" = m$defined_by)
      ttl <- paste0(ttl, "\n", .fdq_node_to_ttl(node, lang = NULL))
    }
  }

  writeLines(ttl, out_file)

  n_terms  <- length(fdq_dims) + length(prin_ents)
  message(sprintf("Wrote %s", out_file))
  message(sprintf("  owned terms : %d  (%d dimensions; scheme + 4 predicates + %d principles)",
                  n_terms, length(fdq_dims), length(prin_ents) - 5L))
  message(sprintf("  subjects    : %d  (incl. ontology header)", n_terms + 1L))
  message(sprintf("  triples     : %d", .fdq_count_triples(c(fdq_dims, prin_ents)) + 12L))
  message(sprintf("  prose lang  : %s", if (is.null(lang)) "(plain -- matches crate emission)" else lang))
  invisible(out_file)
}


# ---- 5. Run as a script -----------------------------------------------------

if (!interactive() && sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  generate_fairagrodq_ttl(
    src_dir  = if (length(args) >= 1) args[[1]] else ".",
    out_file = if (length(args) >= 2) args[[2]] else "fairagrodq.ttl")
}
