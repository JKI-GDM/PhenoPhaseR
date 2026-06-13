################################################################################
# Phenological Window Time-Series Visualisation
################################################################################
#
# PURPOSE:
#   Reads PHASE / PhenoPhaseR COGs (DOY + BSE) for a configurable set of
#   phenological phases and years, aggregates them to an area-of-interest
#   (AOI) polygon (e.g. the Uckermark Landkreis), and renders a single-panel
#   time-series figure showing for each phase:
#     - the AOI-mean starting DOY as line + points,
#     - a model-uncertainty ribbon of width sigma_factor * RMS(BSE),
#     - a linear trend line with regression annotation (slope, intercept,
#       R-squared, p value), reproducing the layout of Fig. 3 in
#       Krengel-Horney et al. (2021), JfK 73 (7-8): 292-305,
#       doi:10.5073/JfK.2021.07-08.14.
#   A translucent band between the two phase means visualises the
#   inter-phase phenological window.
#
#   Designed to be cartographically consistent with
#   plot_phenology_raster_maps(): identical sans-serif typography, identical
#   ESSD figure width (17.4 cm), and phase-line colours sampled from the
#   same viridis (or plasma) palette family as the DOY/BSE maps so both
#   figures read as a coordinated pair in the same publication.
#
# AUTHORS:
#   Markus Möller (ORCID: https://orcid.org/0000-0002-1918-7747)
#   Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#
# DEPENDENCIES:
#   - R >= 4.0.0
#   - terra          (raster I/O and reprojection)
#   - sf             (spatial data handling)
#   - ggplot2        (plotting)
#   - dplyr, tidyr, purrr, tibble  (data wrangling)
#   - scales         (axis label formatting)
#   - viridis        (palette sampling, only when phase_colours = NULL)
#   - geodata        (only when aoi is supplied as a character GADM name)
#
# ESSD FIGURE COMPLIANCE (https://www.earth-system-science-data.net/):
#   - Single sans-serif font family (Helvetica/Arial) throughout
#   - Output width: 17.4 cm (two-column); default height: 9 cm; 300 dpi
#   - Coordinate axis labels: integer year ticks, integer DOY ticks
#   - CVD-friendly colour schemes (viridis / plasma family by default)
#   - Minimal non-data ink (white background, light dashed grid)
#
# VERSION HISTORY:
#   v1.0.0 (2026-05-03): Initial release - function adaptation of the
#                         phenowindow_uckermark_timeseries.R script with
#                         cartographic alignment to plot_phenology_raster_maps().
#
# LICENSE:
#   This code is provided under the MIT License.
#
################################################################################

# ==============================================================================
# FUNCTION DOCUMENTATION
# ==============================================================================
#
# plot_phenology_window_timeseries()
#
# ARGUMENTS:
#   pheno_dir (character):
#     Directory containing PHASE / PhenoPhaseR COGs. Two file layouts are
#     auto-detected:
#       (a) one file per (kind, phase, year):
#             DOY_<crop>-<phase>_<year>.tif    e.g. DOY_202-15_2005.tif
#             BSE_<crop>-<phase>_<year>.tif    e.g. BSE_202-15_2005.tif
#       (b) one multi-band file per (kind, phase), band = year - year_offset:
#             DOY_<crop>-<phase>.tif           e.g. DOY_202-15.tif
#             BSE_<crop>-<phase>.tif           e.g. BSE_202-15.tif
#
#   aoi (sf or character):
#     Area of interest over which DOY / BSE rasters are aggregated.
#     - sf object: any polygon/multipolygon feature in any CRS; reprojected
#       internally.
#     - character: a German Landkreis (NUTS-3) name. The polygon is fetched
#       from GADM level 2 via the 'geodata' package (cached in cache_dir).
#       Example: aoi = "Uckermark".
#
#   plant (numeric or character):
#     Crop identifier matching the COG filenames (e.g., 202 for winter
#     wheat in the DWD/JKI PhenoPhaseR coding).
#
#   crop_label (character or NULL; default = NULL):
#     Display name for the crop, used in the figure title (e.g., "Winter
#     wheat"). If NULL, the numeric code is used.
#
#   phases (named character; default = c("15" = "shooting", "18" = "heading")):
#     Named vector mapping numeric phase IDs (as character keys, since they
#     are used in COG filenames) to human-readable English labels. Two
#     phases are assumed for the inter-phase window band; passing only one
#     phase suppresses the band.
#
#   years (integer; default = 1993:2020):
#     Years to include in the time-series. Range matches Fig. 3 of
#     Krengel-Horney et al. (2021).
#
#   year_offset (integer; default = 1992L):
#     Offset used to map a year to a band index in multi-band PHASE COGs
#     (band = year - year_offset). Only used for layout (b).
#
#   sigma_factor (numeric; default = 1.0):
#     Multiplier of RMS(BSE) controlling the half-width of the model-
#     uncertainty ribbon. 1.0 corresponds to a ~68% pointwise CI under a
#     Gaussian assumption; 1.96 to ~95%.
#
#   phase_palette (character; default = "viridis"):
#     viridis palette option from which the per-phase line colours are
#     sampled when phase_colours is NULL. Pairing convention:
#       "viridis" -> visually aligned with DOY raster maps,
#       "plasma"  -> visually aligned with BSE raster maps.
#     Other valid options: "magma", "inferno", "cividis", "mako",
#     "rocket", "turbo".
#
#   phase_colours (character vector or NULL; default = NULL):
#     Optional explicit colours for the phase lines. Length must equal
#     length(phases). If NULL, length(phases) interior colours are
#     auto-sampled from phase_palette.
#
#   window_fill (character; default = "#a6d96a"):
#     Fill colour of the translucent inter-phase window band. Set to NA to
#     suppress the band even when two phases are passed.
#
#   na_colour (character; default = "white"):
#     Reserved for API symmetry with plot_phenology_raster_maps(); has no
#     effect on the time-series rendering.
#
#   output_dir (character or NULL; default = NULL):
#     Directory for saving the PNG figure.
#     File name: [plant]_[year_min]-[year_max]_DOY_window.png
#     Dimensions: 17.4 x 9.0 cm at 300 dpi (ESSD two-column width).
#     If NULL, the plot is printed to the active graphics device only.
#
#   fig_height (numeric; default = 9.0):
#     Figure height in centimetres. Width is fixed at 17.4 cm to match
#     plot_phenology_raster_maps().
#
#   cache_dir (character; default = "data/aoi"):
#     Directory used for caching GADM downloads when aoi is a character.
#
#   use_synth_fallback (logical; default = FALSE):
#     If TRUE and a required raster cannot be found, a reproducible
#     synthetic raster is generated from the regression coefficients of
#     Krengel-Horney et al. (2021) Fig. 3 (DOY) and a constant 5-day BSE.
#     Useful for dry-run testing; should be FALSE in production.
#
#   point_size (numeric; default = 1.6):
#     Size of the point markers, in mm.
#
# RETURNS:
#   A named list (invisibly):
#     $ts_tbl     : tibble of per-(phase, year) AOI summaries
#                   (n, mean_doy, sd_doy, mean_bse, rms_bse, p10, p90)
#     $trend_tbl  : tibble of per-phase linear-trend statistics
#                   (slope, intercept, r2, p_value)
#     $window_tbl : tibble of yearly start/end DOYs of the inter-phase
#                   window (NULL when only one phase is passed)
#     $aoi_sf     : sf object of the AOI in the analysis CRS (EPSG:25832)
#     $plot       : ggplot object (single panel, ready for export)
#
# ==============================================================================


# ==============================================================================
# DEPENDENCY LOADING
# ==============================================================================

ensure_packages <- function(pkg_list) {
  for (pkg in pkg_list) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      message("Installing package: ", pkg)
      install.packages(pkg, quiet = TRUE)
    }
    library(pkg, character.only = TRUE, quietly = TRUE)
  }
  message("All required packages loaded successfully!")
}

ensure_packages(c("terra", "sf", "ggplot2",
                  "dplyr", "tidyr", "purrr", "tibble",
                  "scales"))


# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

plot_phenology_window_timeseries <- function(
    pheno_dir,
    aoi,
    plant,
    crop_label         = NULL,
    phases             = c(`15` = "shooting", `18` = "heading"),
    years              = 1993:2020,
    year_offset        = 1992L,
    sigma_factor       = 1.0,
    phase_palette      = "viridis",
    phase_colours      = NULL,
    window_fill        = "#a6d96a",
    na_colour          = "white",
    output_dir         = NULL,
    fig_height         = 9.0,
    cache_dir          = "data/aoi",
    use_synth_fallback = FALSE,
    point_size         = 1.6
) {

  # ---------------------------------------------------------------------------
  # INPUT VALIDATION
  # ---------------------------------------------------------------------------

  if (!dir.exists(pheno_dir))
    stop("pheno_dir not found: ", pheno_dir)
  if (!is.numeric(sigma_factor) || sigma_factor < 0)
    stop("sigma_factor must be a non-negative numeric.")
  if (!is.null(phase_colours) && length(phase_colours) != length(phases))
    stop("phase_colours must have the same length as phases.")
  valid_palettes <- c("viridis", "magma", "plasma", "inferno",
                      "cividis", "mako", "rocket", "turbo")
  if (!phase_palette %in% valid_palettes)
    stop("phase_palette must be one of: ",
         paste(valid_palettes, collapse = ", "))

  if (is.null(crop_label)) crop_label <- as.character(plant)

  message("=== Phenological Window Time-Series ===")

  # ---------------------------------------------------------------------------
  # STEP 1: AOI resolution (mirrors plot_phenology_raster_maps)
  #   Analysis CRS is EPSG:25832 (PhenoPhaseR native), which avoids
  #   resampling the DOY / BSE COGs on every read.
  # ---------------------------------------------------------------------------

  crs_target <- "EPSG:25832"

  if (inherits(aoi, "sf")) {
    message("Using user-supplied AOI sf object ...")
    aoi_sf <- aoi
  } else if (is.character(aoi) && length(aoi) == 1) {
    message("Fetching AOI '", aoi, "' from GADM level 2 ...")
    if (!requireNamespace("geodata", quietly = TRUE)) {
      message("Installing package: geodata")
      install.packages("geodata", quiet = TRUE)
    }
    dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
    cache_gpkg <- file.path(cache_dir, paste0(tolower(aoi), ".gpkg"))
    if (!file.exists(cache_gpkg)) {
      de2 <- geodata::gadm(country = "DEU", level = 2, path = cache_dir)
      de2 <- sf::st_as_sf(de2)
      hit <- de2[grepl(aoi, de2$NAME_2, ignore.case = TRUE), ]
      if (nrow(hit) == 0)
        stop("No GADM-level-2 unit matching '", aoi, "' found.")
      sf::st_write(hit, cache_gpkg, quiet = TRUE, append = FALSE)
    }
    aoi_sf <- sf::st_read(cache_gpkg, quiet = TRUE)
  } else {
    stop("'aoi' must be an sf object or a single character name.")
  }

  if (sf::st_crs(aoi_sf) != sf::st_crs(crs_target)) {
    aoi_sf <- sf::st_transform(aoi_sf, crs_target)
  }
  aoi_name <- if (is.character(aoi)) aoi
              else if ("NAME_2" %in% names(aoi_sf)) aoi_sf$NAME_2[1]
              else "AOI"
  message(sprintf("AOI: %s (%.0f km^2)", aoi_name,
                  as.numeric(sf::st_area(aoi_sf)) / 1e6))

  # ---------------------------------------------------------------------------
  # STEP 2: Internal helpers - COG path resolution and raster loading
  # ---------------------------------------------------------------------------

  .phase_path <- function(dir_pheno, crop, phase, year,
                          kind = c("DOY", "BSE"),
                          year_offset = 1992L) {
    kind  <- match.arg(kind)
    crop  <- as.integer(crop)
    phase <- as.integer(phase)
    year  <- as.integer(year)

    per_year_candidates <- c(
      sprintf("%s_%d-%d_%d.tif",  kind, crop, phase, year),
      sprintf("%s_%d_%d_%d.tif",  kind, crop, phase, year),
      sprintf("%s-%d-%d-%d.tif",  kind, crop, phase, year)
    )
    multi_band_candidates <- c(
      sprintf("%s_%d-%d.tif",     kind, crop, phase),
      sprintf("%s_%d_%d.tif",     kind, crop, phase),
      sprintf("%s-%d-%d.tif",     kind, crop, phase)
    )
    for (f in per_year_candidates) {
      p <- file.path(dir_pheno, f)
      if (file.exists(p)) return(list(path = p, band = 1L))
    }
    for (f in multi_band_candidates) {
      p <- file.path(dir_pheno, f)
      if (file.exists(p)) return(list(path = p,
                                      band = year - year_offset))
    }
    list(path = NA_character_, band = NA_integer_)
  }

  .make_synth <- function(aoi_sf, phase, year,
                          kind = c("DOY", "BSE"), res_m = 1000) {
    kind <- match.arg(kind)
    template <- terra::rast(terra::ext(terra::vect(aoi_sf)),
                            resolution = res_m,
                            crs = sf::st_crs(aoi_sf)$wkt)
    if (kind == "DOY") {
      mu <- switch(as.character(phase),
                   "15" = -0.292 * year + 736.75,
                   "18" = -0.554 * year + 1228.24,
                   NA_real_)
      sigma <- 4
    } else {
      mu <- 5; sigma <- 1
    }
    set.seed(year * 100 + as.integer(phase) +
             ifelse(kind == "BSE", 1L, 0L))
    vals <- rnorm(terra::ncell(template), mean = mu, sd = sigma)
    if (kind == "BSE") vals <- pmax(vals, 0.1)
    terra::values(template) <- vals
    terra::mask(template, terra::vect(aoi_sf))
  }

  .load_raster <- function(phase, year, kind) {
    hit <- .phase_path(pheno_dir, plant, phase, year,
                       kind = kind, year_offset = year_offset)
    if (!is.na(hit$path)) {
      r <- terra::rast(hit$path)
      if (terra::nlyr(r) > 1) {
        if (hit$band < 1L || hit$band > terra::nlyr(r)) {
          warning(sprintf("Year %d outside band range of %s (1..%d)",
                          year, basename(hit$path), terra::nlyr(r)))
          return(NULL)
        }
        r <- r[[hit$band]]
      }
      if (!terra::same.crs(r, sf::st_crs(aoi_sf)$wkt)) {
        r <- terra::project(r, sf::st_crs(aoi_sf)$wkt, method = "near")
      }
      terra::mask(terra::crop(r, terra::vect(aoi_sf)),
                  terra::vect(aoi_sf))
    } else if (isTRUE(use_synth_fallback)) {
      .make_synth(aoi_sf, phase, year, kind = kind)
    } else {
      stop("No matching ", kind, " raster for phase=", phase,
           ", year=", year, " under ", pheno_dir,
           ". Set use_synth_fallback = TRUE to dry-run.")
    }
  }

  .summarise <- function(r_doy, r_bse) {
    v <- terra::values(r_doy); v <- v[!is.na(v)]
    if (!length(v)) {
      return(tibble::tibble(n = 0L, mean_doy = NA_real_, sd_doy = NA_real_,
                            mean_bse = NA_real_, rms_bse = NA_real_,
                            p10 = NA_real_, p90 = NA_real_))
    }
    if (!is.null(r_bse)) {
      b <- terra::values(r_bse); b <- b[!is.na(b)]
    } else {
      b <- NA_real_
    }
    tibble::tibble(
      n        = length(v),
      mean_doy = mean(v),
      sd_doy   = stats::sd(v),
      mean_bse = if (all(is.na(b))) NA_real_ else mean(b),
      rms_bse  = if (all(is.na(b))) NA_real_ else sqrt(mean(b^2)),
      p10      = stats::quantile(v, 0.10, names = FALSE),
      p90      = stats::quantile(v, 0.90, names = FALSE)
    )
  }

  # ---------------------------------------------------------------------------
  # STEP 3: Build the time-series table (phase x year)
  # ---------------------------------------------------------------------------

  message("Loading COGs and aggregating to AOI ...")

  grid <- expand.grid(year  = years,
                      phase = as.integer(names(phases)),
                      KEEP.OUT.ATTRS   = FALSE,
                      stringsAsFactors = FALSE)

  ts_tbl <- purrr::pmap_dfr(grid, function(year, phase) {
    r_doy <- .load_raster(phase, year, "DOY")
    r_bse <- tryCatch(.load_raster(phase, year, "BSE"),
                      error = function(e) NULL)
    s <- .summarise(r_doy, r_bse)
    dplyr::bind_cols(tibble::tibble(year = year, phase = phase), s)
  }) |>
    dplyr::mutate(
      phase_label = factor(phases[as.character(phase)],
                           levels = unname(phases))
    )

  message(sprintf("  Aggregated %d (phase x year) combinations.",
                  nrow(ts_tbl)))

  # ---------------------------------------------------------------------------
  # STEP 4: Per-phase linear-trend statistics
  # ---------------------------------------------------------------------------

  trend_tbl <- ts_tbl |>
    dplyr::group_by(phase, phase_label) |>
    dplyr::group_modify(~{
      fit <- lm(mean_doy ~ year, data = .x)
      s   <- summary(fit)
      tibble::tibble(
        slope     = unname(coef(fit)[2]),
        intercept = unname(coef(fit)[1]),
        r2        = s$r.squared,
        p_value   = unname(s$coefficients[2, 4])
      )
    }) |>
    dplyr::ungroup()

  # ---------------------------------------------------------------------------
  # STEP 5: Inter-phase window band (only when two phases are supplied)
  # ---------------------------------------------------------------------------

  window_tbl <- if (length(phases) >= 2L) {
    ts_tbl |>
      dplyr::select(year, phase_label, mean_doy) |>
      tidyr::pivot_wider(names_from = phase_label,
                         values_from = mean_doy) |>
      dplyr::rename(doy_start = !!unname(phases)[1],
                    doy_end   = !!unname(phases)[2])
  } else {
    NULL
  }

  # ---------------------------------------------------------------------------
  # STEP 6: ESSD-compliant typography (identical to raster_maps function)
  # ---------------------------------------------------------------------------

  essd_font    <- "sans"
  sz_panel_ttl <- 9
  sz_subtitle  <- 8
  sz_axis_txt  <- 7.5
  sz_legend_t  <- 8
  sz_legend    <- 7.5
  sz_annot_ttl <- 10
  sz_annot_sub <- 8
  sz_geom_text <- sz_subtitle / .pt    # convert pt to mm for geom_text

  essd_theme <- theme_bw(base_family = essd_font,
                          base_size   = sz_axis_txt) +
    theme(
      panel.background  = element_rect(fill = "white", colour = NA),
      panel.border      = element_rect(colour = "black", linewidth = 0.4),
      panel.grid.major  = element_line(colour    = "grey85",
                                       linewidth = 0.25,
                                       linetype  = "dashed"),
      panel.grid.minor  = element_blank(),
      axis.text         = element_text(size   = sz_axis_txt,
                                       family = essd_font,
                                       colour = "black"),
      axis.title        = element_text(size   = sz_subtitle,
                                       family = essd_font,
                                       colour = "black"),
      axis.ticks        = element_line(colour = "black", linewidth = 0.3),
      axis.ticks.length = unit(1.5, "pt"),
      plot.title        = element_text(size   = sz_annot_ttl,
                                       family = essd_font,
                                       face   = "bold",
                                       hjust  = 0,
                                       margin = margin(b = 2, unit = "pt")),
      plot.subtitle     = element_text(size   = sz_annot_sub,
                                       family = essd_font,
                                       colour = "grey35",
                                       hjust  = 0,
                                       margin = margin(b = 3, unit = "pt")),
      plot.caption      = element_text(size   = sz_legend,
                                       family = essd_font,
                                       colour = "grey45",
                                       hjust  = 0,
                                       margin = margin(t = 4, unit = "pt")),
      legend.position   = "top",
      legend.title      = element_text(size = sz_legend_t,
                                       family = essd_font,
                                       face   = "bold"),
      legend.text       = element_text(size = sz_legend,
                                       family = essd_font),
      legend.background = element_rect(fill = "white", colour = NA),
      legend.margin     = margin(0, 2, 0, 2, unit = "pt"),
      plot.margin       = margin(4, 4, 4, 4, unit = "pt")
    )

  # ---------------------------------------------------------------------------
  # STEP 7: Phase colours - sample from the same palette family as the maps
  #   Sampling at interior positions (dropping the extremes) yields readable
  #   colours that visually pair with the DOY/BSE raster panels.
  # ---------------------------------------------------------------------------

  if (is.null(phase_colours)) {
    if (!requireNamespace("viridis", quietly = TRUE)) {
      message("Installing package: viridis")
      install.packages("viridis", quiet = TRUE)
    }
    n_p <- length(phases)
    phase_colours <- viridis::viridis(n_p + 2,
                                      option    = phase_palette,
                                      direction = -1)[seq(2, n_p + 1)]
  }
  names(phase_colours) <- unname(phases)

  # ---------------------------------------------------------------------------
  # STEP 8: Regression-annotation strings (Krengel et al. 2021 Fig. 3 style)
  # ---------------------------------------------------------------------------

  # place annotations stacked in the upper-left corner
  doy_range <- range(ts_tbl$mean_doy, na.rm = TRUE)
  ann_y_top <- doy_range[2] + 0.10 * diff(doy_range)
  ann_step  <- 0.07 * diff(doy_range)

  ann <- trend_tbl |>
    dplyr::arrange(phase) |>
    dplyr::mutate(
      label = sprintf(
        "%s:  y = %.3f x + %.2f   R\u00b2 = %.2f,  p = %s",
        phase_label, slope, intercept, r2,
        ifelse(p_value < 1e-3, "<0.001", sprintf("%.3f", p_value))
      ),
      x = min(years),
      y = ann_y_top - (dplyr::row_number() - 1) * ann_step
    )

  # ---------------------------------------------------------------------------
  # STEP 9: Build the figure
  # ---------------------------------------------------------------------------

  message("Building figure ...")

  p <- ggplot(ts_tbl, aes(x = year, y = mean_doy,
                          colour = phase_label, fill = phase_label))

  if (!is.null(window_tbl) &&
      !is.na(window_fill) && nzchar(window_fill)) {
    p <- p + geom_ribbon(data        = window_tbl,
                         mapping     = aes(x = year,
                                            ymin = doy_start,
                                            ymax = doy_end),
                         inherit.aes = FALSE,
                         fill        = window_fill,
                         alpha       = 0.25)
  }

  p <- p +
    geom_ribbon(aes(ymin = mean_doy - sigma_factor * rms_bse,
                    ymax = mean_doy + sigma_factor * rms_bse),
                alpha = 0.22, colour = NA) +
    geom_line(linewidth = 0.4, alpha = 0.7) +
    geom_point(size = point_size) +
    geom_smooth(method    = "lm",
                se        = FALSE,
                linewidth = 0.6,
                linetype  = "dashed") +
    geom_text(data    = ann,
              mapping = aes(x = x, y = y, label = label,
                            colour = phase_label),
              hjust = 0, vjust = 1,
              size = sz_geom_text, family = essd_font,
              show.legend = FALSE) +
    scale_colour_manual(values = phase_colours, name = "Phase") +
    scale_fill_manual(  values = phase_colours, name = "Phase") +
    scale_x_continuous(breaks = scales::pretty_breaks(n = 8)) +
    scale_y_continuous(breaks = scales::pretty_breaks(n = 6)) +
    coord_cartesian(clip = "off") +
    labs(
      title    = sprintf("Phenological windows in the %s reference unit",
                         aoi_name),
      subtitle = sprintf(
        "%s, %s; ribbon = mean DOY \u00b1 %.1f \u00b7 RMS(BSE)",
        crop_label,
        paste(unname(phases), collapse = " and "),
        sigma_factor),
      x       = "Year",
      y       = "Day of year (DOY)",
      caption = paste0(
        "Uncertainty: BAM posterior standard error (BSE) from ",
        "PhenoPhaseR (M\u00f6ller et al. 2026)."
      )
    ) +
    essd_theme

  # Print to active graphics device
  print(p)

  # ---------------------------------------------------------------------------
  # STEP 10: Export figure
  #   Width fixed at 17.4 cm to match plot_phenology_raster_maps().
  # ---------------------------------------------------------------------------

  if (!is.null(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    fn_parts <- c(as.character(plant),
                  paste0(min(years), "-", max(years)),
                  "DOY_window.png")
    plot_filename <- paste(fn_parts, collapse = "_")
    output_path   <- file.path(output_dir, plot_filename)

    ggplot2::ggsave(
      filename = output_path,
      plot     = p,
      width    = 17.4,
      height   = fig_height,
      units    = "cm",
      dpi      = 300,
      bg       = "white"
    )
    message("Figure saved: ", output_path)
    message(sprintf("Dimensions  : 17.4 x %.1f cm at 300 dpi (ESSD two-column)",
                    fig_height))
  } else {
    message("output_dir not provided - figure printed to active device only.")
  }

  # ---------------------------------------------------------------------------
  # RETURN
  # ---------------------------------------------------------------------------

  invisible(list(
    ts_tbl     = ts_tbl,
    trend_tbl  = trend_tbl,
    window_tbl = window_tbl,
    aoi_sf     = aoi_sf,
    plot       = p
  ))
}


################################################################################
# USAGE EXAMPLE
# ==============================================================================
#
# # Pair this with plot_phenology_raster_maps() for a coordinated figure set:
#
# # 1. Two-panel DOY + BSE map for one (year, phase) snapshot:
# map_res <- plot_phenology_raster_maps(
#   doy_file     = "~/PhenoPhaseR/output/ro_crate_phase/cogs/DOY_202-15.tif",
#   bse_file     = "~/PhenoPhaseR/output/ro_crate_phase/cogs/BSE_202-15.tif",
#   plant        = 202,
#   target_phase = 15,
#   year         = 2020,
#   output_dir   = "./output",
#   aoi          = "Uckermark"
# )
#
# # 2. Time series of the inter-phase window over the AOI (matching style):
# ts_res <- plot_phenology_window_timeseries(
#   pheno_dir     = "~/PhenoPhaseR/output/ro_crate_phase/cogs",
#   aoi           = "Uckermark",
#   plant         = 202,
#   crop_label    = "Winter wheat",
#   phases        = c(`15` = "shooting", `18` = "heading"),
#   years         = 1993:2024,
#   sigma_factor  = 1.0,
#   phase_palette = "viridis",            # pairs with the DOY map
#   output_dir    = "./output"
# )
#
# # Access tabular outputs:
# ts_res$ts_tbl        # per-(phase, year) AOI summaries
# ts_res$trend_tbl     # linear trend statistics per phase
# ts_res$window_tbl    # yearly start/end DOYs of the inter-phase window
# ts_res$aoi_sf        # AOI as sf object in EPSG:25832
# ts_res$plot          # ggplot object - can be re-themed or re-saved
#
# NOTE ON CARTOGRAPHIC ALIGNMENT:
#   This function shares the ESSD typography block (sans-serif, identical
#   font sizes, light dashed grid, white background) and the 17.4 cm output
#   width with plot_phenology_raster_maps(). Phase line colours are sampled
#   from the same viridis-family palette as the DOY raster, so the two
#   figures form a visually coherent pair.
#
################################################################################
# END OF FILE
################################################################################
