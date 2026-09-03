#!/usr/bin/env Rscript
## Figure 4 -- Quantitative characterisation of the winter wheat (202) dataset:
## (a) out-of-sample MAE per phase and year          [VAM_202-<phase>.csv]
## (b) heading: station observations vs. MAE         [VAM_202-18.csv, ON + MAE]
## (c) heading: per-pixel BSE median and 25-75 %     [GEM_202-18.csv]
## (d) heading: PICP calibration and MPIW            [PIC_202-18.csv]
##
## Expects <DATA_DIR>/<PLANT>/ with the per-phase VAM/GEM/PIC tables
## (semicolon-separated, decimal comma). Output: <OUT>.png / <OUT>.pdf

library(ggplot2)
library(patchwork)

## Root of the per-crop pipeline output folders; the quality tables are
## found by recursive search below <DATA_ROOT>/<PLANT>/, so their exact
## subfolder (e.g. ro_crate_phase/vam/) does not matter.
DATA_ROOT <- "~/PhenoPhaseR/output"
PLANT     <- 202
FOCUS    <- 18                # heading
OUT      <- "Figure_WinterWheat_Accuracy_Uncertainty"

phase_names <- c(`10` = "Sowing",        `12` = "Emergence",
                 `15` = "Shooting",      `18` = "Heading",
                 `19` = "Milk ripening", `21` = "Yellow ripening",
                 `24` = "Harvest")
## Phase colours: PhenoWin phase colour scheme (Phases.csv; Moeller et al. 2020,
## doi:10.1016/j.compag.2020.105534), darkened for line legibility by mixing
## each colour toward #262626 with fraction f = min(0.5, max(0, (L-0.60)*1.35)),
## L = relative luminance. Native scheme hexes in the trailing comments.
phase_cols  <- c(`10` = "#3288BD",  # 3288BD sowing
                 `12` = "#8F988E",  # E5F4E3 emergence
                 `15` = "#8AB085",  # ABDDA4 shooting
                 `18` = "#63BA9E",  # 66C2A5 heading
                 `19` = "#A09579",  # FEECB9 milk ripening
                 `21` = "#D49456",  # FDAE61 yellow ripening
                 `24` = "#F46D43")  # F46D43 harvest

BLUE  <- "#1f4e9c"   # station counts, PICP, BSE median
RED   <- "#c0392b"   # MAE on the secondary axis of (b)
GREEN <- "#1e8449"   # nominal-coverage annotations

locate <- function(plant, filename) {
  root <- file.path(path.expand(DATA_ROOT), plant)
  hits <- list.files(root, pattern = paste0("^", filename, "$"),
                     recursive = TRUE, full.names = TRUE)
  if (length(hits) != 1L)
    stop(sprintf("expected exactly one '%s' under %s, found %d",
                 filename, root, length(hits)), call. = FALSE)
  hits
}
read_q <- function(...) read.csv2(locate(PLANT, sprintf(...)),
                                  stringsAsFactors = FALSE)

theme_panel <- theme_bw(base_size = 11.5) +
  theme(panel.grid = element_blank(),
        plot.title = element_text(size = 12, margin = margin(b = 4)),
        legend.background = element_blank(),
        legend.key = element_blank())

x_years <- scale_x_continuous("Year", breaks = seq(1995, 2025, 5),
                              expand = expansion(mult = 0.02))

## ---------------------------------------------------------------- panel (a)
vam <- do.call(rbind, lapply(names(phase_names), function(ph)
  read_q("VAM_%d-%s.csv", PLANT, ph)))
stopifnot(all(vam$PLANT == PLANT))
vam$lab <- factor(sprintf("%d \u00b7 %s", vam$PHASE, phase_names[as.character(vam$PHASE)]),
                  levels = sprintf("%s \u00b7 %s", names(phase_names), phase_names))

p_a <- ggplot(vam, aes(YEAR, MAE, colour = lab,
                       linewidth = I(ifelse(PHASE == FOCUS, 1.4, 0.55)))) +
  geom_line() +
  scale_colour_manual(NULL, values = setNames(phase_cols, levels(vam$lab))) +
  guides(colour = guide_legend(ncol = 2, override.aes = list(linewidth = 1.2))) +
  scale_y_continuous("Out-of-sample MAE (days)", limits = c(2, 10.4),
                     breaks = seq(2, 10, 2)) +
  x_years +
  ggtitle("(a) Interpolation accuracy by phenological phase") +
  theme_panel +
  theme(legend.position = c(0.02, 1.00), legend.justification = c(0, 1),
        legend.text = element_text(size = 9), legend.key.height = unit(11, "pt"))

## ---------------------------------------------------------------- panel (b)
hd <- vam[vam$PHASE == FOCUS, ]
k  <- 1200 / 8   # MAE (0-8 d) drawn in the station-count space (0-1200)

p_b <- ggplot(hd, aes(YEAR)) +
  geom_area(aes(y = ON), fill = "#b8c2d8", alpha = 0.5) +
  geom_line(aes(y = ON), colour = BLUE, linewidth = 0.9) +
  geom_line(aes(y = MAE * k), colour = RED, linewidth = 1.1) +
  scale_y_continuous(expression(paste("Station observations ", italic(n))),
                     limits = c(0, 1200), breaks = seq(0, 1200, 200),
                     sec.axis = sec_axis(~ . / k, name = "MAE (days)",
                                         breaks = 0:8)) +
  x_years +
  ggtitle("(b) Heading: network decline vs. stable accuracy") +
  theme_panel +
  theme(axis.title.y.left  = element_text(colour = BLUE),
        axis.text.y.left   = element_text(colour = BLUE),
        axis.title.y.right = element_text(colour = RED),
        axis.text.y.right  = element_text(colour = RED))

## ---------------------------------------------------------------- panel (c)
gem <- read_q("GEM_%d-%s.csv", PLANT, FOCUS)
w   <- data.frame(YEAR = sort(unique(gem$YEAR)))
for (p in c("25%", "50%", "75%"))
  w[[paste0("q", sub("%", "", p))]] <-
    gem$Value[gem$Quantile == p][match(w$YEAR, gem$YEAR[gem$Quantile == p])]
stopifnot(!anyNA(w))

p_c <- ggplot(w, aes(YEAR)) +
  geom_ribbon(aes(ymin = q25, ymax = q75, fill = "25\u201375 % of pixels"),
              alpha = 0.65) +
  geom_line(aes(y = q50, colour = "median"), linewidth = 1) +
  scale_fill_manual(NULL, values = c("25\u201375 % of pixels" = "#b9c4dd")) +
  scale_colour_manual(NULL, values = c(median = "#1f3f7a")) +
  guides(fill = guide_legend(order = 1), colour = guide_legend(order = 2)) +
  scale_y_continuous("BSE (days)", limits = c(0, 1.8),
                     breaks = seq(0, 1.75, 0.25)) +
  x_years +
  ggtitle("(c) Heading: per-pixel model uncertainty (BSE)") +
  theme_panel +
  theme(legend.position = c(0.02, 1.00), legend.justification = c(0, 1),
        legend.text = element_text(size = 9), legend.key.height = unit(11, "pt"),
        legend.spacing.y = unit(0, "pt"), legend.margin = margin(0, 0, 0, 0))

## ---------------------------------------------------------------- panel (d)
pic <- read_q("PIC_%d-%s.csv", PLANT, FOCUS)
stopifnot(all(pic$NOMINAL == 0.9))
k2 <- 0.08 / 45  # MPIW (0-45 d) drawn in the PICP space (0.86-0.94)

p_d <- ggplot(pic, aes(YEAR)) +
  annotate("rect", xmin = -Inf, xmax = Inf, ymin = 0.88, ymax = 0.92,
           fill = "#a9dfbf", alpha = 0.25) +
  geom_hline(yintercept = 0.9, linetype = "dashed", colour = GREEN) +
  annotate("text", x = 1993.5, y = 0.9033, label = "nominal 0.90",
           colour = GREEN, hjust = 0, size = 3.3) +
  geom_line(aes(y = 0.86 + MPIW * k2), colour = "grey30",
            linetype = "dotted", linewidth = 0.7) +
  geom_line(aes(y = PICP), colour = BLUE, linewidth = 0.9) +
  geom_point(aes(y = PICP), colour = BLUE, size = 1.4) +
  scale_y_continuous("PICP at 90 % nominal", limits = c(0.86, 0.94),
                     breaks = seq(0.86, 0.94, 0.02),
                     sec.axis = sec_axis(~ (. - 0.86) / k2, name = "MPIW (days)",
                                         breaks = seq(0, 45, 5))) +
  x_years +
  ggtitle("(d) Heading: uncertainty calibration") +
  theme_panel +
  theme(axis.title.y.left  = element_text(colour = BLUE),
        axis.text.y.left   = element_text(colour = BLUE),
        axis.title.y.right = element_text(colour = "grey30"),
        axis.text.y.right  = element_text(colour = "grey30"))

## ------------------------------------------------------------------ output
fig <- (p_a | p_b) / (p_c | p_d)
ggsave(paste0(OUT, ".png"), fig, width = 11, height = 8.2, dpi = 300)
ggsave(paste0(OUT, ".pdf"), fig, width = 11, height = 8.2, device = cairo_pdf)
cat("wrote", paste0(OUT, c(".png", ".pdf"), collapse = " / "), "\n")
