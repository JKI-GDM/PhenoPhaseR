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


# ---- README.md template inside the crate ---------------------------------
# Written at build time, embeds the same validator-stance paragraph as the
# Hook B crate so that anyone unpacking the ZIP from Zenodo finds it without
# leaving the deposit. Wording differs from Hook B: filter variant outputs
# are intermediate artefacts ingested by Step 7, not the final published
# dataset, and the contents are shapefiles + OPT CSVs rather than COGs.
.write_filtervariant_readme <- function(out_dir, plant, phase, years,
                                       software_doi, input_data_doi,
                                       downstream_doi) {
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
    "- `shapefiles/DOY_<plant>-<phase>_<year>.{shp,shx,dbf,prj,cpg}` — per-(phase, year) filtered DOY observations (EPSG:31467).",
    "- `opt_scores/OPT_ALL_<plant>-<phase>.csv` — full OPT scoring grid across filter variants for each phase.",
    "- `opt_scores/OPT_MAX_<plant>-<phase>.csv` — selected filter variant per (phase, year).",
    "- `opt_scores/OPT_<plant>_ALL_PHASES.csv`  — concatenated master tables across all phases.",
    "- `opt_scores/OPT_<plant>_EXPONENTS_ALL_PHASES.csv` — year-specific adaptive exponents.",
    "- `opt_scores/diagnostics/OPT_<plant>-<phase>_DIAGNOSTICS.pdf` — diagnostic plots of the optimisation.",
    "- `ro-crate-metadata.json` — RO-Crate 1.2 manifest with PROV-O provenance and ISO 19157-1 quality elements (via DQV/SKOS).",
    "- `ro-crate-preview.html`  — self-contained human-readable rendering of the manifest (open in any web browser; no tooling required).",
    "",
    "Read one shapefile in R:",
    "",
    "```r",
    "library(sf)",
    "obs <- sf::st_read(\"shapefiles/DOY_202-15_2020.shp\")",
    "```",
    "",
    "## Validation",
    "",
    paste("The normative validation gate for this crate is",
          "[`roc-validator`](https://pypi.org/project/roc-validator/) at the",
          "REQUIRED severity level, against the declared profiles. The crate",
          "passes that gate as deposited:"),
    "",
    "```bash",
    "pip install roc-validator",
    "rocrate-validator validate -l required .",
    "```",
    "",
    paste("Other validators report advisory notices that do **not** affect",
          "RO-Crate 1.2 conformance, parsing, or interoperability:"),
    "",
    paste("- The [NovaCrate](https://novacrate.datamanager.kit.edu/) editor",
          "raises type-range recommendations on entities co-typed with `dct:`",
          "properties — e.g. `dct:creator` expecting `dct:Agent`,",
          "`dct:license` expecting `dct:LicenseDocument`, `dct:spatial`",
          "expecting `dct:Location`. These are DCAT 3 / DCTERMS range",
          "refinements layered on top of RO-Crate's baseline rules, not",
          "RO-Crate violations."),
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
  software_doi   = "10.5281/zenodo.18743008",
  input_data_doi = "10.5281/zenodo.18772094",
  downstream_doi = "10.5281/zenodo.19571847",
  agent_orcid    = "https://orcid.org/0000-0002-1918-7747",
  agent_name     = "Markus Möller",
  start_time     = Sys.time() - 3600,
  end_time       = Sys.time(),
  zip_output     = TRUE,
  generate_html_preview = TRUE
) {

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # --- 0. Normalize quality_table (defensive; tolerate NULL & empty) ------
  # Same defense as build_phase_cog_ro_crate.R: a NULL or zero-row
  # quality_table would propagate to the per-(phase, year) loop and crash
  # at `!nrow(qrow)` with "invalid argument type" (the !NULL trap).
  .empty_qtab <- function() data.frame(
    PLANT = integer(0), PHASE = integer(0), YEAR = integer(0),
    STD = numeric(0), SN = integer(0), COR = numeric(0), MAE = numeric(0),
    OPT = numeric(0), OPT_normalized = numeric(0),
    sn_exponent = numeric(0), N_RATIO = numeric(0),
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
                          quality_table$YEAR  == yr, , drop = FALSE]
    # NROW() returns 0 for NULL and zero-row data frames alike, sidestepping
    # the !NULL crash that was possible with `!nrow(qrow)`.
    if (NROW(qrow) == 0L)
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

  # README.md: written before file_entities is finalised so it appears as a
  # File entity in the manifest and is referenced from the root dataset.
  readme_path <- .write_filtervariant_readme(
    out_dir         = out_dir,
    plant           = plant,
    phase           = phase,
    years           = years,
    software_doi    = software_doi,
    input_data_doi  = input_data_doi,
    downstream_doi  = downstream_doi
  )
  file_entities <- c(file_entities, list(.file_entity(
    readme_path, out_dir,
    description = paste(
      "Human-readable overview of the crate's contents and a notice on",
      "RO-Crate validation: roc-validator REQUIRED-clean; advisory",
      "notices from NovaCrate are documented inside."))))

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
             function(p) list("@id" = .relpath(p, out_dir))),
      list(list("@id" = "README.md"))
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

  # Generate ro-crate-preview.html (native R; rochtml if available).
  .run_ro_crate_html(out_dir, enable = generate_html_preview)

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
