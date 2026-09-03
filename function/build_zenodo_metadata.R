# =============================================================================
# build_zenodo_metadata.R   (Hook C helper)
#
# write_zenodo_metadata(output_dir, plant): for the two crates a pipeline run
# produced under <output_dir> (ro_crate_filtervariants/, ro_crate_phase/),
# writes a complete <kind>.zenodo.json INTO each crate folder.
#
# Source this AFTER _crop_specs.R — it reuses crop_spec / default_creators /
# build_keywords / build_subject_entities, so the Zenodo metadata (incl. the
# AGROVOC subjects) is identical to what went into the crate. Run-specific
# facts (temporal coverage, the base DOIs) are read FROM the crate, so the
# metadata always matches what was written.
#
# Metadata only — no deposit/upload. Push with tools/push_zenodo_metadata.R.
# Targets the FIRST publication (v1.0.0); versioning note at the end.
#
# Author: M. Möller, 2026.  License: MIT.
# =============================================================================

suppressMessages(library(jsonlite))

write_zenodo_metadata <- function(output_dir, plant,
                                  version        = "v1.0.0",
                                  affiliation    = "Julius K\u00fchn-Institut (JKI) \u2013 Federal Research Centre for Cultivated Plants",
                                  affiliation_ror = "022d5qt08",   # JKI ROR id; Zenodo resolves it to the linked, canonical affiliation
                                  grant_id       = "018mejw64::501899475",   # DFG ROR :: award; VERIFY via zen4R getFunders()/getAwards()
                                  software_doi   = "10.5281/zenodo.18743008",
                                  filter_concept = "10.5281/zenodo.19483111",
                                  phase_concept  = "10.5281/zenodo.19571847") {

  if (!exists("crop_spec"))
    stop("source function/_crop_specs.R before build_zenodo_metadata.R")
  `%||%` <- function(a, b)
    if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

  fam <- list(
    filter = list(folder = "ro_crate_filtervariants", json = "filtervariants.zenodo.json",
                  artefact = "filter_variant", concept = filter_concept, downstream = phase_concept),
    phase  = list(folder = "ro_crate_phase",           json = "phase.zenodo.json",
                  artefact = "phase",          concept = phase_concept,  downstream = NA)
  )

  # -- run-specific facts read FROM the crate (single source) -----------------
  crate_facts <- function(crate_dir) {
    f <- file.path(crate_dir, "ro-crate-metadata.json")
    if (!file.exists(f)) stop("no ro-crate-metadata.json in ", crate_dir)
    g <- jsonlite::read_json(f, simplifyVector = FALSE)[["@graph"]]
    root <- Filter(function(e) identical(e[["@id"]], "./"), g)[[1]]
    tc <- root[["temporalCoverage"]] %||% root[["dct:temporal"]] %||% "1993/2025"
    ib <- root[["isBasedOn"]] %||% list()
    base <- unique(unlist(lapply(ib, function(x)
      sub("https?://doi\\.org/", "", x[["@id"]] %||% ""))))
    list(temporal = gsub("/", "\u2013", tc), base_dois = base)
  }

  # -- crop-aware description (the crate's own name/description is terse) ------
  compose_description <- function(crop, artefact, temporal) {
    prov <- sprintf(paste0(
      "<p><strong>Provenance:</strong> generated with PhenoPhaseR (software concept DOI %s). ",
      "AGROVOC subject anchoring (crop species + family concepts, with Wikidata cross-links) ",
      "is carried identically in the accompanying RO-Crate's <code>schema:about</code>.</p>"),
      software_doi)
    if (identical(artefact, "phase")) {
      paste0(
        sprintf("<p>Interpolated phenological phase entry dates (day-of-year) with a per-pixel uncertainty layer, from the PhenoPhaseR pipeline for %s (<em>%s</em> L., DWD Plant ID %d), for Germany over %s at 1&nbsp;km resolution (EPSG:25832).</p>",
                crop$common_name_en, crop$binomial, crop$dwd_id, temporal),
        "<p>Per phase: a multi-band Cloud-Optimised GeoTIFF DOY (one band per year) and BSE (per-pixel basis-spline standard error), plus CAL/GEM/VAM/PIC quality CSVs. The BSE layer is a model-internal statistical uncertainty (AGROVOC 'statistical uncertainty', c_28975); calibration is reported as PICP/MPIW at nominal 90% via 5-fold cross-validation. Pipeline Step 7.</p>",
        prov)
    } else {
      paste0(
        sprintf("<p>Filter-variant optimization outputs of the PhenoPhaseR pipeline for %s (<em>%s</em> L., DWD Plant ID %d), for Germany over %s. The intermediate station-filtering product: per-phase OPT_* optimisation metrics and the selected filtered station observations (SHP_*). No interpolated raster and no uncertainty layer. Pipeline Steps 5-6.</p>",
                crop$common_name_en, crop$binomial, crop$dwd_id, temporal),
        prov)
    }
  }

  build_one <- function(kind) {
    k <- fam[[kind]]
    crate_dir <- file.path(output_dir, k$folder)
    if (!dir.exists(crate_dir)) { message("  skip (no crate): ", crate_dir); return(invisible(NULL)) }
    ff   <- crate_facts(crate_dir)
    crop <- crop_spec(plant)
    art  <- k$artefact

    title <- if (kind == "phase")
      sprintf("PHASE: Interpolated phenological phase entry dates for %s (%s, DWD Plant ID %d) in Germany",
              crop$common_name_en, crop$binomial, crop$dwd_id)
    else
      sprintf("Filter Variants: Optimization metrics and filtered station observations for %s (%s, DWD Plant ID %d) in Germany",
              crop$common_name_en, crop$binomial, crop$dwd_id)

    # creators / keywords / AGROVOC subjects — from the SAME functions as the crate
    creators <- lapply(default_creators(art), function(cr) {
      parts <- strsplit(trimws(cr$name), "\\s+")[[1]]
      list(name            = sprintf("%s, %s", tail(parts, 1), paste(head(parts, -1), collapse = " ")),
           orcid           = sub("https?://orcid\\.org/", "", cr[["@id"]] %||% ""),
           affiliation     = affiliation,        # human-readable (documentation)
           affiliation_ror = affiliation_ror)    # ROR id -> Zenodo resolves to the canonical, linked name
    })
    keywords <- as.list(build_keywords(crop, art, temporal = ff$temporal))
    subj <- build_subject_entities(crop, art)
    subjects <- lapply(subj$defined_terms, function(t) {
      ex <- t[["skos:exactMatch"]]
      list(label = t[["name"]], uri = t[["@id"]], scheme = "AGROVOC",
           wikidata = if (is.list(ex)) (ex[["@id"]] %||% NULL) else (ex %||% NULL))
    })

    # related identifiers: base DOIs from the crate + the Zenodo relation graph
    rel <- lapply(ff$base_dois, function(d)
      list(relation = if (identical(d, software_doi)) "isCompiledBy" else "isDerivedFrom",
           identifier = d, resource_type = if (identical(d, software_doi)) "software" else "dataset"))
    rel <- c(rel, list(list(relation = "isPartOf", identifier = k$concept, resource_type = "dataset")))
    if (!is.na(k$downstream))
      rel <- c(rel, list(list(relation = "isSourceOf", identifier = k$downstream, resource_type = "dataset")))

    meta <- list(
      title = title, version = version, upload_type = "dataset", language = "eng",
      license = "cc-by-4.0", description = compose_description(crop, art, ff$temporal),
      creators = creators, keywords = keywords, subjects = subjects,   # <- AGROVOC in the Zenodo metadata
      related_identifiers = rel,
      grants = if (!is.null(grant_id) && nzchar(grant_id)) list(list(id = grant_id)) else NULL,
      communities = list(list(identifier = "jki"))
    )
    out <- file.path(crate_dir, k$json)
    jsonlite::write_json(meta, out, auto_unbox = TRUE, pretty = TRUE, null = "null")
    message(sprintf("  %-14s -> %s  (%d AGROVOC subjects, %d related ids)",
                    kind, out, length(subjects), length(rel)))
    invisible(out)
  }

  message("Hook C \u2014 Zenodo deposition metadata for plant ", plant, ":")
  for (kind in names(fam)) build_one(kind)
  invisible(TRUE)
}

# ---- Versioning note --------------------------------------------------------
# write_zenodo_metadata() + tools/push_zenodo_metadata.R target the FIRST
# publication (new record, concept DOI, version v1.0.0). For a later version of
# an EXISTING dataset the metadata above is unchanged; only the deposit call
# differs:
#   rec <- zenodo$getDepositionByConceptDOI("<crop's concept DOI>")
#   rec <- zenodo$depositRecordVersion(rec)   # concept DOI stays stable
#   ... update changed files / metadata ... then publish.
