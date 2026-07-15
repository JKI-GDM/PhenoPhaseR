#!/usr/bin/env Rscript
# =============================================================================
# run_zenodo_deposit.R  —  maintainer runner for the metadata-only Zenodo
#                         deposit workflow (PhenoPhaseR).
#
# WHAT THIS IS
#   A thin driver that (1) checks the per-crop RO-Crate folders exist, (2) sources
#   the deposit tools in order, and (3) leaves you with Zenodo DRAFTS to review.
#   It computes nothing and changes no data. All the real work lives in:
#     function/build_zenodo_metadata.R   — assembles the per-crate .zenodo.json
#     tools/push_zenodo_metadata.R       — creates one Zenodo DRAFT per deposit
#     tools/check_draft.R                — prints the POST body / reads drafts back
#
# IT DOES NOT UPLOAD FILES AND DOES NOT PUBLISH.
#   push_zenodo_metadata.R creates drafts only; you add the data files and hit
#   "Publish" in the browser. For an already-published deposit this is how you
#   cut a metadata-only NEW VERSION (data files byte-identical).
#
# SECURITY — the token is NEVER stored in this file.
#   Set it in your environment before running, e.g. in ~/.Renviron:
#       ZENODO_TOKEN=xxxxxxxx        (scope: deposit:write)
#   or for one session:  Sys.setenv(ZENODO_TOKEN = "…")  at the console (not here).
#   This script aborts if ZENODO_TOKEN is unset, rather than carrying a placeholder
#   that could be edited into a real secret and committed.
#
# USAGE
#   Edit the two parameters below (ROOT, CROPS), ensure ZENODO_TOKEN is set, then:
#       Rscript tools/run_zenodo_deposit.R
#   or  source("tools/run_zenodo_deposit.R")   from an R session.
# =============================================================================

# ---- parameters (edit these; no absolute paths or secrets baked in) ---------
ROOT  <- Sys.getenv("PHENOPHASER_ROOT", path.expand("~/PhenoPhaseR"))
CROPS <- 253            # one id, or c(204, 205, 207, …); NULL = every crop found

# ---- preconditions ----------------------------------------------------------
if (!nzchar(Sys.getenv("ZENODO_TOKEN")))
  stop("ZENODO_TOKEN is not set. Export it in your environment (e.g. ~/.Renviron) ",
       "before running; do not hardcode it in this file.", call. = FALSE)

out_dir <- file.path(ROOT, "output")
if (!dir.exists(out_dir))
  stop("Output directory not found: ", out_dir,
       " — set PHENOPHASER_ROOT or fix ROOT.", call. = FALSE)

# ---- (1) show which crops have PHASE / FilterVariant crate folders ----------
ids <- if (is.null(CROPS)) {
  sub("/$", "", list.dirs(out_dir, recursive = FALSE, full.names = FALSE))
} else CROPS
cat("crop : phase_crate filtervariant_crate\n")
for (id in ids)
  cat(sprintf("%-5s: %-11s %s\n", id,
      dir.exists(file.path(out_dir, id, "ro_crate_phase")),
      dir.exists(file.path(out_dir, id, "ro_crate_filtervariants"))))

# ---- (2) source the deposit tools in order ----------------------------------
# build_zenodo_metadata.R and the tools read ZENODO_TOKEN / PKG_ROOT / CROPS
# themselves; CROPS defined above is honoured by push_zenodo_metadata.R.
source(file.path(ROOT, "function", "_crop_specs.R"))
source(file.path(ROOT, "function", "build_zenodo_metadata.R"))
source(file.path(ROOT, "tools",    "push_zenodo_metadata.R"))  # one crop's phase + filtervariant
source(file.path(ROOT, "tools",    "check_draft.R"))

# ---- (3) next step is manual --------------------------------------------------
message("\nDrafts created. Review each in the Zenodo browser, add the (unchanged) ",
        "data files, and Publish. For a metadata-only new version, confirm the ",
        "files are byte-identical to the previous version before publishing.")
