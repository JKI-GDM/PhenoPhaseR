#!/usr/bin/env Rscript
## Appendix figure -- Out-of-sample interpolation accuracy by phenological
## phase for all eight crops (one panel per crop), from the per-crop VAM
## tables. Colours identify Phase IDs consistently across panels and follow
## the PhenoWin phase colour scheme, darkened for line legibility; the
## thickened line marks each crop's most accurately interpolated phase
## (lowest median MAE).
##
## Expects <DATA_DIR>/<PLANT>/VAM_<PLANT>-<phase>.csv
## (semicolon-separated, decimal comma). Output: <OUT>.png / <OUT>.pdf

library(ggplot2)

## Root of the per-crop pipeline output folders; the VAM tables are found
## by recursive search below <DATA_ROOT>/<PLANT>/, so their exact subfolder
## (e.g. ro_crate_phase/vam/) does not matter.
DATA_ROOT <- "~/PhenoPhaseR/output"
OUT      <- "Figure_FamilyAccuracy_perCrop"

crops <- c(`202` = "Winter wheat",    `203` = "Winter rye",
           `204` = "Winter barley",   `205` = "Winter rapeseed",
           `207` = "Spring barley",   `208` = "Oats",
           `215` = "Maize",           `253` = "Sugar beet")
## Phase colours: PhenoWin phase colour scheme (Phases.csv; Moeller et al. 2020,
## doi:10.1016/j.compag.2020.105534), darkened for line legibility by mixing
## each colour toward #262626 with fraction f = min(0.5, max(0, (L-0.60)*1.35)),
## L = relative luminance. Native scheme hexes in the trailing comments.
## Phases 13, 66 and 67 share one native colour (99C693) and never co-occur
## within a panel.
phase_cols <- c(`5`  = "#9A995B",  # FFFE89 flowering
                `6`  = "#ACAB0F",  # FFFE00
                `10` = "#3288BD",  # 3288BD sowing
                `12` = "#8F988E",  # E5F4E3 emergence
                `13` = "#89B084",  # 99C693 closed stand
                `14` = "#8FA78C",  # C4E7BF 4th leaf
                `15` = "#8AB085",  # ABDDA4 shooting
                `17` = "#7DB2A2",  # 93D4C0 bud formation
                `18` = "#63BA9E",  # 66C2A5 heading
                `19` = "#A09579",  # FEECB9 milk ripening
                `20` = "#AE9B65",  # FEE08B early dough
                `21` = "#D49456",  # FDAE61 yellow ripening
                `22` = "#D3945A",  # FDAE67 full ripening
                `24` = "#F46D43",  # F46D43 harvest
                `65` = "#519B84",  # 519B84 tassel emergence
                `66` = "#89B084",  # 99C693 panicle emergence
                `67` = "#89B084")  # 99C693 stem elongation

vam_files <- function(plant) {
  root <- file.path(path.expand(DATA_ROOT), plant)
  hits <- list.files(root, pattern = sprintf("^VAM_%s-\\d+\\.csv$", plant),
                     recursive = TRUE, full.names = TRUE)
  if (!length(hits)) stop("no VAM tables found under ", root, call. = FALSE)
  dup <- duplicated(basename(hits))
  if (any(dup)) stop("duplicate VAM tables under ", root, ": ",
                     paste(basename(hits)[dup], collapse = ", "),
                     call. = FALSE)
  hits
}

dat <- do.call(rbind, lapply(names(crops), function(pl)
  do.call(rbind, lapply(vam_files(pl), read.csv2,
                        stringsAsFactors = FALSE))))
stopifnot(all(as.character(dat$PLANT) %in% names(crops)),
          all(as.character(dat$PHASE) %in% names(phase_cols)))

## crop facet labels in Plant-ID order
dat$crop <- factor(sprintf("%s (%d)", crops[as.character(dat$PLANT)], dat$PLANT),
                   levels = sprintf("%s (%s)", crops, names(crops)))

## most accurately interpolated phase per crop (lowest median MAE)
med  <- aggregate(MAE ~ PLANT + PHASE, dat, median)
best <- vapply(split(med, med$PLANT),
               function(d) d$PHASE[which.min(d$MAE)], numeric(1))
dat$lw <- ifelse(dat$PHASE == best[as.character(dat$PLANT)], 1.25, 0.42)

p <- ggplot(dat, aes(YEAR, MAE, colour = factor(PHASE), linewidth = I(lw),
                     group = PHASE)) +
  geom_line() +
  facet_wrap(~ crop, nrow = 2) +
  scale_colour_manual("Phase ID",
                      values = phase_cols[order(as.integer(names(phase_cols)))],
                      breaks = sort(as.integer(names(phase_cols)))) +
  guides(colour = guide_legend(nrow = 1,
                               override.aes = list(linewidth = 1.3))) +
  scale_x_continuous("Year", breaks = seq(1995, 2025, 10),
                     limits = c(1992, 2026), expand = expansion(mult = 0.01)) +
  scale_y_continuous("Out-of-sample MAE (days)", limits = c(1.5, 13),
                     breaks = seq(2, 12, 2)) +
  theme_bw(base_size = 11.5) +
  theme(panel.grid = element_blank(),
        strip.background = element_blank(),
        strip.text = element_text(size = 11),
        legend.position = "bottom",
        legend.margin = margin(t = 0))

ggsave(paste0(OUT, ".png"), p, width = 13.2, height = 6.6, dpi = 300)
ggsave(paste0(OUT, ".pdf"), p, width = 13.2, height = 6.6, device = cairo_pdf)
cat("wrote", paste0(OUT, c(".png", ".pdf"), collapse = " / "), "\n")
