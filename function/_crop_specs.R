# ============================================================================
# _crop_specs.R
#
# Shared helpers for the PhenoPhaseR RO-Crate builders. Single source of
# truth for:
#
#   - crop specifications (DWD Plant ID, common names, binomial, AGROVOC URI,
#     Wikidata QID) for the eight crops in scope of the family blueprint
#     (winter wheat, winter rye, winter barley, winter rapeseed, spring
#     barley, oats, maize, sugar beet)
#   - the role-aware creators list for each crate kind (filter variants, PHASE)
#   - the layered keyword scheme (mandatory core + per-crop + artefact-specific)
#   - AGROVOC subject terms shared across the family (phenology, GDD,
#     spatial interpolation, Germany)
#   - DefinedTerm / DefinedTermSet entity builders that wrap AGROVOC concept
#     URIs into proper JSON-LD nodes referenced from `schema:about` /
#     `dct:subject` on the root dataset
#
# Source this file from build_filtervariant_ro_crate.R and
# build_phase_cog_ro_crate.R before calling the main entry points. The
# entry-point signatures keep their original parameters as overrides so
# existing callers continue to work without changes.
#
# AGROVOC URIs are best-effort literals. Verify each against the AGROVOC
# SPARQL endpoint (https://agrovoc.fao.org/sparql) or the concept browser
# (https://agrovoc.fao.org/browse/agrovoc/) before publishing.
#
# Author : M. Möller, 2026
# License: MIT (this script); CC-BY-4.0 (the output crate contents)
# ============================================================================


# ---- Crop specifications --------------------------------------------------
# Each crop is identified by its DWD Plant ID. Common names are given in
# English (canonical for international discovery) and German (canonical for
# the JKI / DWD audience). The AGROVOC concept URI bridges the species into
# the FAO Linked Open Data cloud; the Wikidata QID gives a second, cross-
# domain handle that AGROVOC concepts cross-link to via skos:exactMatch.
#
# IMPORTANT: AGROVOC URIs below are best-effort. Verify each against the
# AGROVOC SPARQL endpoint before publishing a new deposit. The Wikidata
# QIDs are likewise unverified; resolve them at https://www.wikidata.org/
# wiki/<QID> before relying on them.
.CROP_SPECS <- list(
  "202" = list(
    dwd_id          = 202L,
    common_name_en  = "winter wheat",
    common_name_de  = "Winterweizen",
    binomial        = "Triticum aestivum",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_8412",
    wikidata_qid    = "Q11575"
  ),
  "203" = list(
    dwd_id          = 203L,
    common_name_en  = "winter rye",
    common_name_de  = "Winterroggen",
    binomial        = "Secale cereale",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_6829",
    wikidata_qid    = "Q12539"
  ),
  "204" = list(
    dwd_id          = 204L,
    common_name_en  = "winter barley",
    common_name_de  = "Wintergerste",
    binomial        = "Hordeum vulgare",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_3704",
    wikidata_qid    = "Q188459"
  ),
  "205" = list(
    dwd_id          = 205L,
    common_name_en  = "winter rapeseed",
    common_name_de  = "Winterraps",
    binomial        = "Brassica napus",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_27117",
    wikidata_qid    = "Q146281"
  ),
  "207" = list(
    dwd_id          = 207L,
    common_name_en  = "spring barley",
    common_name_de  = "Sommergerste",
    binomial        = "Hordeum vulgare",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_3704",
    wikidata_qid    = "Q188459"
  ),
  "208" = list(
    dwd_id          = 208L,
    common_name_en  = "oats",
    common_name_de  = "Hafer",
    binomial        = "Avena sativa",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_842",
    wikidata_qid    = "Q12953"
  ),
  "215" = list(
    dwd_id          = 215L,
    common_name_en  = "maize",
    common_name_de  = "Mais",
    binomial        = "Zea mays",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_12332",
    wikidata_qid    = "Q11577"   # VERIFY — Zea mays QID
  ),
  "253" = list(
    dwd_id          = 253L,
    common_name_en  = "sugar beet",
    common_name_de  = "Zuckerrübe",
    binomial        = "Beta vulgaris ssp. vulgaris var. saccharifera",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_7499",  # verified
    wikidata_qid    = "Q151964"  # verified — Wikidata "sugar beet"
  )
)


crop_spec <- function(dwd_id) {
  key <- as.character(dwd_id)
  spec <- .CROP_SPECS[[key]]
  if (is.null(spec))
    stop("Unknown DWD Plant ID: ", dwd_id,
         ". Add it to .CROP_SPECS in _crop_specs.R first.")
  spec
}


# ---- Family-wide AGROVOC concepts ----------------------------------------
# Concepts that apply to every crop in the family. The crop-specific concept
# (per-deposit) is taken from the crop_spec; these supplement it. Each URI
# becomes a DefinedTerm entity in the @graph and is referenced from the
# root dataset's `schema:about` / `dct:subject`.
.VOCAB_TERMS_CORE <- list(
  phenology = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_28793",
    label = "phenology"
  ),
  growing_degree_days = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_36099",
    label = "growing degree days"
  ),
  spatial_interpolation = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_36300",
    label = "spatial interpolation"
  ),
  germany = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_3258",
    label = "Germany"
  )
)


# ---- Default creators list -------------------------------------------------
# A creator entry is a list with @id (typically an ORCID URI), name, and
# role. Roles use DataCite ContributorType vocabulary literals so they
# round-trip cleanly to Zenodo's deposit fields and into DataCite metadata.
#
# Family policy (set once, here): for each per-crop deposit, both the
# filter-variant (Hook A) and PHASE (Hook B) crates carry the same author
# list. This treats data management as a pipeline-wide contribution rather
# than tying it to a specific step, and removes the C-vs-D asymmetry that
# was present in the winter-wheat deposits at concept DOIs 19483111 and
# 19571847. Override at the call site if a specific deposit needs a
# different set of contributors.
.DEFAULT_CREATORS_FAMILY <- list(
  list(
    "@id"   = "https://orcid.org/0000-0002-1918-7747",
    name    = "Markus M\u00f6ller",
    role    = "Producer",
    affiliation_ror = "https://ror.org/022d5qt08"
  ),
  list(
    "@id"   = "https://orcid.org/0000-0002-5079-9557",
    name    = "Mahdi Hedayat Mahmoudi",
    role    = "DataManager",
    affiliation_ror = "https://ror.org/022d5qt08"
  ),
  list(
    "@id"   = "https://orcid.org/0009-0003-4330-6309",
    name    = "Paul Peschel",
    role    = "DataManager",
    affiliation_ror = "https://ror.org/022d5qt08"
  )
)


default_creators <- function(artefact = c("filter_variant", "phase")) {
  artefact <- match.arg(artefact)
  # Same list for both artefact families by policy. If you decide to scope
  # data-management contributions to only one step, branch on `artefact`
  # here and return the appropriate subset.
  .DEFAULT_CREATORS_FAMILY
}


# ---- Keyword builder -------------------------------------------------------
# Layered scheme:
#   1. Mandatory family-wide core (every deposit, A through D, all crops)
#   2. Per-crop additions (only on crop-specific deposits, i.e. C and D)
#   3. Artefact-specific additions (filter variants vs. PHASE)
#
# Returns a character vector that is fed identically to `keywords`
# (Schema.org) and `dcat:keyword` (DCAT 3) on the root dataset.
build_keywords <- function(crop,
                           artefact = c("filter_variant", "phase")) {
  artefact <- match.arg(artefact)

  core <- c("phenology", "Germany", "DWD", "PhenoPhaseR",
            "FAIR", "RO-Crate", "1 km resolution", "1993\u20132024")

  per_crop <- c(
    crop$common_name_en,
    crop$binomial,
    sprintf("DWD Plant ID %d", crop$dwd_id)
  )

  artefact_specific <- switch(artefact,
    filter_variant = c("growing degree days", "PHASE model",
                       "quality control", "adaptive filter",
                       "ISO 19157-1", "DQV"),
    phase          = c("growing degree days", "spatial interpolation",
                       "BBCH", "Cloud Optimized GeoTIFF", "EPSG:25832",
                       "BAM", "kriging", "uncertainty",
                       "ISO 19157-1", "DQV")
  )

  unique(c(core, per_crop, artefact_specific))
}


# ---- AGROVOC DefinedTerm / DefinedTermSet builders ------------------------
# Build a Schema.org DefinedTerm node for one AGROVOC concept URI. The
# generated node is hoisted into the @graph alongside the other contextual
# entities and is referenced by URI only from the root dataset's
# `schema:about` / `dct:subject`.
.defined_term_agrovoc <- function(uri, name,
                                  alternate_names = character(0),
                                  wikidata_qid    = NULL) {
  node <- list(
    "@id"             = uri,
    "@type"           = "DefinedTerm",
    "name"            = name,
    "termCode"        = basename(uri),
    "inDefinedTermSet" = list("@id" = "http://aims.fao.org/aos/agrovoc/")
  )
  if (length(alternate_names))
    node[["alternateName"]] <- alternate_names
  if (!is.null(wikidata_qid) && nzchar(wikidata_qid))
    node[["skos:exactMatch"]] <- list(
      "@id" = paste0("https://www.wikidata.org/entity/", wikidata_qid)
    )
  node
}


.defined_term_set_agrovoc <- function() {
  list(
    "@id"       = "http://aims.fao.org/aos/agrovoc/",
    "@type"     = "DefinedTermSet",
    "name"      = "AGROVOC Multilingual Thesaurus",
    "url"       = "https://agrovoc.fao.org/",
    "publisher" = list("@id" = "https://ror.org/00pe0tf51"),  # FAO
    "license"   = "https://creativecommons.org/licenses/by/4.0/"
  )
}


# ---- Subject (schema:about / dct:subject) builder -------------------------
# Returns the list of @id references to put in `schema:about` and
# `dct:subject` on the root dataset, plus the full set of DefinedTerm
# (and the DefinedTermSet) entities to hoist into the @graph. The PHASE
# crates additionally subject the spatial-interpolation concept; the
# filter-variant crates do not (Step 5–6 outputs are pre-interpolation).
build_subject_entities <- function(crop,
                                   artefact = c("filter_variant", "phase")) {
  artefact <- match.arg(artefact)

  # Always-present concepts: the crop + phenology + GDD
  crop_term <- .defined_term_agrovoc(
    uri             = crop$agrovoc_uri,
    name            = crop$common_name_en,
    alternate_names = c(crop$common_name_de, crop$binomial),
    wikidata_qid    = crop$wikidata_qid
  )

  core_terms <- list(
    .defined_term_agrovoc(.VOCAB_TERMS_CORE$phenology$uri,
                          .VOCAB_TERMS_CORE$phenology$label),
    .defined_term_agrovoc(.VOCAB_TERMS_CORE$growing_degree_days$uri,
                          .VOCAB_TERMS_CORE$growing_degree_days$label),
    .defined_term_agrovoc(.VOCAB_TERMS_CORE$germany$uri,
                          .VOCAB_TERMS_CORE$germany$label)
  )

  artefact_terms <- if (identical(artefact, "phase")) {
    list(.defined_term_agrovoc(.VOCAB_TERMS_CORE$spatial_interpolation$uri,
                               .VOCAB_TERMS_CORE$spatial_interpolation$label))
  } else list()

  all_terms <- c(list(crop_term), core_terms, artefact_terms)
  subject_refs <- lapply(all_terms, function(t) list("@id" = t[["@id"]]))

  list(
    subject_refs    = subject_refs,
    defined_terms   = all_terms,
    defined_term_set = .defined_term_set_agrovoc()
  )
}


# ---- Creator / Person entity helpers --------------------------------------
# Build the `creator` / `dct:creator` reference list (URIs only) plus the
# Person entities to hoist into the @graph. Roles are exposed both as a
# top-level schema:Role wrapper (for Schema.org consumers) and as a flat
# property on the Person itself.
build_creator_entities <- function(creators) {
  # creator / dct:creator on the root dataset: @id references only
  creator_refs <- lapply(creators, function(c) list("@id" = c[["@id"]]))

  # Hoisted Person entities. Each carries name, ORCID, role, and affiliation.
  person_entities <- lapply(creators, function(c) {
    p <- list(
      "@id"          = c[["@id"]],
      "@type"        = "Person",
      "name"         = c$name,
      "schema:roleName" = c$role,
      "prov:role"    = c$role
    )
    if (!is.null(c$affiliation_ror) && nzchar(c$affiliation_ror))
      p[["affiliation"]] <- list("@id" = c$affiliation_ror)
    p
  })

  list(
    creator_refs   = creator_refs,
    person_entities = person_entities
  )
}
