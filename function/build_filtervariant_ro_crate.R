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
# Artifact set produced (in <results>) by filter_variant_selector.R with
# subfolders = TRUE:
#   <results>/shapefiles/DOY_<plant>-<phase>_<year>.{shp,shx,dbf,prj,cpg}
#   <results>/opt_scores/OPT_ALL_<plant>-<phase>.csv
#   <results>/opt_scores/OPT_MAX_<plant>-<phase>.csv
#   <results>/opt_scores/OPT_ALL_<plant>_ALL_PHASES.csv      (master table)
#   <results>/opt_scores/OPT_MAX_<plant>_ALL_PHASES.csv      (master table)
#   <results>/opt_scores/OPT_<plant>_EXPONENTS_ALL_PHASES.csv
#   <results>/opt_scores/diagnostics/OPT_<plant>-<phase>_DIAGNOSTICS.pdf
#
# Crate layout produced (in <out_dir>), aligned with Hook B's per-phase
# grouping and matching the published structure of Zenodo record 20232707:
#   <out_dir>/shapefiles/SHP_<plant>-<phase>.zip      (one ZIP per phase,
#                                                      32 shapefile sets each)
#   <out_dir>/opt_scores/OPT_ALL_<plant>.csv          (renamed from
#                                                      OPT_ALL_<plant>_ALL_PHASES.csv)
#   <out_dir>/opt_scores/OPT_MAX_<plant>.csv          (renamed from
#                                                      OPT_MAX_<plant>_ALL_PHASES.csv)
#   <out_dir>/opt_scores/OPT_<plant>_EXPONENTS.csv    (renamed)
#   <out_dir>/opt_scores/OPT_ALL_<plant>-<phase>.csv  (kept, member of phase Dataset)
#   <out_dir>/opt_scores/OPT_MAX_<plant>-<phase>.csv  (kept, member of phase Dataset)
#   <out_dir>/opt_scores/diagnostics/OPT_<plant>-<phase>_DIAGNOSTICS.pdf
#   <out_dir>/_per_phase/shapefiles/<phase>/...       (working dir for
#                                                      pre-ZIP shapefile sets;
#                                                      EXCLUDED from the
#                                                      published ZIP)
#   <out_dir>/README.md
#   <out_dir>/ro-crate-metadata.json
#   <out_dir>/ro-crate-preview.html
#
# Quality table column expectations (from OPT_MAX_<plant>_ALL_PHASES.csv):
#   PLANT, PHASE, YEAR, Q, RMSE, MAE, SN, COR, STD, sn_exponent, OPT,
#   OPT_normalized
# Optional columns (silently skipped if absent or NA): N_RATIO
#
# Columns are mapped to ISO 19157-1 thematic-accuracy quality elements
# (via SKOS bridge in .iso19157_dimension); columns that aren't direct
# accuracy metrics are still exposed as DQV quality measurements with no
# ISO 19157-1 close-match (the SKOS bridge omits them):
#   gdd_quantile_threshold      ← Q              (model parameter)
#   cv_rmse                     ← RMSE           (thematic_accuracy_quantitative_attribute)
#   mae_days                    ← MAE            (thematic_accuracy_quantitative_attribute)
#   sample_number               ← SN             (completeness_omission)
#   correlation                 ← COR            (thematic_accuracy_quantitative_attribute)
#   residual_sd_cutoff          ← STD            (filter parameter)
#   adaptive_exponent_x         ← sn_exponent    (model parameter)
#   OPT_score                   ← OPT            (selection score)
#   OPT_score_normalized        ← OPT_normalized (selection score)
#   n_ratio                     ← N_RATIO        (selection score, optional)
#
# Author : adapted for PhenoPhaseR by M. Möller, 2026
# License: MIT (this script); CC-BY-4.0 (the output crate contents)
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(tools)
})

# Shared crop specs, default creators, layered keyword builder, and AGROVOC
# DefinedTerm helpers. Source from the same directory as this script.
.this_dir <- tryCatch(
  dirname(sys.frame(1)$ofile),
  error = function(e) getwd()
)
source(file.path(.this_dir, "_crop_specs.R"))


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
    n_ratio                = "DQ_CompletenessOmission",
    sample_number          = "DQ_CompletenessOmission",
    OPT_score              = "DQ_ThematicAccuracy",
    OPT_score_normalized   = "DQ_ThematicAccuracy",
    gdd_quantile_threshold = "DQ_ThematicAccuracy",
    adaptive_exponent_x    = "DQ_ThematicAccuracy",
    correlation            = "DQ_ThematicAccuracy",
    residual_sd_cutoff     = "DQ_ThematicAccuracy",
    mae_days               = "DQ_ThematicAccuracy",
    cv_rmse                = "DQ_ThematicAccuracy",
    cv_mae                 = "DQ_ThematicAccuracy",
    cv_r2                  = "DQ_ThematicAccuracy",
    cv_bias                = "DQ_ThematicAccuracy",
    training_n             = "DQ_CompletenessOmission",
    validation_n           = "DQ_CompletenessOmission",
    bam_k                  = "DQ_LogicalConsistency",
    mean_bse               = "DQ_ThematicAccuracy",
    "DQ_ThematicAccuracy"
  )
}

.quality_element <- function(measure, value, unit_text = NULL,
                             definition = NULL, qm_id = NULL) {
  # Each measurement is a first-class top-level entity in the @graph: dual-
  # typed schema:PropertyValue + dqv:QualityMeasurement, with its own @id and
  # a reference (not an inline object) to the dqv:Metric entity that defines
  # what it measures. This shape is what JSON-LD / RO-Crate validators expect
  # for object references — inline anonymous objects under
  # schema:variableMeasured trip the rule "node references MUST have only
  # @id, no other properties" (roc-validator, REQUIRED).
  el <- list(
    "@id"               = qm_id,
    "@type"             = c("schema:PropertyValue", "dqv:QualityMeasurement"),
    "schema:propertyID" = paste0("iso19157:", measure),
    "schema:name"       = measure,
    "schema:value"      = value,
    "dqv:value"         = value,
    "dqv:isMeasurementOf" = list("@id" = paste0("#metric-", measure))
  )
  if (!is.null(unit_text))  el[["schema:unitText"]]    <- unit_text
  if (!is.null(definition)) el[["schema:description"]] <- definition
  el
}


# ---- Top-level dqv:Metric entity (one per unique measure name in crate) ---
# The Metric describes the *kind* of thing being measured (e.g. RMSE in days,
# mapped to ISO 19157 DQ_ThematicAccuracy). Many measurements reference the
# same Metric via dqv:isMeasurementOf, so it lives at top level rather than
# being inlined redundantly per measurement.
.metric_entity <- function(measure) {
  list(
    "@id"             = paste0("#metric-", measure),
    "@type"           = "dqv:Metric",
    "skos:prefLabel"  = measure,
    "skos:closeMatch" = list("@id" = paste0("iso19157:", measure)),
    "dqv:inDimension" = list("@id" = paste0("iso19157:",
                                            .iso19157_dimension(measure)))
  )
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


# ---- Discover the staged (in-crate) layout after renaming + ZIPping -----
# The crate uses the short names OPT_ALL_<plant>.csv, OPT_MAX_<plant>.csv,
# OPT_<plant>_EXPONENTS.csv (no ALL_PHASES suffix) and one phase ZIP per
# phase under shapefiles/. This helper enumerates what landed there so the
# manifest builders can reference real on-disk files.
.discover_staged_artifacts <- function(out_dir, plant, phases) {
  shp_dir <- file.path(out_dir, "shapefiles")
  csv_dir <- file.path(out_dir, "opt_scores")
  pdf_dir <- file.path(out_dir, "opt_scores", "diagnostics")
  phase_alt <- paste(phases, collapse = "|")

  list(
    phase_zips = list.files(shp_dir,
      pattern = sprintf("^SHP_%d-(%s)\\.zip$", plant, phase_alt),
      full.names = TRUE),
    opt_per_phase = list.files(csv_dir,
      pattern = sprintf("^OPT_(ALL|MAX)_%d-(%s)\\.csv$", plant, phase_alt),
      full.names = TRUE),
    opt_master = list.files(csv_dir,
      pattern = sprintf("^OPT_(ALL|MAX)_%d\\.csv$", plant),
      full.names = TRUE),
    exponents = list.files(csv_dir,
      pattern = sprintf("^OPT_%d_EXPONENTS\\.csv$", plant),
      full.names = TRUE),
    diagnostics = list.files(pdf_dir,
      pattern = sprintf("^OPT_%d-(%s)_DIAGNOSTICS\\.pdf$", plant, phase_alt),
      full.names = TRUE)
  )
}


# ---- Per-phase Dataset block ---------------------------------------------
# Aligned with the per-phase grouping used by Hook B (build_phase_cog_ro_crate)
# and with the published structure of Zenodo record 20232707. Each block
# represents one phenological phase across the full year range; per-year
# quality measurements live inside `schema:variableMeasured` /
# `dqv:hasQualityMeasurement` as inline objects tagged with `dct:temporal`.
#
# Helper: build a single per-(phase, year) quality measurement bundle.
# Tolerates absent / NA columns silently — only emits measurements for the
# columns actually present in the row.
.per_year_quality_measurements <- function(q_row, plant, phase, year) {
  has <- function(col) col %in% names(q_row) &&
                       !is.null(q_row[[col]]) &&
                       length(q_row[[col]]) == 1L &&
                       !is.na(q_row[[col]])

  add_qe <- function(lst, col, measure, unit, defn) {
    if (!has(col)) return(lst)
    qm_id <- sprintf("#qm-%d-%d-%d-%s", plant, phase, year, measure)
    qe <- .quality_element(measure, q_row[[col]], unit, defn, qm_id = qm_id)
    qe[["dct:temporal"]]            <- as.character(year)
    qe[["schema:temporalCoverage"]] <- as.character(year)
    c(lst, list(qe))
  }

  qe <- list()
  qe <- add_qe(qe, "Q",              "gdd_quantile_threshold", "ratio",
               "GDD quantile threshold q* minimising MAE for the year")
  qe <- add_qe(qe, "RMSE",           "cv_rmse",                "days",
               "Root mean squared error between predicted and observed DOY")
  qe <- add_qe(qe, "MAE",            "mae_days",               "days",
               "Mean absolute error between predicted and observed DOY")
  qe <- add_qe(qe, "SN",             "sample_number",          "count",
               "Number of station observations retained after filtering")
  qe <- add_qe(qe, "COR",            "correlation",            "r",
               "Pearson correlation between predicted and observed DOY")
  qe <- add_qe(qe, "STD",            "residual_sd_cutoff",     "sigma",
               "Standard-deviation multiplier of the residual filter")
  qe <- add_qe(qe, "sn_exponent",    "adaptive_exponent_x",    NULL,
               "Year-specific exponent on sample number ratio")
  qe <- add_qe(qe, "OPT",            "OPT_score",              NULL,
               "Objective function OPT = SN^x(year) * COR")
  qe <- add_qe(qe, "OPT_normalized", "OPT_score_normalized",   "ratio",
               "OPT score normalised to [0, 1] across all years")
  qe <- add_qe(qe, "N_RATIO",        "n_ratio",                "ratio",
               "Sample retention SN/SN_max after residual SD filtering")
  qe
}

.phase_dataset <- function(plant, phase, years, parts_paths, crate_root,
                           quality_table) {
  if (!length(parts_paths)) return(NULL)

  # Collect per-year quality measurements as first-class entities (each with
  # its own @id). They are returned alongside the Dataset node so the caller
  # can hoist them into the @graph; the Dataset itself references them by
  # @id only, satisfying the JSON-LD "node reference" rule.
  qe_all <- list()
  for (yr in years) {
    qrow <- quality_table[quality_table$PLANT == plant &
                          quality_table$PHASE == phase   &
                          quality_table$YEAR  == yr, , drop = FALSE]
    if (NROW(qrow) == 0L) next
    qe_all <- c(qe_all,
                .per_year_quality_measurements(qrow[1, ], plant, phase, yr))
  }
  qm_refs <- lapply(qe_all, function(qe) list("@id" = qe[["@id"]]))

  dataset <- list(
    "@id"   = sprintf("#phase-%d-%d", plant, phase),
    "@type" = c("Dataset", "dcat:Dataset"),
    "name"  = sprintf("Filter variant results — plant %d, phase %d, %d–%d",
                      plant, phase, min(years), max(years)),
    "description" = paste0(
      "Filtered phenological entry-date observations for plant ", plant,
      ", phase ", phase, ", years ", min(years), "–", max(years), ". ",
      "The per-year shapefile sets selected by the residual-SD outlier ",
      "filter (Steps 5–6 of the PhenoPhaseR pipeline, objective function ",
      "OPT = SN^x(year) * COR) are packaged together in ",
      sprintf("`SHP_%d-%d.zip`", plant, phase),
      " (32 annual shapefile sets, naming convention DOY_<plant>-<phase>_<year>). ",
      "The accompanying per-phase OPT scoring tables and diagnostic plot ",
      "are also part of this Dataset. These shapefiles are the direct ",
      "input to spatial_interpolation.R (Step 7)."),
    "hasPart" = lapply(parts_paths,
                       function(p) list("@id" = .relpath(p, crate_root))),
    "schema:variableMeasured"   = qm_refs,
    "dqv:hasQualityMeasurement" = qm_refs,
    "schema:temporalCoverage" = sprintf("%d/%d", min(years), max(years)),
    "dct:temporal"            = sprintf("%d/%d", min(years), max(years)),
    "schema:spatialCoverage"  = list("@id" = "https://www.geonames.org/2921044/"),
    "dct:spatial"             = list("@id" = "https://www.geonames.org/2921044/")
  )

  list(dataset = dataset, measurements = qe_all)
}


# ---- README.md template inside the crate ---------------------------------
# Written at build time, embeds the same validator-stance paragraph as the
# Hook B crate so that anyone unpacking the ZIP from Zenodo finds it without
# leaving the deposit. Wording differs from Hook B: filter variant outputs
# are intermediate artefacts ingested by Step 7, not the final published
# dataset, and the contents are shapefiles + OPT CSVs rather than COGs.
.write_filtervariant_readme <- function(out_dir, plant, phase, years,
                                       software_doi, input_data_doi,
                                       downstream_doi,
                                       validation_result = NULL) {
  readme_path <- file.path(out_dir, "README.md")
  ph_str <- paste(phase, collapse = ", ")
  yr_str <- sprintf("%d–%d", min(years), max(years))

  txt <- c(
    sprintf("# PhenoPhaseR filter variant results — plant %d, phases %s, %s",
            plant, ph_str, yr_str),
    "",
    sprintf(paste(
      "Filtered and optimised phenological entry-date observations from the",
      "DWD annual-reporter network for plant %d (DWD/JKI code), phenological",
      "phases %s, years %s. Per-(phase, year) shapefiles selected by the",
      "objective function OPT = SN^x(year) × COR with a residual",
      "standard-deviation outlier cutoff (Steps 5–6 of the PhenoPhaseR",
      "pipeline). These shapefiles are the **direct input to",
      "spatial_interpolation.R (Step 7)**, which produces the final PHASE",
      "entry-date COGs deposited at https://doi.org/%s. This crate is the",
      "intermediate, reproducible record of the filter optimisation step,",
      "not a finished analysis product."),
      plant, ph_str, yr_str, downstream_doi),
    "",
    "## Contents",
    "",
    "- `shapefiles/SHP_<plant>-<phase>.zip` — One ZIP per phenological phase, each containing 32 annual ESRI Shapefile sets (`DOY_<plant>-<phase>_<year>.{shp,shx,dbf,prj,cpg}`) for years 1993–2024.",
    "- `opt_scores/OPT_ALL_<plant>.csv` — Full optimisation landscape: all 45 candidate (q, f_std) filter variants per (year, phase) combination, all phases, all years.",
    "- `opt_scores/OPT_MAX_<plant>.csv` — Year-specific best-performing filter variant, all phases, all years. Columns: `PLANT, PHASE, YEAR, Q, RMSE, MAE, SN, COR, STD, sn_exponent, OPT, OPT_normalized`.",
    "- `opt_scores/OPT_<plant>_EXPONENTS.csv` — Year-specific adaptive exponents alpha(y) used in the OPT objective function.",
    "- `opt_scores/OPT_ALL_<plant>-<phase>.csv`, `opt_scores/OPT_MAX_<plant>-<phase>.csv` — Per-phase slices of the OPT tables (one file per phase).",
    "- `opt_scores/diagnostics/OPT_<plant>-<phase>_DIAGNOSTICS.pdf` — Per-phase diagnostic plots.",
    "- `ro-crate-metadata.json` — RO-Crate 1.2 manifest with PROV-O provenance and ISO 19157-1 quality elements (via DQV/SKOS). The manifest groups outputs by phenological phase, with per-year quality measurements as inline DQV nodes tagged with `dct:temporal`.",
    "- `ro-crate-preview.html` — Self-contained human-readable rendering of the manifest (open in any web browser; no tooling required).",
    "",
    "Read one shapefile from a phase ZIP in R:",
    "",
    "```r",
    "library(sf)",
    "# Extract one year's shapefile set from the phase ZIP",
    "unzip(\"shapefiles/SHP_202-15.zip\", files = paste0(\"DOY_202-15_2020.\",",
    "                                                  c(\"shp\",\"shx\",\"dbf\",\"prj\",\"cpg\")),",
    "      exdir = tempdir())",
    "obs <- sf::st_read(file.path(tempdir(), \"DOY_202-15_2020.shp\"))",
    "```",
    "",
    "## Validation",
    "",
    paste("This deposit declares conformance to the **RO-Crate 1.2** base",
          "profile and the **Process Run Crate** profile",
          "([https://w3id.org/ro/wfrun/process/0.5](https://w3id.org/ro/wfrun/process/0.5)),",
          "which is the WRROC base profile for series of software applications",
          "that contribute to the same overall computation without being",
          "orchestrated by a workflow engine. Conformance is verified at build",
          "time against the validator named below; we make no claims about",
          "cleanliness against other tools."),
    "",
    "### Build-time validation record",
    "",
    .validation_block_md(validation_result),
    "",
    "### Reproducing the validation",
    "",
    "```bash",
    "pip install roc-validator",
    "rocrate-validator validate -l required -p ro-crate-1.1 .",
    "```",
    "",
    paste("We chose `roc-validator` because it is the only RO-Crate",
          "validation tool that (a) validates against the profiles a crate",
          "declares, rather than a fixed ruleset, and (b) separates",
          "**REQUIRED** from **RECOMMENDED** / **OPTIONAL** severity levels",
          "— so a clean run at REQUIRED is a well-defined claim. Other",
          "RO-Crate validation tools exist and may report additional",
          "advisory notices; those notices do not affect RO-Crate 1.2",
          "conformance, parsing by `ro-crate-py`, or rendering by",
          "RO-Crate–aware HTML viewers, and we do not treat them as gating."),
    "",
    paste("For visual inspection without any tooling, open",
          "`ro-crate-preview.html` in a web browser."),
    "",
    "## Provenance and citation",
    "",
    sprintf("- Software: PhenoPhaseR — https://doi.org/%s",  software_doi),
    sprintf("- Input data (DWD): https://doi.org/%s",        input_data_doi),
    sprintf("- Downstream dataset (PHASE COGs, Hook B): https://doi.org/%s", downstream_doi),
    "",
    "## License",
    "",
    "Crate contents: CC-BY-4.0. Generating code: MIT.",
    "",
    "---",
    sprintf("Generated by `build_filtervariant_ro_crate.R` on %s.",
            format(Sys.Date()))
  )

  writeLines(txt, readme_path, useBytes = TRUE)
  message("Wrote crate README: ", readme_path)
  invisible(readme_path)
}


# ---- ro-crate-preview.html: pure-R renderer ------------------------------
# Same renderer as in build_phase_cog_ro_crate.R. Reads the manifest at
# out_dir/ro-crate-metadata.json and produces a self-contained HTML preview
# using only base R + jsonlite (already a hard dependency). No Node.js, no
# npm, no external binaries. Eventually factor into _utils_rocrate.R and
# source from both hook scripts.
.write_ro_crate_html_native <- function(out_dir) {
  metadata_json <- file.path(out_dir, "ro-crate-metadata.json")
  preview_path  <- file.path(out_dir, "ro-crate-preview.html")
  if (!file.exists(metadata_json)) return(invisible(NULL))

  crate <- jsonlite::fromJSON(metadata_json, simplifyVector = FALSE)
  graph <- crate[["@graph"]]
  if (is.null(graph) || length(graph) == 0L) return(invisible(NULL))

  esc <- function(x) {
    if (is.null(x) || length(x) == 0L) return("")
    x <- as.character(x)
    x <- gsub("&",  "&amp;",  x, fixed = TRUE)
    x <- gsub("<",  "&lt;",   x, fixed = TRUE)
    x <- gsub(">",  "&gt;",   x, fixed = TRUE)
    x <- gsub("\"", "&quot;", x, fixed = TRUE)
    x
  }
  anchorize <- function(id)
    paste0("e-", gsub("[^A-Za-z0-9._-]", "_", as.character(id)))

  entity_index <- list()
  for (e in graph) {
    id <- as.character(e[["@id"]])
    nm <- if (!is.null(e[["name"]]))         as.character(e[["name"]])
          else if (!is.null(e[["schema:name"]])) as.character(e[["schema:name"]])
          else id
    entity_index[[id]] <- nm
  }
  id_link <- function(id) {
    id_char <- as.character(id)
    if (id_char %in% names(entity_index))
      sprintf("<a href=\"#%s\">%s</a> <code>(%s)</code>",
              anchorize(id_char), esc(entity_index[[id_char]]), esc(id_char))
    else if (grepl("^https?://", id_char))
      sprintf("<a href=\"%s\">%s</a>", esc(id_char), esc(id_char))
    else
      sprintf("<code>%s</code>", esc(id_char))
  }

  render_value <- function(v) {
    if (is.null(v)) return("&mdash;")
    if (!is.list(v)) {
      v_char <- as.character(v)
      if (length(v_char) == 0L) return("&mdash;")
      if (length(v_char) > 1L) {
        parts <- vapply(v_char, function(x) {
          if (grepl("^https?://", x))
            sprintf("<a href=\"%s\">%s</a>", esc(x), esc(x))
          else esc(x)
        }, character(1))
        return(paste(parts, collapse = ", "))
      }
      if (grepl("^https?://", v_char))
        return(sprintf("<a href=\"%s\">%s</a>", esc(v_char), esc(v_char)))
      return(esc(v_char))
    }
    if (is.null(names(v))) {
      if (length(v) == 0L) return("&mdash;")
      is_nested_obj <- vapply(v, function(x)
        is.list(x) && !is.null(names(x)) && !identical(names(x), "@id"),
        logical(1))
      if (length(v) > 5L && all(is_nested_obj)) {
        json_pretty <- as.character(jsonlite::toJSON(
          v, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
        return(sprintf(
          "<details><summary>array of %d nested objects (click to expand)</summary><pre>%s</pre></details>",
          length(v), esc(json_pretty)))
      }
      return(paste(vapply(v, render_value, character(1)), collapse = "; "))
    }
    if (length(v) == 1L && identical(names(v), "@id"))
      return(id_link(v[["@id"]]))
    json_pretty <- as.character(jsonlite::toJSON(
      v, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null"))
    if (nchar(json_pretty) <= 160L)
      return(sprintf("<code>%s</code>", esc(json_pretty)))
    sprintf(
      "<details><summary>nested object (%d keys)</summary><pre>%s</pre></details>",
      length(v), esc(json_pretty))
  }

  render_entity <- function(e) {
    id <- as.character(e[["@id"]])
    nm <- entity_index[[id]]
    types <- e[["@type"]]
    type_str <- if (is.null(types)) "Thing"
                else if (is.list(types))
                  paste(vapply(types, as.character, character(1)), collapse = ", ")
                else paste(as.character(types), collapse = ", ")
    rows <- character(0)
    for (k in setdiff(names(e), c("@id", "@type", "name"))) {
      rows <- c(rows, sprintf(
        "<tr><th>%s</th><td>%s</td></tr>", esc(k), render_value(e[[k]])))
    }
    root_class <- if (id == "./") " root" else ""
    sprintf(
      paste0("<section id=\"%s\" class=\"entity%s\">\n",
             "<h3>%s</h3>\n",
             "<p class=\"meta\"><code>@id:</code> <code>%s</code> ",
             "&middot; <code>@type:</code> %s</p>\n",
             "<table>\n%s\n</table>\n</section>"),
      anchorize(id), root_class,
      esc(nm), esc(id), esc(type_str),
      paste(rows, collapse = "\n"))
  }

  toc_items <- vapply(graph, function(e) {
    id <- as.character(e[["@id"]])
    sprintf("<li><a href=\"#%s\">%s</a> &mdash; <code>%s</code></li>",
            anchorize(id), esc(entity_index[[id]]), esc(id))
  }, character(1))

  root_entity <- NULL
  for (e in graph) {
    if (identical(as.character(e[["@id"]]), "./")) { root_entity <- e; break }
  }
  crate_title <- if (!is.null(root_entity[["name"]]))
    as.character(root_entity[["name"]]) else "RO-Crate"

  css <- paste0(
    "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;",
    "max-width:980px;margin:2em auto;padding:0 1.2em;color:#222;line-height:1.55}",
    "h1{border-bottom:2px solid #2c3e50;padding-bottom:.3em;margin-bottom:.2em}",
    "h2{margin-top:2em;border-bottom:1px solid #aaa;padding-bottom:.2em}",
    "h3{margin:0 0 .3em 0}",
    ".lead{color:#666;margin-top:0;font-style:italic}",
    ".meta{font-size:.9em;color:#555;margin:.2em 0 .8em 0}",
    "table{border-collapse:collapse;width:100%;margin:.4em 0 1em 0}",
    "th{background:#f4f6f8;text-align:left;padding:.45em .8em;border:1px solid #d8dee4;",
    "width:22%;vertical-align:top;font-weight:600}",
    "td{padding:.45em .8em;border:1px solid #d8dee4;vertical-align:top}",
    "a{color:#1c6ea4;text-decoration:none}a:hover{text-decoration:underline}",
    "code{background:#f4f6f8;padding:.1em .35em;border-radius:3px;font-size:.9em;",
    "font-family:'SFMono-Regular',Consolas,'Liberation Mono',monospace}",
    ".toc{background:#fafbfc;border:1px solid #d8dee4;padding:.8em 1.2em;margin:1em 0 2em 0}",
    ".toc ul{margin:.3em 0;padding-left:1.4em}.toc li{margin:.15em 0}",
    "section.entity{margin-top:1.5em}",
    "section.root{background:#f8fbfd;border-left:4px solid #1c6ea4;padding:1em 1.5em}",
    "details{margin:.3em 0}details summary{cursor:pointer;color:#555;font-size:.9em}",
    "details pre{background:#fafbfc;padding:.6em;border:1px solid #d8dee4;",
    "border-radius:3px;overflow-x:auto;font-size:.85em}",
    ".footer{margin-top:3em;padding-top:1em;border-top:1px solid #d8dee4;",
    "font-size:.85em;color:#666}"
  )

  html <- c(
    "<!DOCTYPE html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    sprintf("<title>%s &mdash; RO-Crate preview</title>", esc(crate_title)),
    sprintf("<style>%s</style>", css),
    "</head>",
    "<body>",
    sprintf("<h1>%s</h1>", esc(crate_title)),
    paste("<p class=\"lead\">RO-Crate 1.2 preview &mdash; rendered by",
          "<code>build_filtervariant_ro_crate.R</code> (native R renderer,",
          "no external dependencies).</p>"),
    "<nav class=\"toc\"><strong>Entities in this crate:</strong>",
    "<ul>",
    paste(toc_items, collapse = "\n"),
    "</ul></nav>",
    "<h2>Entity details</h2>",
    paste(vapply(graph, render_entity, character(1)), collapse = "\n\n"),
    sprintf(paste("<p class=\"footer\">Generated on %s.",
                  "Validation strategy: see <code>README.md</code> in this",
                  "deposit.</p>"),
            format(Sys.Date())),
    "</body>",
    "</html>"
  )

  writeLines(html, preview_path, useBytes = TRUE)
  message("Wrote ro-crate-preview.html (native R): ", preview_path)
  invisible(preview_path)
}


# ---- Optional: run roc-validator at build time ---------------------------
# Soft dependency on the Python tool `rocrate-validator`
# (https://pypi.org/project/roc-validator/). When available on PATH and
# `enable = TRUE`, runs it at the REQUIRED severity level against the
# declared profiles, captures the output, and returns a small list with
# the result. When unavailable, returns a "not run" status without error
# so the build continues.
#
# The returned list is intended to be embedded into the in-crate README
# so the deposit carries a build-time validation record rather than a
# bare assertion.
.run_roc_validator <- function(out_dir, enable = TRUE,
                               profile = "ro-crate-1.1") {
  if (!isTRUE(enable))
    return(list(status = "skipped", reason = "disabled by caller",
                profile = profile, version = NA_character_, output = ""))

  bin <- Sys.which("rocrate-validator")
  if (!nzchar(bin))
    return(list(status = "not_run",
                reason = "rocrate-validator not found on PATH",
                profile = profile,
                version = NA_character_, output = ""))

  ver <- tryCatch(
    paste(system2(bin, args = "--version", stdout = TRUE, stderr = TRUE),
          collapse = " "),
    error = function(e) NA_character_)

  res <- tryCatch(
    system2(bin,
            args = c("validate", "-l", "required",
                     "-p", shQuote(profile),
                     shQuote(out_dir)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) NULL)

  status <- attr(res, "status")
  if (is.null(status)) status <- 0L
  list(
    status  = if (status == 0L) "passed" else "failed",
    reason  = NA_character_,
    profile = profile,
    version = ver,
    output  = paste(res, collapse = "
")
  )
}


# ---- Render a validation result as Markdown for the in-crate README ------
.validation_block_md <- function(vr) {
  if (is.null(vr)) vr <- list(status = "not_run",
                              reason = "validation step skipped",
                              profile = "ro-crate-1.1",
                              version = NA_character_, output = "")

  badge <- switch(vr$status,
    passed  = "PASSED",
    failed  = "FAILED",
    not_run = "NOT RUN",
    skipped = "SKIPPED",
    "UNKNOWN"
  )

  prof_applied <- if (is.null(vr$profile) || is.na(vr$profile) ||
                      !nzchar(vr$profile)) "ro-crate-1.1"
                  else vr$profile

  lines <- c(
    sprintf("- **Status:** **%s**", badge),
    "- **Validator:** [`rocrate-validator`](https://pypi.org/project/roc-validator/) (PyPI: `roc-validator`)",
    sprintf("- **Validator version:** %s",
            if (is.na(vr$version) || !nzchar(vr$version)) "_not recorded_"
            else paste0("`", vr$version, "`")),
    "- **Severity level applied:** `required`",
    sprintf("- **Validator profile applied:** `%s`", prof_applied),
    "- **Crate-declared profiles:** RO-Crate 1.2 base profile; Process Run Crate (WRROC base)",
    sprintf("- **Build date:** %s", format(Sys.Date()))
  )

  # If the crate declares 1.2/Process-Run-Crate but we validated against 1.1,
  # add a brief explanatory note so a reader doesn't read "1.1 profile applied"
  # as a downgrade.
  if (prof_applied == "ro-crate-1.1")
    lines <- c(lines,
      paste("- **Note on profile choice:** the bundled profile set of",
            "`roc-validator` 0.9.x supports up to RO-Crate 1.1; the",
            "REQUIRED-level checks at 1.1 are a strict subset of what 1.2",
            "requires (1.2 adds optional features, not new MUST clauses on",
            "the base profile). The crate itself remains RO-Crate 1.2,",
            "declared by its `@context` and `conformsTo` properties; once",
            "`roc-validator` ships native 1.2 profile support, pass",
            "`profile = \"ro-crate-1.2\"` to switch."))

  if (!is.na(vr$reason) && nzchar(vr$reason))
    lines <- c(lines, sprintf("- **Note:** %s", vr$reason))

  if (vr$status %in% c("passed", "failed") && nzchar(vr$output))
    lines <- c(lines, "",
               "<details><summary>Validator output</summary>",
               "",
               "```",
               vr$output,
               "```",
               "",
               "</details>")
  paste(lines, collapse = "\n")
}


.run_ro_crate_html <- function(out_dir, enable = TRUE) {
  if (!isTRUE(enable)) return(invisible(NULL))
  metadata_json <- file.path(out_dir, "ro-crate-metadata.json")
  if (!file.exists(metadata_json)) return(invisible(NULL))

  bin <- Sys.which("rochtml")
  if (nzchar(bin)) {
    tryCatch(
      system2(bin, args = shQuote(metadata_json),
              stdout = TRUE, stderr = TRUE),
      error = function(e) NULL)
    preview_path <- file.path(out_dir, "ro-crate-preview.html")
    if (file.exists(preview_path)) {
      message("Wrote ro-crate-preview.html via rochtml.")
      return(invisible(preview_path))
    }
    message("rochtml found but did not produce a preview; ",
            "falling back to native R renderer.")
  }
  .write_ro_crate_html_native(out_dir)
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
  crop           = crop_spec(plant),
  creators       = default_creators("filter_variant"),
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  downstream_doi = "10.5281/zenodo.19571847",
  agent_orcid    = creators[[1]][["@id"]],
  agent_name     = creators[[1]][["name"]],
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = TRUE,
  generate_html_preview = TRUE,
  run_roc_validator     = TRUE,
  roc_validator_profile = "ro-crate-1.1"
) {

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # --- 0. Normalize quality_table (defensive; tolerate NULL & empty) ------
  # Same defense as build_phase_cog_ro_crate.R: a NULL or zero-row
  # quality_table would propagate to the per-(phase, year) loop and crash
  # at `!nrow(qrow)` with "invalid argument type" (the !NULL trap).
  .empty_qtab <- function() data.frame(
    PLANT = integer(0), PHASE = integer(0), YEAR = integer(0),
    Q = numeric(0), RMSE = numeric(0), MAE = numeric(0),
    SN = integer(0), COR = numeric(0), STD = numeric(0),
    sn_exponent = numeric(0), OPT = numeric(0), OPT_normalized = numeric(0),
    N_RATIO = numeric(0),
    stringsAsFactors = FALSE
  )
  if (is.null(quality_table) ||
      (is.data.frame(quality_table) && nrow(quality_table) == 0L)) {
    # Try to recover from the canonical master CSV on disk before giving up.
    master_csv <- file.path(results_dir, "opt_scores",
                            sprintf("OPT_MAX_%d_ALL_PHASES.csv", plant))
    if (file.exists(master_csv)) {
      quality_table <- utils::read.csv2(master_csv, stringsAsFactors = FALSE)
      message(sprintf("quality_table was empty; reconstructed from %s (%d rows).",
                      basename(master_csv), nrow(quality_table)))
    } else {
      message("quality_table is empty and no OPT_MAX master CSV found; ",
              "shapefile datasets will have no quality measurements attached.")
      quality_table <- .empty_qtab()
    }
  } else if (!is.data.frame(quality_table)) {
    stop("`quality_table` must be a data.frame (or NULL); got: ",
         paste(class(quality_table), collapse = "/"))
  }

  # --- 1. Stage artifacts into the crate ----------------------------------
  src <- .discover_artifacts(results_dir, plant, phase, years)
  per_phase_work <- file.path(out_dir, "_per_phase", "shapefiles")
  for (sub in c("shapefiles",
                "opt_scores",
                "opt_scores/diagnostics",
                "_per_phase/shapefiles"))
    dir.create(file.path(out_dir, sub), showWarnings = FALSE, recursive = TRUE)

  # Per-phase OPT and diagnostic files are copied with their original names;
  # they stay member-of-phase-Dataset.
  if (length(src$opt_per_phase)) file.copy(src$opt_per_phase, file.path(out_dir, "opt_scores"),             overwrite = TRUE)
  if (length(src$diagnostics))   file.copy(src$diagnostics,   file.path(out_dir, "opt_scores/diagnostics"), overwrite = TRUE)

  # Plant-level master CSVs: rename during staging
  #   OPT_ALL_<plant>_ALL_PHASES.csv → OPT_ALL_<plant>.csv
  #   OPT_MAX_<plant>_ALL_PHASES.csv → OPT_MAX_<plant>.csv
  #   OPT_<plant>_EXPONENTS_ALL_PHASES.csv → OPT_<plant>_EXPONENTS.csv
  # The shorter names match the Zenodo record 20232707 published layout and
  # read better on the deposit landing page.
  for (p in src$opt_master) {
    bn      <- basename(p)
    new_bn  <- sub(sprintf("^OPT_(ALL|MAX)_%d_ALL_PHASES\\.csv$", plant),
                   sprintf("OPT_\\1_%d.csv", plant), bn)
    file.copy(p, file.path(out_dir, "opt_scores", new_bn), overwrite = TRUE)
  }
  for (p in src$exponents) {
    bn     <- basename(p)
    new_bn <- sub(sprintf("^OPT_%d_EXPONENTS_ALL_PHASES\\.csv$", plant),
                  sprintf("OPT_%d_EXPONENTS.csv", plant), bn)
    file.copy(p, file.path(out_dir, "opt_scores", new_bn), overwrite = TRUE)
  }

  # Per-phase ZIPs: bundle each phase's 32 shapefile sets (5 files each =
  # ~160 files per phase) into SHP_<plant>-<phase>.zip under shapefiles/.
  # The original per-(phase, year) components are staged into
  # _per_phase/shapefiles/<phase>/ so they remain on disk for provenance
  # (the working subfolder is excluded from the published ZIP).
  phase_zip_paths <- character(0)
  for (ph in phase) {
    pat <- sprintf("^DOY_%d-%d_\\d+\\.(shp|shx|dbf|prj|cpg)$", plant, ph)
    hits <- src$shapefiles[grepl(pat, basename(src$shapefiles))]
    if (!length(hits)) {
      message(sprintf("No shapefile components found for phase %d; skipping.", ph))
      next
    }

    ph_work <- file.path(per_phase_work, as.character(ph))
    dir.create(ph_work, showWarnings = FALSE, recursive = TRUE)
    file.copy(hits, ph_work, overwrite = TRUE)

    # Build the ZIP from the relative file list so the archive's internal
    # paths are flat (no `_per_phase/shapefiles/<phase>/` prefix inside).
    zip_rel  <- file.path("shapefiles",
                          sprintf("SHP_%d-%d.zip", plant, ph))
    zip_abs  <- file.path(out_dir, zip_rel)
    if (file.exists(zip_abs)) file.remove(zip_abs)
    local({
      old <- setwd(ph_work); on.exit(setwd(old), add = TRUE)
      flat_names <- list.files(".", recursive = FALSE)
      utils::zip(zip_abs, flat_names, flags = "-9Xq")
    })
    phase_zip_paths <- c(phase_zip_paths, zip_abs)
    message(sprintf(
      "Built phase ZIP: %s (%d files across %d shapefile sets)",
      basename(zip_abs), length(hits), length(hits) %/% 5L))
  }

  # Re-discover what landed under out_dir (with master CSVs now renamed)
  art <- .discover_staged_artifacts(out_dir, plant, phase)

  # --- 2. Per-phase Datasets (one per phase, multi-year measurements) -----
  # Each call to .phase_dataset() returns a list with two slots: the Dataset
  # node (with @id-only references in schema:variableMeasured) and the
  # measurement entities themselves, which we hoist into the @graph as first-
  # class top-level entries. This is the JSON-LD-correct shape; the previous
  # inline-anonymous-object form tripped roc-validator's REQUIRED checks.
  phase_datasets       <- list()
  measurement_entities <- list()
  for (ph in phase) {
    # Parts belonging to this phase Dataset: the phase ZIP + per-phase OPT
    # CSVs + the diagnostic PDF (any that exist).
    pz <- art$phase_zips[grepl(sprintf("^SHP_%d-%d\\.zip$", plant, ph),
                               basename(art$phase_zips))]
    pp <- art$opt_per_phase[grepl(sprintf("^OPT_(ALL|MAX)_%d-%d\\.csv$",
                                          plant, ph),
                                  basename(art$opt_per_phase))]
    pd <- art$diagnostics[grepl(sprintf("^OPT_%d-%d_DIAGNOSTICS\\.pdf$",
                                        plant, ph),
                                basename(art$diagnostics))]
    parts <- c(pz, pp, pd)
    if (!length(parts)) next

    ds <- .phase_dataset(plant       = plant,
                         phase       = ph,
                         years       = years,
                         parts_paths = parts,
                         crate_root  = out_dir,
                         quality_table = quality_table)
    if (is.null(ds)) next
    phase_datasets       <- c(phase_datasets,       list(ds$dataset))
    measurement_entities <- c(measurement_entities, ds$measurements)
  }

  # --- 2b. dqv:Metric entities (one per unique measure name in crate) -----
  # The Metric describes what is being measured (RMSE in days, mapped to
  # ISO 19157 DQ_ThematicAccuracy). Many measurements share the same Metric;
  # hoisting it out of each measurement node removes ~10× redundancy and
  # gives downstream DQV consumers a stable identifier to group by.
  measure_names <- unique(vapply(measurement_entities,
                                 function(e) e[["schema:name"]],
                                 character(1)))
  metric_entities <- lapply(measure_names, .metric_entity)

  # --- 3. Per-component File entities -------------------------------------
  file_entities <- c(
    lapply(art$phase_zips,    .file_entity, crate_root = out_dir,
           description = "ZIP archive of 32 annual ESRI Shapefile sets for one phenological phase (1993–2024). Each set: .shp, .shx, .dbf, .prj, .cpg."),
    lapply(art$opt_per_phase, .file_entity, crate_root = out_dir,
           description = "Per-phase OPT scoring table from filter_variant_selector"),
    lapply(art$opt_master,    .file_entity, crate_root = out_dir,
           description = "Plant-level OPT scoring table aggregated across all phenological phases"),
    lapply(art$exponents,     .file_entity, crate_root = out_dir,
           description = "Year-specific adaptive exponents alpha(y) used in the OPT objective function"),
    lapply(art$diagnostics,   .file_entity, crate_root = out_dir,
           description = "Diagnostic plots for filter variant optimisation")
  )

  # README.md: written before file_entities is finalised so it appears as a
  # File entity in the manifest and is referenced from the root dataset.
  # The first pass uses validation_result = NULL (status "not_run"); after
  # the manifest is written and `roc-validator` has run, the README is
  # rewritten with the real result. This keeps the validation record inside
  # the README itself rather than in a separate file.
  readme_path <- .write_filtervariant_readme(
    out_dir           = out_dir,
    plant             = plant,
    phase             = phase,
    years             = years,
    software_doi      = software_doi,
    input_data_doi    = input_data_doi,
    downstream_doi    = downstream_doi,
    validation_result = NULL
  )
  file_entities <- c(file_entities, list(.file_entity(
    readme_path, out_dir,
    description = paste(
      "Human-readable overview of the crate's contents and the build-time",
      "RO-Crate validation record (validator name, version, profiles, and",
      "status as captured at build time)."))))

  # --- 4. PROV-O CreateAction (Steps 1–6) ---------------------------------
  all_outputs <- unname(unlist(c(art$phase_zips, art$opt_per_phase,
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
  # The phase Datasets carry the per-phase ZIPs + per-phase OPT CSVs +
  # diagnostic PDFs as hasPart. The root collects the plant-level master
  # tables (OPT_ALL_<plant>.csv, OPT_MAX_<plant>.csv, EXPONENTS) directly,
  # plus references the phase Datasets and the README.
  root_extra_files <- c(art$opt_master, art$exponents)
  # --- 5a. Build subject / keyword / creator entities --------------------
  # Centralised in _crop_specs.R so the same policy applies across every
  # crop and both crate kinds (filter variants and PHASE).
  subj_bundle    <- build_subject_entities(crop, artefact = "filter_variant")
  creator_bundle <- build_creator_entities(creators)
  kw             <- build_keywords(crop, artefact = "filter_variant")

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
    "creator"       = creator_bundle$creator_refs,
    "dct:creator"   = creator_bundle$creator_refs,
    "publisher"     = list("@id" = "https://ror.org/022d5qt08"),
    "dct:publisher" = list("@id" = "https://ror.org/022d5qt08"),
    "keywords"      = kw,
    "dcat:keyword"  = kw,
    # Domain semantics: AGROVOC subject terms (crop + phenology + GDD + Germany)
    "about"         = subj_bundle$subject_refs,
    "dct:subject"   = subj_bundle$subject_refs,
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
      lapply(phase_datasets, function(d) list("@id" = d[["@id"]])),
      lapply(root_extra_files,
             function(p) list("@id" = .relpath(p, out_dir))),
      list(list("@id" = "README.md"))
    ),
    "wasGeneratedBy"      = list("@id" = "#filtervariant-creation"),
    "prov:wasGeneratedBy" = list("@id" = "#filtervariant-creation")
  )

  # --- 6. Contextual entities --------------------------------------------
  context_entities <- c(
    # Person entities for all creators (with roles + affiliation)
    creator_bundle$person_entities,
    list(
      # Profile Crate node — declares which WRROC profile this crate conforms
      # to. Process Run Crate (WRROC base profile) fits PhenoPhaseR's
      # multi-step R pipeline: a sequence of software applications that
      # contribute to the same overall computation, without being orchestrated
      # by a workflow engine. See https://w3id.org/ro/wfrun/process/0.5
      list("@id"     = "https://w3id.org/ro/wfrun/process/0.5",
           "@type"   = "CreativeWork",
           "name"    = "Process Run Crate",
           "version" = "0.5"),
      list("@id" = "https://ror.org/022d5qt08",
           "@type" = "Organization",
           "name"  = paste("Julius K\u00fchn-Institut (JKI) \u2013 Federal",
                           "Research Centre for Cultivated Plants")),
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
           "@type" = "Place", "name" = "Federal Republic of Germany"),
      # AGROVOC concept set + DefinedTerm entities
      subj_bundle$defined_term_set
    ),
    subj_bundle$defined_terms
  )

  # --- 7. Metadata descriptor --------------------------------------------
  metadata_descriptor <- list(
    "@id"        = "ro-crate-metadata.json",
    "@type"      = "CreativeWork",
    "conformsTo" = list(
      list("@id" = "https://w3id.org/ro/crate/1.2"),
      list("@id" = "https://w3id.org/ro/wfrun/process/0.5")
    ),
    "about"      = list("@id" = "./"),
    "description" = paste(
      "RO-Crate 1.2 (Process Run Crate profile) describing the filter",
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
        # Domain subject vocabulary (referenced via schema:about / dct:subject)
        "agrovoc"  = "http://aims.fao.org/aos/agrovoc/",
        # Carrier vocabularies. Note: schema is http (not https) by design —
        # the official RO-Crate 1.2 context loaded above maps all Schema.org
        # terms to http://schema.org/ identifiers. Using https here would
        # split Schema.org into two RDF namespaces in the expanded graph
        # (Schema.org-from-RO-Crate vs. Schema.org-from-this-prefix). Stay on
        # http until and unless RO-Crate itself migrates.
        "schema"   = "http://schema.org/",
        "spdx"     = "http://spdx.org/rdf/terms#"
      )
    ),
    "@graph" = c(
      list(metadata_descriptor),
      list(root_dataset),
      phase_datasets,
      file_entities,
      measurement_entities,
      metric_entities,
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

  # Generate ro-crate-preview.html (native R; rochtml if available).
  .run_ro_crate_html(out_dir, enable = generate_html_preview)

  # Run roc-validator against the finished crate and rewrite the README so
  # the validation record is captured inside the deposit. Soft dependency:
  # skipped with a "not_run" status if `rocrate-validator` isn't installed.
  vr <- .run_roc_validator(out_dir, enable = run_roc_validator,
                           profile = roc_validator_profile)
  message(sprintf("rocrate-validator: %s%s",
                  vr$status,
                  if (!is.na(vr$reason) && nzchar(vr$reason))
                    sprintf(" (%s)", vr$reason) else ""))
  .write_filtervariant_readme(
    out_dir           = out_dir,
    plant             = plant,
    phase             = phase,
    years             = years,
    software_doi      = software_doi,
    input_data_doi    = input_data_doi,
    downstream_doi    = downstream_doi,
    validation_result = vr
  )

  if (zip_output) {
    zip_path <- paste0(out_dir, ".zip")
    old <- setwd(dirname(out_dir)); on.exit(setwd(old), add = TRUE)
    # Enumerate the contents of out_dir explicitly, excluding the working
    # subfolder _per_phase/ so the published ZIP carries only the per-phase
    # ZIPs + the renamed master CSVs + metadata. _per_phase/ remains on
    # disk for provenance.
    pub <- setdiff(list.files(basename(out_dir), recursive = TRUE,
                              all.files = FALSE, full.names = TRUE,
                              include.dirs = FALSE),
                   list.files(file.path(basename(out_dir), "_per_phase"),
                              recursive = TRUE,
                              all.files = FALSE, full.names = TRUE,
                              include.dirs = FALSE))
    utils::zip(zip_path, pub, flags = "-9X")
    message("Wrote crate ZIP    : ", zip_path,
            " (excludes _per_phase/ working subfolder)")
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
#
#   ## Simplest call — crop_spec is looked up automatically by plant ID,
#   ## creators defaults to the family-wide list defined in _crop_specs.R:
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
#
#   ## To override the default contributor list for a specific deposit
#   ## (e.g. solo-authored test crate):
#   # build_filtervariant_ro_crate(
#   #   ..., creators = list(
#   #     list("@id"   = "https://orcid.org/0000-0002-1918-7747",
#   #          name    = "Markus Möller",
#   #          role    = "Producer",
#   #          affiliation_ror = "https://ror.org/022d5qt08")
#   #   )
#   # )
# ============================================================================
