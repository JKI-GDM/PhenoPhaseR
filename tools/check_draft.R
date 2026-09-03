# =============================================================================
# check_draft.R  —  the deciding test.
#
# (A) prints the EXACT JSON body zen4R will POST for your phase file (built on
#     YOUR machine), and
# (B) reads the two drafts you just created straight back from Zenodo and shows
#     what Zenodo actually STORED for them.
#
# It creates no new drafts and deposits nothing. Just run and send me the output:
#     source("~/PhenoPhaseR/tools/check_draft.R")
# =============================================================================

suppressMessages({ library(zen4R); library(jsonlite) })

PKG_ROOT <- "/home/markus.moeller/PhenoPhaseR/output"   # <-- same as your push script
TOKEN    <- Sys.getenv("ZENODO_TOKEN")
API_URL  <- "https://zenodo.org/api"
stopifnot(nzchar(TOKEN))

`%||%` <- function(a, b)
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# ---- exact copy of zen4R 0.10.3 ZenodoRequest$prepareData -------------------
# (so we see EXACTLY what would be POSTed, without touching the network)
prepareData <- function(data){
  if (is(data, "ZenodoRecord")) {
    data <- as.list(data); data[[".__enclos_env__"]] <- NULL
    for (p in names(data)) if (is(data[[p]], "function")) data[[p]] <- NULL
    if (!is.null(data[["submitted"]])) if (!data[["submitted"]]) data[["submitted"]] <- NULL
    if (length(data[["files"]]) == 0)    data[["files"]] <- NULL
    if (length(data[["metadata"]]) == 0) data[["metadata"]] <- NULL
    data[["links"]] <- NULL; data[["verbose.info"]] <- NULL
    data[["verbose.debug"]] <- NULL; data[["loggerType"]] <- NULL
    data <- data[!sapply(data, is.null)]
  }
  as(toJSON(data, pretty = TRUE, auto_unbox = TRUE), "character")
}

# ---- (A) build the phase record and show the body that WOULD be sent --------
f <- list.files(path.expand(PKG_ROOT), recursive = TRUE, full.names = TRUE,
                pattern = "^phase\\.zenodo\\.json$")[1]
cat("### (A) BODY zen4R WOULD POST — built from", f, "###\n")
m <- jsonlite::read_json(f, simplifyVector = FALSE)
rec <- ZenodoRecord$new()
if (!is.null(m$title))       rec$setTitle(m$title)
if (!is.null(m$description)) rec$setDescription(m$description)
if (!is.null(m$version))     rec$setVersion(m$version)
if (!is.null(m$upload_type)) rec$setResourceType(m$upload_type)
if (!is.null(m$license))     rec$setLicense(m$license)
for (c in m$creators) {
  parts <- strsplit(c$name, ",\\s*")[[1]]
  rec$addCreator(lastname = parts[1], firstname = if (length(parts) > 1) parts[2] else NULL,
                 orcid = c$orcid %||% NULL,
                 affiliations = c$affiliation_ror %||% c$affiliation %||% NULL)
}
body <- prepareData(rec)
cat("body length          :", nchar(body), "chars\n")
cat("body has \"metadata\"   :", grepl('"metadata"', body), "\n")
cat("body has the title    :", grepl(rec$metadata$title %||% "ZZZ", body, fixed = TRUE), "\n")
cat("---- first 900 chars of the exact body ----\n", substr(body, 1, 900), "\n...\n\n", sep = "")

# ---- (B) read the drafts you just created straight back from Zenodo ---------
cat("### (B) WHAT ZENODO STORED for the drafts you just created ###\n")
logf <- file.path(path.expand(PKG_ROOT), "zenodo_drafts.csv")
if (!file.exists(logf)) stop("no zenodo_drafts.csv — run push_zenodo_metadata.R first")
log <- utils::read.csv(logf, colClasses = "character")
if (exists("CROPS") && !is.null(CROPS))              # if set (e.g. per-crop push), verify only those
  log <- log[log$crop_id %in% as.character(CROPS), , drop = FALSE]
if (nrow(log) == 0) stop("no logged drafts to check",
                         if (exists("CROPS") && !is.null(CROPS)) paste0(" for CROPS = ", paste(CROPS, collapse = ", ")) else "")
zenodo <- ZenodoManager$new(url = API_URL, token = TOKEN, logger = "INFO")

for (i in seq_len(nrow(log))) {
  id <- as.character(log$record_id[i])
  cat("\n-- draft", id, "(", log$kind[i], ") --\n")
  rec2 <- tryCatch(zenodo$getDepositionById(id),
                   error = function(e) { cat("   fetch error:", conditionMessage(e), "\n"); NULL })
  if (is.null(rec2) || !inherits(rec2, "ZenodoRecord")) { cat("   (could not read this draft back)\n"); next }
  md <- rec2$metadata %||% list()
  cat("   stored keys     :", paste(names(md), collapse = ", ") %||% "<none>", "\n")
  cat("   stored title    :", md$title %||% "<<<<<< EMPTY — Zenodo stored NO metadata >>>>>>", "\n")
  cat("   stored creators :", length(md$creators %||% list()),
      "| subjects:", length(md$subjects %||% list()),
      "| related:", length(md$related_identifiers %||% list()), "\n")
  # related works: is each one's resource type set?
  for (ri in (md$related_identifiers %||% list()))
    cat(sprintf("     - %-14s %-24s type: %s\n",
                ri$relation_type$id %||% "?", ri$identifier %||% "?",
                ri$resource_type$id %||% "<<not set>>"))
  # funding
  fund <- md$funding %||% list()
  if (length(fund) == 0) cat("   funding         : <<none>>\n")
  else for (fw in fund)
    cat(sprintf("   funding         : funder %s | award %s %s\n",
                fw$funder$id %||% "?",
                fw$award$number %||% (fw$award$id %||% "?"),
                if (!is.null(fw$award$title)) paste0("(", fw$award$title$en %||% "", ")") else ""))
}

cat("\n### READ THIS ###\n")
cat("If (A) shows a body WITH metadata but (B) shows the drafts stored EMPTY, then\n",
    "zen4R's POST is reaching Zenodo without the body intact — most likely something\n",
    "in the network path (e.g. a JKI proxy). The consistent 'transient error on\n",
    "attempt 1' each run points the same way. Send me this whole output.\n", sep = "")
cat("If (B) shows the metadata IS stored, the drafts are not actually empty — open\n",
    "the exact URLs from the log and check the 'Metadata' section there.\n", sep = "")
