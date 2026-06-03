# ============================================================================
# _crop_specs.R
#
# Shared helpers for the PhenoPhaseR RO-Crate builders. Single source of
# truth for:
#
#   - crop specifications (DWD Plant ID, common names, binomial) for the
#     eight crops in scope of the family blueprint (winter wheat, winter
#     rye, winter barley, winter rapeseed, spring barley, oats, maize,
#     sugar beet)
#   - the role-aware creators list for each crate kind (filter variants, PHASE)
#   - the layered keyword scheme (mandatory core + per-crop + artefact-specific)
#
# Source this file from build_filtervariant_ro_crate.R and
# build_phase_cog_ro_crate.R before calling the main entry points. The
# entry-point signatures keep their original parameters as overrides so
# existing callers continue to work without changes.
#
# Subject vocabulary: as of v1.6.2, no controlled-vocabulary subject anchors
# (AGROVOC, Wikidata, or others) are emitted into `schema:about` /
# `dct:subject`. Earlier v1.6.0 / v1.6.1 versions of this file referenced
# AGROVOC concept URIs that were later found to point at unrelated concepts
# (e.g. "sawlogs" instead of "winter rye", "local authorities" instead of
# "phenology") when resolved against agrovoc.fao.org. Rather than swap to a
# different controlled vocabulary and inherit the same verification burden,
# the deposit family relies on free-text `schema:keywords` / `dcat:keyword`
# (which Zenodo, OpenAIRE, BonaRes and Google Dataset Search all index) plus
# the GeoNames spatial-coverage URI on the root dataset for place anchoring.
# This is honest about the level of semantic anchoring that has been
# verified, and keeps the deposits valid RO-Crate 1.2 (subject anchors are
# optional in the profile). Previously-published deposits retain their
# original `schema:about` entries on Zenodo as historical record; the
# cleanup will land on their next coordinated re-release.
#
# Author : M. Möller, 2026
# License: MIT (this script); CC-BY-4.0 (the output crate contents)
# ============================================================================


# ---- Crop specifications --------------------------------------------------
# Each crop is identified by its DWD Plant ID. Common names are given in
# English (canonical for international discovery) and German (canonical for
# the JKI / DWD audience). The binomial is the Latin botanical name.
.CROP_SPECS <- list(
  "202" = list(
    dwd_id          = 202L,
    common_name_en  = "winter wheat",
    common_name_de  = "Winterweizen",
    binomial        = "Triticum aestivum"
  ),
  "203" = list(
    dwd_id          = 203L,
    common_name_en  = "winter rye",
    common_name_de  = "Winterroggen",
    binomial        = "Secale cereale"
  ),
  "204" = list(
    dwd_id          = 204L,
    common_name_en  = "winter barley",
    common_name_de  = "Wintergerste",
    binomial        = "Hordeum vulgare"
  ),
  "205" = list(
    dwd_id          = 205L,
    common_name_en  = "winter rapeseed",
    common_name_de  = "Winterraps",
    binomial        = "Brassica napus"
  ),
  "207" = list(
    dwd_id          = 207L,
    common_name_en  = "spring barley",
    common_name_de  = "Sommergerste",
    binomial        = "Hordeum vulgare"
  ),
  "208" = list(
    dwd_id          = 208L,
    common_name_en  = "oats",
    common_name_de  = "Hafer",
    binomial        = "Avena sativa"
  ),
  "215" = list(
    dwd_id          = 215L,
    common_name_en  = "maize",
    common_name_de  = "Mais",
    binomial        = "Zea mays"
  ),
  # Sugar beet (DWD plant ID 253): Beta vulgaris ssp. vulgaris var.
  # saccharifera, Altissima cultivar group. DWD reports current-year beet
  # observations under the generic object-ID 250 ("Rueben ohne Sortenangabe",
  # beet without variety specification) and reassigns them to 252 (fodder
  # beet, "Futter-Ruebe") or 253 (sugar beet, "Zucker-Ruebe") after year-end
  # via the *_Ruebe_Spezifizierung* file. The 252-vs-253 mapping is per the
  # authoritative DWD phase catalogue (PH_Beschreibung_PflanzePhase.txt):
  #   250  "Rueben ohne Sortenangabe"  (generic, no variety)
  #   252  "Futter-Ruebe"               (fodder beet, Crassa group)
  #   253  "Zucker-Ruebe"               (sugar beet,  Altissima group)
  # Sources:
  #   https://opendata.dwd.de/climate_environment/CDC/observations_germany/
  #     phenology/annual_reporters/crops/recent/
  #     DESCRIPTION_obsgermany-phenology-annual_reporters-crops-recent_en.pdf
  #   PH_Beschreibung_PflanzePhase.txt (DWD CDC plant/phase catalogue)
  # Fodder beet (252, Beta vulgaris var. rapa / Crassa group) is the other
  # post-year-end specification but is not included here. To add it later,
  # append an entry alongside this one.
  "253" = list(
    dwd_id          = 253L,
    common_name_en  = "sugar beet",
    common_name_de  = "Zuckerrübe",
    binomial        = "Beta vulgaris ssp. vulgaris var. saccharifera"
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


# ---- Subject (schema:about / dct:subject) builder -------------------------
# As of v1.6.2, no controlled-vocabulary subject anchors (AGROVOC, Wikidata,
# or others) are emitted. This function preserves the original return shape
# so existing builder call sites continue to compile and run, but returns
# empty lists for `subject_refs`, `defined_terms`, and a NULL
# `defined_term_set`. The builders skip emitting `schema:about` /
# `dct:subject` when `subject_refs` is empty; the @graph carries no
# `DefinedTerm` / `DefinedTermSet` entities sourced from this function.
#
# Free-text subject anchoring is handled exclusively via `build_keywords()`
# (Schema.org `keywords` and DCAT `dcat:keyword`), which Zenodo, OpenAIRE,
# BonaRes, and Google Dataset Search all index. Place anchoring is handled
# via the GeoNames URI on the root dataset's `spatialCoverage`.
#
# If a future release brings back a controlled-vocabulary subject layer,
# extend this function to populate the three return slots; the builders
# will pick the new entries up without further changes.
build_subject_entities <- function(crop,
                                   artefact = c("filter_variant", "phase")) {
  artefact <- match.arg(artefact)

  list(
    subject_refs     = list(),
    defined_terms    = list(),
    defined_term_set = NULL
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
