# ============================================================================
# build_filtervariant_ro_crate.R
#
# PhenoPhaseR Hook A: Package the filter variant results (Steps 5–6 outputs)
# into an RO-Crate 1.2 deposit ready for Zenodo upload (target concept DOI
# 10.5281/zenodo.19483111).
#
# Mirrors the build_ro_crate() pattern of WeatherIndicatoR
# (Möller 2026, https://doi.org/10.5281/zenodo.19631197).
#
# Artifact set (produced by the patched filter_variant_selector.R with
# subfolders = TRUE):
#   <results>/shapefiles/DOY_<plant>-<phase>_<year>.{shp,shx,dbf,prj,cpg}
#   <results>/opt_scores/OPT_ALL_<plant>-<phase>.csv
#   <results>/opt_scores/OPT_MAX_<plant>-<phase>.csv
#   <results>/opt_scores/OPT_ALL_<plant>_ALL_PHASES.csv      (master table)
#   <results>/opt_scores/OPT_MAX_<plant>_ALL_PHASES.csv      (master table)
#   <results>/opt_scores/OPT_<plant>_EXPONENTS_ALL_PHASES.csv
#   <results>/opt_scores/diagnostics/OPT_<plant>-<phase>_DIAGNOSTICS.pdf
#
# Quality table column expectations (from OPT_MAX_<plant>_ALL_PHASES.csv):
#   PLANT, PHASE, YEAR, STD, SN, COR, MAE, OPT, OPT_normalized,
#   sn_exponent, N_RATIO
# These columns are mapped to ISO 19157-1 thematic-accuracy quality elements:
#   n_ratio              ← N_RATIO       (SN / SN_max per phase)
#   OPT_score            ← OPT           (SN^x * COR)
#   adaptive_exponent_x  ← sn_exponent
#   correlation          ← COR
#   residual_sd_cutoff   ← STD
#   sample_number        ← SN
#   mae_days             ← MAE
#
# Author : adapted for PhenoPhaseR by M. Möller, 2026
# License: MIT (this script); CC-BY-4.0 (the output crate contents)
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(tools)
})


# ---- Shared helpers (factor into R/_utils_rocrate.R when integrating) -----
.mime_table <- c(
  shp = "application/vnd.shp", shx = "application/vnd.shx",
  dbf = "application/dbase", prj = "text/plain", cpg = "text/plain",
  csv = "text/csv", pdf = "application/pdf",
  tif = "image/tiff;application=geotiff;profile=cloud-optimized",
  json = "application/json", txt = "text/plain"
)
.mime_for <- function(ext) {
  m <- .mime_table[tolower(ext)]
  ifelse(is.na(m), "application/octet-stream", unname(m))
}
.relpath <- function(path, root) {
  sub(paste0("^", normalizePath(root, mustWork = FALSE), "/?"),
      "", normalizePath(path, mustWork = FALSE))
}
.file_entity <- function(path, crate_root, description = NULL) {
  stopifnot(file.exists(path))
  out <- list(
    "@id"            = .relpath(path, crate_root),
    "@type"          = "File",
    "name"           = basename(path),
    "contentSize"    = unname(file.info(path)$size),
    "encodingFormat" = .mime_for(file_ext(path)),
    "dateModified"   = format(file.info(path)$mtime,
                              "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "spdx:checksum"  = paste0("MD5: ", unname(md5sum(path)))
  )
  if (!is.null(description)) out[["description"]] <- description
  out
}
# Map each measure to its ISO 19157-1 quality dimension. Used as the SKOS
# bridge so DQV-aware consumers (FAIRagro, BonaRes, GeoNetwork, CKAN) can
# group measurements by W3C-standard dimensions instead of parsing custom
# property IDs.
.iso19157_dimension <- function(measure) {
  switch(measure,
    n_ratio              = "DQ_CompletenessOmission",
    sample_number        = "DQ_CompletenessOmission",
    OPT_score            = "DQ_ThematicAccuracy",
    adaptive_exponent_x  = "DQ_ThematicAccuracy",
    correlation          = "DQ_ThematicAccuracy",
    residual_sd_cutoff   = "DQ_ThematicAccuracy",
    mae_days             = "DQ_ThematicAccuracy",
    cv_rmse              = "DQ_ThematicAccuracy",
    cv_mae               = "DQ_ThematicAccuracy",
    cv_r2                = "DQ_ThematicAccuracy",
    cv_bias              = "DQ_ThematicAccuracy",
    training_n           = "DQ_CompletenessOmission",
    validation_n         = "DQ_CompletenessOmission",
    bam_k                = "DQ_LogicalConsistency",
    mean_bse             = "DQ_ThematicAccuracy",
    "DQ_ThematicAccuracy"
  )
}

.quality_element <- function(measure, value, unit_text = NULL,
                             definition = NULL) {
  # Dual typing: schema:PropertyValue keeps Schema.org consumers happy;
  # dqv:QualityMeasurement makes the node first-class for W3C DQV pipelines.
  el <- list(
    "@type"             = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = paste0("iso19157:", measure),
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list(
      "@type"           = "dqv:Metric",
      "skos:prefLabel"  = measure,
      "skos:closeMatch" = list("@id" = paste0("iso19157:", measure)),
      "dqv:inDimension" = list("@id" = paste0("iso19157:",
                                              .iso19157_dimension(measure)))
    )
  )
  if (!is.null(unit_text))  el[["schema:unitText"]]    <- unit_text
  if (!is.null(definition)) el[["schema:description"]] <- definition
  el
}


# ---- Discover artifacts under the patched subfolder layout ----------------
.discover_artifacts <- function(results_dir, plant, phases, years) {

  shp_dir <- file.path(results_dir, "shapefiles")
  csv_dir <- file.path(results_dir, "opt_scores")
  pdf_dir <- file.path(results_dir, "opt_scores", "diagnostics")

  phase_alt <- paste(phases, collapse = "|")
  year_alt  <- paste(years,  collapse = "|")

  shp_pat <- sprintf("^DOY_%d-(%s)_(%s)\\.(shp|shx|dbf|prj|cpg)$",
                     plant, phase_alt, year_alt)
  list(
    shapefiles = list.files(shp_dir, pattern = shp_pat, full.names = TRUE),
    opt_per_phase = list.files(csv_dir,
      pattern = sprintf("^OPT_(ALL|MAX)_%d-(%s)\\.csv$", plant, phase_alt),
      full.names = TRUE),
    opt_master = list.files(csv_dir,
      pattern = sprintf("^OPT_(ALL|MAX)_%d_ALL_PHASES\\.csv$", plant),
      full.names = TRUE),
    exponents = list.files(csv_dir,
      pattern = sprintf("^OPT_%d_EXPONENTS_ALL_PHASES\\.csv$", plant),
      full.names = TRUE),
    diagnostics = list.files(pdf_dir,
      pattern = sprintf("^OPT_%d-(%s)_DIAGNOSTICS\\.pdf$", plant, phase_alt),
      full.names = TRUE)
  )
}


# ---- Per-(phase, year) shapefile Dataset block ----------------------------
.shapefile_dataset <- function(shp_files_for_yp, crate_root,
                               plant, phase, year, q_row) {
  if (!length(shp_files_for_yp)) return(NULL)

  basename <- sprintf("DOY_%d-%d_%d", plant, phase, year)

  qe <- list(
    .quality_element("n_ratio", q_row$N_RATIO, "ratio",
                     "Sample retention SN/SN_max after residual SD filtering"),
    .quality_element("OPT_score", q_row$OPT, NULL,
                     "Objective function OPT = SN^x(year) * COR"),
    .quality_element("adaptive_exponent_x", q_row$sn_exponent, NULL,
                     "Year-specific exponent on sample number ratio"),
    .quality_element("correlation", q_row$COR, "r",
                     "Pearson correlation observed DOY vs GDD-predicted DOY"),
    .quality_element("residual_sd_cutoff", q_row$STD, "sigma",
                     "Standard-deviation multiplier of the residual filter"),
    .quality_element("sample_number", q_row$SN, "count",
                     "Number of station observations retained after filtering"),
    .quality_element("mae_days", q_row$MAE, "days",
                     "Mean absolute error from per-station GDD calibration")
  )

  list(
    "@id"   = sprintf("shapefiles/%s/", basename),
    # Dual typing: Dataset (Schema.org/RO-Crate) + dcat:Dataset (W3C DCAT 3)
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf("Optimised phenological observations (plant %d, phase %d, %d)",
                      plant, phase, year),
    "description" = paste0(
      "Filtered phenological entry-date observations for plant ", plant,
      ", phase ", phase, ", year ", year, ". Selected variant of the ",
      "residual-SD outlier filter, scored by OPT = SN^x * COR. Direct ",
      "input to spatial_interpolation.R (Step 7)."),
    "encodingFormat" = "application/vnd.shapefile",
    "hasPart"        = lapply(shp_files_for_yp,
                              function(p) list("@id" = .relpath(p, crate_root))),
    # Quality info: Schema.org variableMeasured + W3C DQV hasQualityMeasurement
    # both reference the same node array (dual-typed in .quality_element).
    "schema:variableMeasured"    = qe,
    "dqv:hasQualityMeasurement"  = qe,
    "schema:temporalCoverage" = as.character(year),
    "dct:temporal"            = as.character(year),
    "schema:spatialCoverage"  = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"             = list("@id" = "https://www.geonames.org/2921044/")
  )
}


# ============================================================================
# Main entry point
# ============================================================================
build_filtervariant_ro_crate <- function(
  out_dir,
  plant,
  phase,                                       # vector of phase IDs
  years,
  results_dir,
  quality_table,                               # OPT_MAX_<plant>_ALL_PHASES.csv contents
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  downstream_doi = "10.5281/zenodo.19571847",
  agent_orcid    = "https://orcid.org/0000-0002-1918-7747",
  agent_name     = "Markus Möller",
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = TRUE
) {

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # --- 1. Stage artifacts into the crate ----------------------------------
  src <- .discover_artifacts(results_dir, plant, phase, years)
  for (sub in c("shapefiles",
                "opt_scores",
                "opt_scores/diagnostics"))
    dir.create(file.path(out_dir, sub), showWarnings = FALSE, recursive = TRUE)

  if (length(src$shapefiles))    file.copy(src$shapefiles,    file.path(out_dir, "shapefiles"),               overwrite = TRUE)
  if (length(src$opt_per_phase)) file.copy(src$opt_per_phase, file.path(out_dir, "opt_scores"),               overwrite = TRUE)
  if (length(src$opt_master))    file.copy(src$opt_master,    file.path(out_dir, "opt_scores"),               overwrite = TRUE)
  if (length(src$exponents))     file.copy(src$exponents,     file.path(out_dir, "opt_scores"),               overwrite = TRUE)
  if (length(src$diagnostics))   file.copy(src$diagnostics,   file.path(out_dir, "opt_scores/diagnostics"),   overwrite = TRUE)

  art <- .discover_artifacts(out_dir, plant, phase, years)

  # --- 2. Per-(phase, year) shapefile datasets ----------------------------
  shp_datasets <- list()
  for (ph in phase) for (yr in years) {
    pat <- sprintf("^DOY_%d-%d_%d\\.", plant, ph, yr)
    parts <- art$shapefiles[grepl(pat, basename(art$shapefiles))]
    if (!length(parts)) next
    qrow <- quality_table[quality_table$PLANT == plant &
                          quality_table$PHASE == ph    &
                          quality_table$YEAR  == yr, ]
    if (!nrow(qrow))
      qrow <- data.frame(N_RATIO = NA, OPT = NA, sn_exponent = NA,
                         COR = NA, STD = NA, SN = NA, MAE = NA)
    ds <- .shapefile_dataset(parts, out_dir, plant, ph, yr, qrow[1, ])
    if (!is.null(ds)) shp_datasets[[length(shp_datasets) + 1]] <- ds
  }

  # --- 3. Per-component File entities -------------------------------------
  file_entities <- c(
    lapply(art$shapefiles,    .file_entity, crate_root = out_dir),
    lapply(art$opt_per_phase, .file_entity, crate_root = out_dir,
           description = "Per-phase OPT scoring table from filter_variant_selector"),
    lapply(art$opt_master,    .file_entity, crate_root = out_dir,
           description = "Combined OPT scoring table across all phases"),
    lapply(art$exponents,     .file_entity, crate_root = out_dir,
           description = "Year-specific adaptive exponents per phase"),
    lapply(art$diagnostics,   .file_entity, crate_root = out_dir,
           description = "Diagnostic plots for filter variant optimisation")
  )

  # --- 4. PROV-O CreateAction (Steps 1–6) ---------------------------------
  all_outputs <- unname(unlist(c(art$shapefiles, art$opt_per_phase,
                                  art$opt_master, art$exponents, art$diagnostics)))
  create_action <- list(
    "@id"        = "#filtervariant-creation",
    # Dual typing: schema:CreateAction + W3C prov:Activity
    "@type"      = c("CreateAction", "prov:Activity"),
    "name"       = "PhenoPhaseR Steps 1–6: phenology download through filter variant selection",
    "agent"      = list("@id" = agent_orcid),
    "prov:wasAssociatedWith" = list("@id" = agent_orcid),
    "instrument" = list("@id" = paste0("https://doi.org/", software_doi)),
    "object"     = list(list("@id" = paste0("https://doi.org/", input_data_doi))),
    "prov:used"  = list(list("@id" = paste0("https://doi.org/", input_data_doi))),
    "result"     = lapply(all_outputs,
                          function(p) list("@id" = .relpath(p, out_dir))),
    "startTime"        = format(start_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "prov:startedAtTime" = format(start_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "endTime"          = format(end_time,   "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    "prov:endedAtTime" = format(end_time,   "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )

  # --- 5. Root dataset descriptor -----------------------------------------
  csv_root_files <- c(art$opt_per_phase, art$opt_master, art$exponents,
                      art$diagnostics)
  root_dataset <- list(
    "@id"   = "./",
    # Dual typing: Dataset (Schema.org/RO-Crate) + dcat:Dataset (W3C DCAT 3)
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf(
      "PhenoPhaseR filter variant results — plant %d, phases %s, %d–%d",
      plant, paste(phase, collapse = ","), min(years), max(years)),
    "description" = paste(
      "Intermediate output of the PhenoPhaseR pipeline (Steps 1–6):",
      "filtered and optimised phenological entry-date observations from the",
      "DWD annual-reporter network. Per-year filter variant selected by",
      "OPT = SN^x(year) * COR with a residual standard-deviation outlier",
      "cutoff. These shapefiles are the direct input to spatial_interpolation",
      "(Step 7), which produces the PHASE entry-date COGs."),
    "datePublished" = format(Sys.Date()),
    "dct:issued"    = format(Sys.Date()),
    "license"       = list("@id" = "https://creativecommons.org/licenses/by/4.0/"),
    "dct:license"   = list("@id" = "https://creativecommons.org/licenses/by/4.0/"),
    "creator"       = list(list("@id" = agent_orcid)),
    "dct:creator"   = list(list("@id" = agent_orcid)),
    "publisher"     = list("@id" = "https://ror.org/02jx3x895"),
    "dct:publisher" = list("@id" = "https://ror.org/02jx3x895"),
    "keywords"      = c("phenology", "filter variant", "DWD", "winter wheat",
                        "Germany", "FAIR", "RO-Crate", "ISO 19157-1", "DQV"),
    "dcat:keyword"  = c("phenology", "filter variant", "DWD", "winter wheat",
                        "Germany", "FAIR", "RO-Crate", "ISO 19157-1", "DQV"),
    "spatialCoverage"  = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"      = list("@id" = "https://www.geonames.org/2921044/"),
    "temporalCoverage" = sprintf("%d/%d", min(years), max(years)),
    "dct:temporal"     = sprintf("%d/%d", min(years), max(years)),
    "isBasedOn" = list(
      list("@id" = paste0("https://doi.org/", software_doi)),
      list("@id" = paste0("https://doi.org/", input_data_doi))
    ),
    "prov:wasDerivedFrom" = list(
      list("@id" = paste0("https://doi.org/", software_doi)),
      list("@id" = paste0("https://doi.org/", input_data_doi))
    ),
    "hasPart" = c(
      lapply(shp_datasets, function(d) list("@id" = d[["@id"]])),
      lapply(csv_root_files,
             function(p) list("@id" = .relpath(p, out_dir)))
    ),
    "wasGeneratedBy"      = list("@id" = "#filtervariant-creation"),
    "prov:wasGeneratedBy" = list("@id" = "#filtervariant-creation")
  )

  # --- 6. Contextual entities --------------------------------------------
  context_entities <- list(
    list("@id" = agent_orcid, "@type" = "Person", "name" = agent_name,
         "affiliation" = list("@id" = "https://ror.org/02jx3x895")),
    list("@id" = "https://ror.org/02jx3x895",
         "@type" = "Organization", "name" = "Julius Kühn-Institut (JKI)"),
    list("@id" = "https://creativecommons.org/licenses/by/4.0/",
         "@type" = "CreativeWork",
         "name"  = "Creative Commons Attribution 4.0 International"),
    list("@id" = paste0("https://doi.org/", software_doi),
         "@type" = "SoftwareApplication", "name" = "PhenoPhaseR"),
    list("@id" = paste0("https://doi.org/", input_data_doi),
         "@type" = "Dataset",
         "name"  = "DWD phenology and gridded temperature input data"),
    list("@id" = paste0("https://doi.org/", downstream_doi),
         "@type" = "Dataset",
         "name"  = "PHASE Crop Phenological Development Dataset (final COGs)"),
    list("@id" = "https://www.geonames.org/2921044/",
         "@type" = "Place", "name" = "Federal Republic of Germany")
  )

  # --- 7. Metadata descriptor --------------------------------------------
  metadata_descriptor <- list(
    "@id"        = "ro-crate-metadata.json",
    "@type"      = "CreativeWork",
    "conformsTo" = list(
      list("@id" = "https://w3id.org/ro/crate/1.2"),
      list("@id" = "https://w3id.org/ro/crate/1.2/Workflow-Run-Crate")
    ),
    "about"      = list("@id" = "./"),
    "description" = paste(
      "RO-Crate 1.2 (Workflow Run Crate profile) describing the filter",
      "variant results of the PhenoPhaseR pipeline.")
  )

  # --- 8. Assemble JSON-LD graph -----------------------------------------
  crate <- list(
    "@context" = list(
      "https://w3id.org/ro/crate/1.2/context",
      list(
        # W3C vocabularies (primary for quality propagation)
        "dcat"     = "http://www.w3.org/ns/dcat#",
        "dct"      = "http://purl.org/dc/terms/",
        "dqv"      = "http://www.w3.org/ns/dqv#",
        "prov"     = "http://www.w3.org/ns/prov#",
        "skos"     = "http://www.w3.org/2004/02/skos/core#",
        "xsd"      = "http://www.w3.org/2001/XMLSchema#",
        # ISO bridge target (referenced via skos:closeMatch from DQV)
        "iso19157" = "http://standards.iso.org/iso/19157/-1/",
        # Carrier vocabularies (kept for entities without W3C equivalents)
        "schema"   = "http://schema.org/",
        "spdx"     = "http://spdx.org/rdf/terms#"
      )
    ),
    "@graph" = c(
      list(metadata_descriptor),
      list(root_dataset),
      shp_datasets,
      file_entities,
      list(create_action),
      context_entities
    )
  )

  # --- 9. Write -----------------------------------------------------------
  out_json <- file.path(out_dir, "ro-crate-metadata.json")
  write_json(crate, out_json,
             pretty = TRUE, auto_unbox = TRUE,
             null = "null", na = "null")
  message("Wrote crate metadata: ", out_json)

  if (zip_output) {
    zip_path <- paste0(out_dir, ".zip")
    old <- setwd(dirname(out_dir)); on.exit(setwd(old), add = TRUE)
    utils::zip(zip_path, basename(out_dir), flags = "-r9X")
    message("Wrote crate ZIP    : ", zip_path)
  }

  invisible(out_json)
}


# ============================================================================
# Wiring example for PhenoPhaseR.R (after Step 6)
# ============================================================================
#   t1_fv <- Sys.time()
#
#   ## OPT_MAX master table written by filter_variant_selector
#   qtab_fv <- read.csv2(file.path(output_dir, "opt_scores",
#                                  paste0("OPT_MAX_", plant,
#                                         "_ALL_PHASES.csv")),
#                        stringsAsFactors = FALSE)
#
#   source(file.path(function_dir, "build_filtervariant_ro_crate.R"))
#   build_filtervariant_ro_crate(
#     out_dir       = file.path(output_dir, "ro_crate_filtervariants"),
#     plant         = plant,
#     phase         = target_phases,
#     years         = years,
#     results_dir   = output_dir,
#     quality_table = qtab_fv,
#     start_time    = t0_fv,
#     end_time      = t1_fv
#   )
# ============================================================================
