# ============================================================================
# _crop_specs.R
#
# Shared helpers for the PhenoPhaseR RO-Crate builders. Single source of
# truth for:
#
#   - crop specifications (DWD Plant ID, common names, binomial, AGROVOC URI,
#     Wikidata QID) for the seven crops in scope of the family blueprint
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
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_8412",  # VERIFIED 2026-06
    wikidata_qid    = "Q11575"  # wikidata unverified
  ),
  "203" = list(
    dwd_id          = 203L,
    common_name_en  = "winter rye",
    common_name_de  = "Winterroggen",
    binomial        = "Secale cereale",
    # AGROVOC has no "winter rye" concept; c_14010 is the generic "rye"
    # (Secale cereale). The winter/spring distinction is carried by the
    # DWD Plant ID (203) and the free-text keyword, not by the AGROVOC anchor.
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_14010",  # VERIFIED 2026-06 (rye, generic)
    agrovoc_is_generic = TRUE,
    wikidata_qid    = "Q12539"  # wikidata unverified
  ),
  "204" = list(
    dwd_id          = 204L,
    common_name_en  = "winter barley",
    common_name_de  = "Wintergerste",
    binomial        = "Hordeum vulgare",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_5b8bcf68",  # VERIFIED 2026-06 (winter barley)
    wikidata_qid    = "Q188459"  # wikidata unverified
  ),
  "205" = list(
    dwd_id          = 205L,
    common_name_en  = "winter rapeseed",
    common_name_de  = "Winterraps",
    binomial        = "Brassica napus",
    # AGROVOC has no "winter rapeseed" concept; c_25499 is the generic
    # "rapeseed" (Brassica napus). The winter/spring distinction is carried
    # by the DWD Plant ID (205) and the free-text keyword.
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_25499",  # VERIFIED 2026-06 (rapeseed, generic)
    agrovoc_is_generic = TRUE,
    wikidata_qid    = "Q146281"  # wikidata unverified
  ),
  "207" = list(
    dwd_id          = 207L,
    common_name_en  = "spring barley",
    common_name_de  = "Sommergerste",
    binomial        = "Hordeum vulgare",
    # Distinct AGROVOC concept from winter barley (204): AGROVOC does
    # distinguish spring barley. Earlier config wrongly shared one URI.
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_ad10e027",  # VERIFIED 2026-06 (spring barley)
    wikidata_qid    = "Q188459"  # wikidata unverified
  ),
  "208" = list(
    dwd_id          = 208L,
    common_name_en  = "oats",
    common_name_de  = "Hafer",
    binomial        = "Avena sativa",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_5287",  # VERIFIED 2026-06 (oats)
    wikidata_qid    = "Q12953"  # wikidata unverified
  ),
  "215" = list(
    dwd_id          = 215L,
    common_name_en  = "maize",
    common_name_de  = "Mais",
    binomial        = "Zea mays",
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_12332",  # VERIFIED 2026-06 (maize)
    wikidata_qid    = "Q11577"  # wikidata unverified — VERIFY Zea mays QID
  ),
  "253" = list(
    dwd_id          = 253L,
    common_name_en  = "sugar beet",
    common_name_de  = "Zucker-Ruebe",
    binomial        = "Beta vulgaris",
    # Root crop (not a cereal). AGROVOC c_7499 = "sugar beet", supplied and
    # looked up by the maintainer 2026-06; confirm on first build via
    # verify_agrovoc_uris(). Beta vulgaris is the species; AGROVOC's sugar
    # beet concept is the appropriate crop-level anchor.
    agrovoc_uri     = "http://aims.fao.org/aos/agrovoc/c_7499",  # VERIFIED 2026-06 (sugar beet)
    wikidata_qid    = "Q23800"  # wikidata unverified — VERIFY Beta vulgaris QID
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
    uri   = "http://aims.fao.org/aos/agrovoc/c_5774",  # VERIFIED 2026-06
    label = "phenology"
  ),
  growing_degree_days = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_28c4c002",  # VERIFIED 2026-06
    label = "growing degree days"
  ),
  germany = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_3245",  # VERIFIED 2026-06
    label = "Germany"
  ),
  spatial_data = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_379bbe9f",  # VERIFIED 2026-06
    label = "spatial data"
  )
  # NOTE on "spatial interpolation": AGROVOC has no concept for "spatial
  # interpolation" or "interpolation" (verified 2026-06). The method is
  # therefore NOT anchored to a controlled-vocabulary URI; it is carried as
  # a free-text keyword only. "spatial data" (above) anchors the dataset's
  # nature at the level AGROVOC actually supports. "spatial analysis"
  # (c_40da9d3b) also exists and could be added here if desired, but is
  # broader than what the pipeline does.
)

# ---- PHASE-only artefact terms --------------------------------------------
# Terms that apply only to the PHASE (Hook B) deposits, which carry the
# interpolated COGs and the BSE per-pixel uncertainty layer. The
# filter-variant deposits have no uncertainty raster, so these are not
# attached there.
#
# IMPORTANT on the uncertainty anchor: the BSE layer is the basis-spline
# STANDARD ERROR from the BAM fit -- a model-internal (statistical)
# uncertainty, NOT an empirically validated predictive uncertainty. AGROVOC
# "statistical uncertainty" (c_28975) is the honest anchor for this: it
# denotes the quantitative-statistical uncertainty of an estimate, which is
# exactly what a fitted-surface standard error is. It deliberately does NOT
# claim validated predictive coverage (that would require a calibration
# check such as PICP). See v1.7.0 design note.
.VOCAB_TERMS_PHASE <- list(
  statistical_uncertainty = list(
    uri   = "http://aims.fao.org/aos/agrovoc/c_28975",  # VERIFIED 2026-06
    label = "statistical uncertainty"
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
#
# `temporal` lets the caller pass the actual covered range (e.g. "1993-2025")
# so the keyword matches the deposit rather than a hard-coded span. Defaults
# to the historical "1993-2024" for backward compatibility.
build_keywords <- function(crop,
                           artefact = c("filter_variant", "phase"),
                           temporal = "1993\u20132024") {
  artefact <- match.arg(artefact)

  core <- c("phenology", "crop phenology", "agrometeorology",
            "Germany", "DWD", "Deutscher Wetterdienst",
            "PhenoPhaseR", "FAIR", "FAIR data", "RO-Crate",
            "reproducible workflow", "open data",
            "1 km resolution", temporal)

  per_crop <- c(
    crop$common_name_en,
    crop$binomial,
    sprintf("DWD Plant ID %d", crop$dwd_id)
  )

  # NB: DWD phenological phase codes are crop-specific catalogue codes, NOT
  # BBCH numbers — so "BBCH" is deliberately NOT a keyword (it would be
  # inaccurate and misleading for anyone filtering on it).
  artefact_specific <- switch(artefact,
    # Filter-variant deposits are the intermediate station-filtering product
    # (CSV metrics). They carry NO uncertainty raster, so no PICP/calibration
    # or COG keywords here — that would over-claim what the deposit contains.
    filter_variant = c(
      "growing degree days", "PHASE model",
      "phenological observations", "station filtering",
      "outlier detection", "quality control", "adaptive filter",
      "data curation", "ISO 19157-1", "DQV", "data quality"
    ),
    # PHASE deposits carry the interpolated entry-date COGs and the BSE
    # uncertainty layer, now with k-fold cross-validated calibration (v1.7.0).
    phase = c(
      "growing degree days", "phenological entry dates",
      "spatial interpolation", "generalized additive model", "GAM",
      "kriging", "Cloud Optimized GeoTIFF", "COG", "EPSG:25832",
      "raster data", "spatial data",
      "uncertainty quantification", "predictive uncertainty",
      "prediction interval", "cross-validation", "calibration",
      "ISO 19157-1", "DQV", "data quality"
    )
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
                          .VOCAB_TERMS_CORE$germany$label),
    .defined_term_agrovoc(.VOCAB_TERMS_CORE$spatial_data$uri,
                          .VOCAB_TERMS_CORE$spatial_data$label)
  )

  # PHASE deposits carry the BSE uncertainty layer, so they additionally
  # anchor "statistical uncertainty". Filter-variant deposits do not.
  artefact_terms <- if (identical(artefact, "phase")) {
    list(.defined_term_agrovoc(.VOCAB_TERMS_PHASE$statistical_uncertainty$uri,
                               .VOCAB_TERMS_PHASE$statistical_uncertainty$label))
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

# ---- Build-time AGROVOC URI verification -----------------------------------
# Resolves every AGROVOC URI used in this file against the live AGROVOC
# REST API and checks that the returned English prefLabel is consistent with
# the concept we *think* we are referencing. This is the guard that would
# have caught the v1.6.0 -> v1.6.3 episode: seven of ten hand-typed URIs
# pointed at the wrong concept, and nothing in the build noticed.
#
# IMPORTANT: this function needs outbound network access to
# agrovoc.fao.org. Run it on a machine/CI runner that can reach the site
# (a typical workstation can; locked-down sandboxes cannot). It is NOT
# called automatically at source() time -- call it explicitly from the
# pipeline before a publish hook, e.g.:
#
#     source("function/_crop_specs.R")
#     verify_agrovoc_uris(stop_on_mismatch = TRUE)   # in PhenoPhaseR.R, pre-publish
#
# AGROVOC rate-limits aggressive callers (HTTP 429). The fetcher therefore:
#   - waits `delay_s` seconds between requests (default 1.5),
#   - retries a 429 with exponential backoff (2, 4, 8, 16 s),
#   - and NEVER treats a 429 as a wrong URI -- a throttled request is
#     reported as "rate-limited" (inconclusive), so a busy server can never
#     make a correct URI look broken.
# If you install the 'curl' package the fetcher can see HTTP status codes
# (so it distinguishes 429 rate-limit from 404 not-found from a real error);
# without curl it falls back to base url()/readLines(), which cannot see the
# status, and any failure is reported as the inconclusive "error" verdict
# rather than a mismatch.
#
# Matching is deliberately lenient: AGROVOC labels and our expected concept
# names will not be byte-identical ("rye" vs "winter rye", "growing degree
# days" vs "growing degree-days"), so we normalise punctuation/whitespace
# and check that one label contains the other, after stripping the season
# qualifier for concepts flagged `agrovoc_is_generic`. A mismatch is
# something like config "phenology" -> AGROVOC "local authorities", which no
# lenient rule will accept. That is exactly what we want to catch.

# Collect every (expected_label, uri, is_generic) triple used in this file.
.agrovoc_inventory <- function() {
  rows <- list()

  for (key in names(.CROP_SPECS)) {
    spec <- .CROP_SPECS[[key]]
    if (!is.null(spec$agrovoc_uri) && nzchar(spec$agrovoc_uri)) {
      rows[[length(rows) + 1]] <- list(
        context    = paste0("crop ", spec$dwd_id),
        expected   = spec$common_name_en,
        uri        = spec$agrovoc_uri,
        is_generic = isTRUE(spec$agrovoc_is_generic)
      )
    }
  }

  for (nm in names(.VOCAB_TERMS_CORE)) {
    term <- .VOCAB_TERMS_CORE[[nm]]
    if (!is.null(term$uri) && nzchar(term$uri)) {
      rows[[length(rows) + 1]] <- list(
        context    = paste0("family term '", nm, "'"),
        expected   = term$label,
        uri        = term$uri,
        is_generic = FALSE
      )
    }
  }

  for (nm in names(.VOCAB_TERMS_PHASE)) {
    term <- .VOCAB_TERMS_PHASE[[nm]]
    if (!is.null(term$uri) && nzchar(term$uri)) {
      rows[[length(rows) + 1]] <- list(
        context    = paste0("PHASE term '", nm, "'"),
        expected   = term$label,
        uri        = term$uri,
        is_generic = FALSE
      )
    }
  }
  rows
}

# Fetch the English prefLabel for one AGROVOC concept URI.
#
# Returns a list(label=<chr or NA>, status=<"ok"|"ratelimited"|"notfound"|
# "error">). Distinguishing 429 (rate-limited) from a genuine failure is the
# whole point: a throttled request must NEVER be allowed to look like a wrong
# URI. The function retries on 429 with exponential backoff.
#
# Uses the 'curl' package when available (it exposes the HTTP status code, so
# we can react to 429 specifically). Falls back to base url()/readLines(),
# which cannot see the status -- in that mode a 429 surfaces as an error and
# is reported as "error" (inconclusive), never as a mismatch.
.agrovoc_preflabel <- function(uri, timeout_s = 20,
                               max_retries = 4, backoff_base_s = 2) {
  if (!requireNamespace("jsonlite", quietly = TRUE))
    stop("verify_agrovoc_uris() needs the 'jsonlite' package.")

  endpoint <- paste0(
    "https://agrovoc.fao.org/browse/rest/v1/agrovoc/data",
    "?uri=", utils::URLencode(uri, reserved = TRUE),
    "&format=application/json&lang=en"
  )

  have_curl <- requireNamespace("curl", quietly = TRUE)

  # --- one HTTP attempt: returns list(status_code=<int or NA>, body=<chr>) ---
  do_request <- function() {
    if (have_curl) {
      h <- curl::new_handle()
      curl::handle_setopt(h, timeout = timeout_s,
                          useragent = "PhenoPhaseR-agrovoc-verify/1.0")
      r <- tryCatch(curl::curl_fetch_memory(endpoint, handle = h),
                    error = function(e) NULL)
      if (is.null(r)) return(list(status_code = NA_integer_, body = ""))
      list(status_code = r$status_code,
           body = rawToChar(r$content))
    } else {
      # Base fallback: no status visibility. A 429 throws -> we cannot tell
      # it apart from other errors, so we mark status NA and let the caller
      # treat it as inconclusive (never as a mismatch).
      body <- tryCatch({
        con <- url(endpoint, encoding = "UTF-8")
        on.exit(close(con), add = TRUE)
        paste(readLines(con, warn = FALSE), collapse = "")
      }, error = function(e) NULL)
      if (is.null(body)) return(list(status_code = NA_integer_, body = ""))
      list(status_code = 200L, body = body)
    }
  }

  # --- parse a successful body into a prefLabel ------------------------------
  parse_label <- function(txt) {
    if (!nzchar(txt)) return(NA_character_)
    data <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE),
                     error = function(e) NULL)
    if (is.null(data)) return(NA_character_)
    g <- data[["graph"]]
    if (is.null(g)) return(NA_character_)
    for (node in g) {
      nid <- node[["uri"]]; if (is.null(nid)) nid <- node[["@id"]]
      if (is.null(nid) || nid != uri) next
      pl <- node[["prefLabel"]]; if (is.null(pl)) pl <- node[["skos:prefLabel"]]
      if (is.null(pl)) return(NA_character_)
      if (is.list(pl) && !is.null(pl[["value"]])) return(pl[["value"]])
      if (is.list(pl)) {
        for (cand in pl) {
          lang <- cand[["lang"]]; val <- cand[["value"]]
          if (!is.null(val) && (is.null(lang) || lang == "en")) return(val)
        }
      }
      if (is.character(pl)) return(pl)
    }
    NA_character_
  }

  # --- retry loop with backoff on 429 ----------------------------------------
  for (attempt in seq_len(max_retries + 1L)) {
    resp <- do_request()
    sc   <- resp$status_code

    if (!is.na(sc) && sc == 429L) {
      if (attempt > max_retries)
        return(list(label = NA_character_, status = "ratelimited"))
      wait <- backoff_base_s * (2 ^ (attempt - 1L))  # 2, 4, 8, 16 s ...
      message(sprintf("    rate-limited (429); backing off %.0fs and retrying (%d/%d) ...",
                      wait, attempt, max_retries))
      Sys.sleep(wait)
      next
    }

    if (is.na(sc))                       # base-fallback error, or curl failure
      return(list(label = NA_character_, status = "error"))
    if (sc == 404L)
      return(list(label = NA_character_, status = "notfound"))
    if (sc >= 400L)
      return(list(label = NA_character_, status = "error"))

    return(list(label = parse_label(resp$body), status = "ok"))
  }

  list(label = NA_character_, status = "error")
}

# Lenient label-consistency test. TRUE = consistent, FALSE = mismatch.
.agrovoc_labels_consistent <- function(expected, actual, is_generic) {
  if (is.na(actual)) return(NA)  # could not verify (network/parse) -> caller decides
  # Normalise: lowercase, turn hyphens/underscores into spaces, collapse
  # whitespace, drop other punctuation. Handles "growing degree days" vs
  # AGROVOC "growing degree-days", etc.
  norm <- function(s) {
    s <- tolower(trimws(s))
    s <- gsub("[-_/]", " ", s)
    s <- gsub("[^a-z0-9 ]", "", s)
    s <- gsub("\\s+", " ", s)
    trimws(s)
  }
  e <- norm(expected)
  a <- norm(actual)
  # For generic anchors, drop the season qualifier from the expected label:
  # "winter rye" -> "rye", "winter rapeseed" -> "rapeseed".
  if (is_generic)
    e <- trimws(sub("^(winter|spring|summer) ", "", e))
  # Consistent if either label contains the other.
  grepl(e, a, fixed = TRUE) || grepl(a, e, fixed = TRUE)
}

#' Verify every AGROVOC URI in this file against the live AGROVOC API.
#'
#' @param stop_on_mismatch  If TRUE (default for publishing), a confirmed
#'   mismatch raises an error and halts the build. If FALSE, mismatches are
#'   reported as warnings and the function returns a data.frame for review.
#' @param stop_on_unreachable If TRUE, inability to reach AGROVOC (rate-limit,
#'   network error, or 404) is also fatal. Default FALSE: the build proceeds
#'   but prints which URIs could not be checked. Set TRUE in CI -- but note
#'   that AGROVOC rate-limits aggressive callers, so keep `delay_s` healthy.
#' @param delay_s  Seconds to wait between requests, to stay under AGROVOC's
#'   rate limit (HTTP 429). Default 1.5. A 429 is NEVER treated as a mismatch;
#'   the fetcher retries it with exponential backoff and, if it still fails,
#'   reports it as "ratelimited" (an inconclusive verdict, not a wrong URI).
#' @return (invisibly) a data.frame with one row per URI and its verdict.
verify_agrovoc_uris <- function(stop_on_mismatch = TRUE,
                                stop_on_unreachable = FALSE,
                                delay_s = 1.5) {
  inv <- .agrovoc_inventory()
  if (length(inv) == 0) {
    message("verify_agrovoc_uris(): no AGROVOC URIs configured -- nothing to check.")
    return(invisible(data.frame()))
  }

  recs <- vector("list", length(inv))
  for (i in seq_along(inv)) {
    r <- inv[[i]]
    if (i > 1L) Sys.sleep(delay_s)          # throttle: stay under the rate limit
    res    <- .agrovoc_preflabel(r$uri)      # list(label, status)
    actual <- res$label
    status <- res$status

    if (status == "ok") {
      consistent <- .agrovoc_labels_consistent(r$expected, actual, r$is_generic)
      verdict <- if (is.na(consistent)) "UNREACHABLE"  # ok status but no label parsed
                 else if (isTRUE(consistent)) "ok"
                 else "MISMATCH"
    } else if (status == "ratelimited") {
      verdict <- "RATELIMITED"
    } else if (status == "notfound") {
      verdict <- "NOTFOUND"
    } else {
      verdict <- "UNREACHABLE"
    }

    recs[[i]] <- data.frame(
      context = r$context, expected = r$expected, uri = r$uri,
      agrovoc = ifelse(is.na(actual), paste0("<", status, ">"), actual),
      generic = r$is_generic, verdict = verdict,
      stringsAsFactors = FALSE
    )
  }
  df <- do.call(rbind, recs)

  mism <- df[df$verdict == "MISMATCH", , drop = FALSE]
  rl   <- df[df$verdict == "RATELIMITED", , drop = FALSE]
  nf   <- df[df$verdict == "NOTFOUND", , drop = FALSE]
  unre <- df[df$verdict == "UNREACHABLE", , drop = FALSE]
  n_inconclusive <- nrow(rl) + nrow(nf) + nrow(unre)

  message(sprintf(
    "verify_agrovoc_uris(): %d URIs checked -- %d ok, %d mismatch, %d rate-limited, %d not-found, %d other-unreachable.",
    nrow(df), sum(df$verdict == "ok"), nrow(mism), nrow(rl), nrow(nf), nrow(unre)))

  if (nrow(mism) > 0) {
    message("  MISMATCHES (config concept vs. AGROVOC prefLabel) -- these are real errors:")
    for (i in seq_len(nrow(mism)))
      message(sprintf("    [%s] expected '%s' but %s resolves to '%s'",
                      mism$context[i], mism$expected[i], mism$uri[i], mism$agrovoc[i]))
  }
  if (nrow(rl) > 0) {
    message("  RATE-LIMITED (429 after retries -- inconclusive, NOT a wrong URI). ",
            "Re-run later or raise delay_s:")
    for (i in seq_len(nrow(rl)))
      message(sprintf("    [%s] %s (%s)", rl$context[i], rl$uri[i], rl$expected[i]))
  }
  if (nrow(nf) > 0) {
    message("  NOT FOUND (404 -- the URI does not resolve; likely a wrong/retired code):")
    for (i in seq_len(nrow(nf)))
      message(sprintf("    [%s] %s (%s)", nf$context[i], nf$uri[i], nf$expected[i]))
  }
  if (nrow(unre) > 0) {
    message("  UNREACHABLE (network/parse error -- inconclusive):")
    for (i in seq_len(nrow(unre)))
      message(sprintf("    [%s] %s (%s)", unre$context[i], unre$uri[i], unre$expected[i]))
  }

  # A 404 is a strong signal of a genuinely bad URI, so it blocks like a
  # mismatch. Rate-limit / network errors are inconclusive and only block
  # when stop_on_unreachable = TRUE.
  if (stop_on_mismatch && (nrow(mism) > 0 || nrow(nf) > 0))
    stop(sprintf("verify_agrovoc_uris(): %d mismatch + %d not-found -- refusing to build. Fix _crop_specs.R.",
                 nrow(mism), nrow(nf)), call. = FALSE)
  if (stop_on_unreachable && (nrow(rl) > 0 || nrow(unre) > 0))
    stop(sprintf("verify_agrovoc_uris(): %d inconclusive (rate-limit/network) and stop_on_unreachable=TRUE.",
                 nrow(rl) + nrow(unre)), call. = FALSE)

  invisible(df)
}
