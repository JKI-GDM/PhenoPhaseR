# =============================================================================
# push_zenodo_metadata.R   (metadata-only)
#
# Creates a Zenodo DRAFT for each crop deposit from the already-generated
# `.zenodo.json`, with clean metadata annotation. It does NOT upload files and
# does NOT publish — you add the data files and hit "Publish" in the browser.
#
# Point PKG_ROOT at your pipeline output; Hook C (write_zenodo_metadata) wrote a
# .zenodo.json into each crate folder there. File discovery is recursive and
# layout-agnostic, so it also works with the unzipped standalone packages.
#
#   PKG_ROOT/                                    (e.g. ~/PhenoPhaseR/output)
#     203/ro_crate_filtervariants/filtervariants.zenodo.json
#     203/ro_crate_phase/phase.zenodo.json
#     204/ro_crate_*/...   (etc.)
#
# Re-runnable: each created draft's id is logged to zenodo_drafts.csv. Set
# RESET <- TRUE to delete the previously-logged drafts before recreating them,
# so tuning the metadata never spawns duplicate drafts.
#
# zen4R builds and validates each record, but the deposit POST is sent via
# libcurl directly: zen4R's httr POST does not survive the JKI inspecting proxy
# (the draft is created empty), whereas a direct libcurl POST of the identical
# body does (verified over both HTTP/1.1 and HTTP/2). See record_to_body() /
# deposit_draft_curl() below.
# Author: M. Möller, 2026.  License: MIT.
# =============================================================================

library(zen4R)
library(jsonlite)

# Some inspecting proxies (e.g. the JKI genugate/squid relay) reject HTTP/2 with
# "'Connection: Upgrade' is not allowed for proxy requests", which shows up as a
# raw HTML 400 and the first request of every run failing. Forcing HTTP/1.1 for
# all libcurl requests avoids the HTTP/2 upgrade and lets the request body
# through. Harmless on networks without such a proxy. (http_version = 2 == 1.1)
httr::set_config(httr::config(http_version = 2))

# ---- Configuration (edit these) --------------------------------------------
SANDBOX  <- FALSE                                    # FALSE = real zenodo.org; a draft stays private/unpublished/deletable, so this is safe
TOKEN    <- Sys.getenv("ZENODO_TOKEN")               # PRODUCTION token from zenodo.org/account/settings/applications/tokens (scope: deposit:write); set via Sys.setenv(), not in this file
PKG_ROOT <- "/home/markus.moeller/PhenoPhaseR/output"   # where Hook C wrote the .zenodo.json (per crop, inside each ro_crate_* folder)
RESET    <- FALSE                                     # TRUE: delete previously-logged drafts, then recreate
if (!exists("THROTTLE_S")) THROTTLE_S <- 4            # seconds to pause between records; Zenodo rate-limits the
                                                     # (unauthenticated) vocabulary lookups at ~133/min, and each
                                                     # record makes ~10, so a big batch needs spacing. Lower to 0
                                                     # for a 1-2 crop run; raise if you still see HTTP 429.
if (!exists("CROPS")) CROPS <- NULL                   # session-overridable: set CROPS <- 204 (or c(204,205))
                                                     # BEFORE sourcing to deposit only those; NULL = every crop
                                                     # found under PKG_ROOT. It STAYS set until you change it or
                                                     # run rm(CROPS) / CROPS <- NULL.

# DFG FAIRagro funding. The award 501899475 is NOT in Zenodo's OpenAIRE awards
# vocabulary, so it is attached as a CUSTOM award (number + title) under the DFG
# funder, which IS in the ROR-sourced funders vocabulary (see attach_funding()).
# The funder id is resolved against Zenodo at run time; if it can't be resolved,
# funding is skipped with a warning (add it by hand in the browser). Set
# FUNDER_ROR <- NULL to skip funding entirely.
FUNDER_ROR   <- "018mejw64"      # Deutsche Forschungsgemeinschaft (DFG), ROR id
AWARD_NUMBER <- "501899475"      # FAIRagro DFG project number
AWARD_TITLE  <- "FAIRagro"       # free-text award title (custom award)

API_URL  <- if (SANDBOX) "https://sandbox.zenodo.org/api" else "https://zenodo.org/api"
BASE_URL <- sub("/api$", "", API_URL)
LOG_CSV  <- file.path(path.expand(PKG_ROOT), "zenodo_drafts.csv")

stopifnot(nzchar(TOKEN))
zenodo <- ZenodoManager$new(url = API_URL, token = TOKEN, logger = "INFO")

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# Retry helper for transient Zenodo infrastructure hiccups. Zenodo's proxy
# occasionally returns an HTML error page (504/502/503/400) instead of JSON,
# which zen4R reports as "lexical error: invalid char in json". Those are safe
# to retry; genuine metadata errors come back as proper JSON and are NOT caught
# here (so they still fail fast). Backoff: 3, 6, 12, 24 s.
with_retry <- function(fn, tries = 5, base_delay = 3, label = "") {
  transient <- "lexical error|invalid char in json|<html>|Gateway Time|Bad Gateway|Bad request|Service Unavailable|50[234]"
  for (i in seq_len(tries)) {
    res <- tryCatch(fn(), error = function(e) structure(list(err = e), class = "retry_err"))
    if (!inherits(res, "retry_err")) return(res)
    msg <- conditionMessage(res$err)
    if (i == tries || !grepl(transient, msg, ignore.case = TRUE)) stop(res$err)
    delay <- base_delay * 2^(i - 1)
    message(sprintf("  transient Zenodo error on %s (attempt %d/%d) - retrying in %ds ...",
                    label, i, tries, delay))
    Sys.sleep(delay)
  }
}

# zen4R deprecated addKeyword in favour of addSubject; use addSubject for
# free-text keywords, fall back to addKeyword only if that fails.
add_one_keyword <- function(rec, k) {
  ok <- tryCatch({ rec$addSubject(subject = k); TRUE }, error = function(e) FALSE)
  if (!ok) tryCatch(rec$addKeyword(k),
                    error = function(e) warning("keyword '", k, "' not added (check addSubject/addKeyword)"))
}

# ---- Deposit transport ------------------------------------------------------
# zen4R builds/validates the record, but its httr POST does not survive the JKI
# inspecting proxy (the draft is created empty). A direct libcurl POST of the
# same body DOES get through (verified over both HTTP/1.1 and HTTP/2). So we
# serialize the record with zen4R's own logic and send it via libcurl.

# zen4R ZenodoRequest$prepareData, reproduced: turns a ZenodoRecord into the
# exact InvenioRDM JSON body zen4R would POST.
record_to_body <- function(record) {
  data <- as.list(record); data[[".__enclos_env__"]] <- NULL
  for (p in names(data)) if (is(data[[p]], "function")) data[[p]] <- NULL
  if (!is.null(data[["submitted"]])) if (!data[["submitted"]]) data[["submitted"]] <- NULL
  if (length(data[["files"]]) == 0)    data[["files"]] <- NULL
  if (length(data[["metadata"]]) == 0) data[["metadata"]] <- NULL
  data[["links"]] <- NULL; data[["verbose.info"]] <- NULL
  data[["verbose.debug"]] <- NULL; data[["loggerType"]] <- NULL
  data <- data[!vapply(data, is.null, logical(1))]
  as.character(jsonlite::toJSON(data, pretty = TRUE, auto_unbox = TRUE))
}

# POST the body to <api>/records via libcurl; returns the created draft id.
# Raises on non-2xx (so genuine metadata errors surface instead of a silent
# empty draft), and warns if the created draft comes back without a title.
deposit_draft_curl <- function(body, token, api_url) {
  h <- curl::new_handle()
  curl::handle_setopt(h, http_version = 2,            # 2 == force HTTP/1.1
                      customrequest = "POST", postfields = body)
  curl::handle_setheaders(h, "Authorization" = paste("Bearer", token),
                             "Content-Type" = "application/json",
                             "Accept" = "application/json")
  r   <- curl::curl_fetch_memory(paste0(api_url, "/records"), handle = h)
  txt <- rawToChar(r$content)
  if (!(r$status_code %in% c(200, 201)))
    stop(sprintf("HTTP %s from Zenodo: %s", r$status_code,
                 substr(gsub("\\s+", " ", txt), 1, 300)))
  id <- sub('.*?"id":\\s*"?([0-9]+).*', "\\1", txt)
  if (!grepl('"metadata"', txt) || grepl('"title":\\s*""', txt))
    warning("draft ", id, " was created but its stored title looks empty")
  id
}

# ---- Funding: DFG funder (from ROR vocab) + FAIRagro custom award -----------
# zen4R's addGrant can only attach awards that exist in Zenodo's awards
# vocabulary; the FAIRagro award isn't one. InvenioRDM accepts a custom award
# (number + optional title) under a funder that IS in the funders vocabulary, so
# we resolve the DFG funder and attach the award directly to the record.
attach_funding <- function(rec) {
  if (is.null(FUNDER_ROR) || !nzchar(FUNDER_ROR)) return(invisible())
  zen <- ZenodoManager$new()                              # public funders vocab, no token needed
  f   <- tryCatch(zen$getFunderById(utils::URLencode(FUNDER_ROR)), error = function(e) NULL)
  fid <- if (!is.null(f) && !inherits(f, "ZenodoException") && !is.null(f$id)) {
    f$id                                                  # resolved cleanly against the vocabulary
  } else {
    # The lookup failed. The usual cause is Zenodo rate-limiting (HTTP 429) on a
    # big batch, NOT a bad ROR. FUNDER_ROR is user-supplied and (for this run)
    # already validated on other records, so attach it by ROR rather than
    # silently dropping funding. If the ROR really were invalid, the deposit
    # would fail loudly with a 4xx in deposit_draft_curl - not a silent gap.
    message("  (funder lookup for ", FUNDER_ROR, " failed - attaching by ROR anyway)")
    FUNDER_ROR
  }
  award <- list(number = AWARD_NUMBER)
  if (!is.null(AWARD_TITLE) && nzchar(AWARD_TITLE)) award$title <- list(en = AWARD_TITLE)
  rec$metadata$funding <- c(rec$metadata$funding %||% list(),
                            list(list(funder = list(id = fid), award = award)))
}

# ---- Map one .zenodo.json into a (local) ZenodoRecord -----------------------
record_from_zenodo_json <- function(path) {
  m   <- jsonlite::read_json(path, simplifyVector = FALSE)
  rec <- ZenodoRecord$new()

  rec$setTitle(m$title)
  rec$setDescription(m$description)                  # HTML accepted
  if (!is.null(m$version)) rec$setVersion(m$version)
  rec$setResourceType(m$upload_type)                 # "dataset" (new API; replaces setUploadType)
  rec$setLicense(m$license)                          # "cc-by-4.0"

  for (c in m$creators) {                            # names are "Last, First"
    parts <- strsplit(c$name, ",\\s*")[[1]]
    rec$addCreator(
      lastname     = parts[1],
      firstname    = if (length(parts) > 1) parts[2] else NULL,
      orcid        = c$orcid %||% NULL,
      affiliations = c$affiliation_ror %||% c$affiliation %||% NULL   # ROR id -> resolved, linked affiliation (correct plural arg)
    )
  }

  for (k in m$keywords) add_one_keyword(rec, k)

  # AGROVOC subjects (written by hook_zenodo_metadata.R). zen4R 0.10.3's
  # addSubject(subject) takes free text only (no URI argument), so the AGROVOC
  # label is added as a subject and the concept URI stays in the RO-Crate.
  for (s in (m$subjects %||% list())) {
    lab <- s$label %||% s$subject %||% NULL
    if (is.null(lab)) next
    add_one_keyword(rec, lab)                        # addSubject(subject=lab); keyword fallback
  }

  for (ri in m$related_identifiers)                  # software/dataset/family-concept DOIs
    rec$addRelatedIdentifier(relation = tolower(ri$relation),   # Zenodo relation vocab is lowercase (iscompiledby, isderivedfrom, ...)
                             identifier = ri$identifier, scheme = "doi",
                             resource_type = ri$resource_type %||% NULL)   # "software"/"dataset" — resolved & attached per related work

  attach_funding(rec)                               # DFG FAIRagro as a custom award (see FUNDER_ROR/AWARD_* config)

  # NOTE: community submission ("jki") is intentionally omitted — on the new
  # platform adding a draft to a community is a *review request* to the manager.
  # If you want it, after depositRecord() call:
  #   zenodo$createReviewRequest(rec, "jki"); zenodo$submitRecordForReview(rec)

  rec
}

# ---- Running log (cumulative across runs) + optional reset ------------------
# The log is a plain CSV that older runs / manual edits may have left with a
# stray index column or otherwise odd shape. Normalise to exactly these four
# columns so the merge (rbind) below never fails on a column-count mismatch.
LOG_COLS  <- c("crop_id", "kind", "record_id", "draft_url")
empty_log <- data.frame(crop_id = character(), kind = character(),
                        record_id = character(), draft_url = character(),
                        stringsAsFactors = FALSE)
done <- empty_log
if (file.exists(LOG_CSV)) {
  raw <- tryCatch(utils::read.csv(LOG_CSV, colClasses = "character"),
                  error = function(e) empty_log)
  if (all(LOG_COLS %in% names(raw))) {
    done <- raw[, LOG_COLS, drop = FALSE]              # keep the 4 canonical cols, drop any extras
  } else if (ncol(raw) > 0) {
    message("note: existing log has unexpected columns (", paste(names(raw), collapse = ", "),
            ") - starting a fresh log this run")
  }
}

if (RESET && nrow(done) > 0) {                       # delete the logged drafts, then start fresh
  for (id in done$record_id) {
    message("RESET: deleting draft ", id)
    tryCatch(zenodo$deleteRecord(id), error = function(e) message("  (already gone: ", id, ")"))
  }
  done <- done[0, ]
}

# ---- Find every .zenodo.json (layout-agnostic) -----------------------------
# Matches the two known filenames anywhere under PKG_ROOT, so this works with
# BOTH the hook output (output/<id>/ro_crate_*/) and the package layout
# (<id>_<slug>/{filter-variants,phase}/). Point PKG_ROOT at either.
files <- list.files(path.expand(PKG_ROOT), recursive = TRUE, full.names = TRUE,
                    pattern = "^(filtervariants|phase)\\.zenodo\\.json$")
if (!is.null(CROPS)) {                               # keep only the requested crop(s)
  want  <- as.character(CROPS)
  files <- files[vapply(files, function(f) sub(".*?([0-9]{3}).*", "\\1", f) %in% want, logical(1))]
}
if (length(files) == 0)
  stop("no matching .zenodo.json under ", PKG_ROOT,
       if (!is.null(CROPS)) paste0(" for CROPS = ", paste(CROPS, collapse = ", ")) else "")
rows <- list()

for (json in files) {
  kind   <- if (grepl("filtervariants\\.zenodo\\.json$", json)) "filter" else "phase"
  dwd_id <- sub(".*?([0-9]{3}).*", "\\1", json)      # nearest 3-digit id in the path

  # Idempotency: skip a crop already in the log (unless RESET cleared it above),
  # so re-running push deposits only NEW crops instead of duplicating old ones.
  if (any(done$crop_id == dwd_id & done$kind == kind)) {
    prev <- done$record_id[done$crop_id == dwd_id & done$kind == kind][1]
    message(sprintf("=== %s / %s === already deposited (draft %s) - skipping", dwd_id, kind, prev))
    next
  }

  message(sprintf("\n=== %s / %s ===", dwd_id, kind))
  rec <- with_retry(function() record_from_zenodo_json(json),   # vocab fetches happen here; safe to retry
                    label = sprintf("%s/%s", dwd_id, kind))
  body <- record_to_body(rec)                                   # zen4R's own serialization
  id   <- with_retry(function() deposit_draft_curl(body, TOKEN, API_URL),  # direct libcurl POST (survives the proxy)
                     label = sprintf("%s/%s deposit", dwd_id, kind))

  url <- paste0(BASE_URL, "/uploads/", id)
  message("  draft: ", url)
  rows[[length(rows) + 1]] <- data.frame(
    crop_id = dwd_id, kind = kind, record_id = id, draft_url = url,
    stringsAsFactors = FALSE)

  if (THROTTLE_S > 0) Sys.sleep(THROTTLE_S)          # space out the next record's vocab lookups (avoid HTTP 429)
}

# ---- Log + summary (append this run's new drafts to the running log) --------
new_rows <- if (length(rows)) do.call(rbind, rows)[, LOG_COLS, drop = FALSE] else empty_log
log_df   <- rbind(done, new_rows)
utils::write.csv(log_df, LOG_CSV, row.names = FALSE)
message(sprintf("\n%d new draft(s) this run; %d in the log total. Log: %s",
                nrow(new_rows), nrow(log_df), LOG_CSV))
if (nrow(new_rows) == 0) {
  message("(nothing new: every .zenodo.json under PKG_ROOT is already in the log. ",
          "Set RESET <- TRUE to delete and recreate.)")
} else {
  message("Next: open each NEW draft URL, upload your data files, then click Publish.")
  print(new_rows[, c("crop_id", "kind", "draft_url")])
}
