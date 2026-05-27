################################################################################
# Raster Map Visualisation: DOY and BSE
################################################################################
#
# PURPOSE:
#   Reads a DOY (Day of Year) and a BSE raster file (.tif) and renders them
#   as a two-panel side-by-side map on a single plot sheet, formatted to meet
#   Earth System Science Data (ESSD) figure requirements.
#   Both panels share the Germany background and coordinate framework from
#   plot_phenology_comparison(); DOY and BSE (Bayesian posterior standard error)
#   each receive their own perceptually-uniform, CVD-safe viridis colour scale
#   with a dedicated colour bar.
#
# AUTHORS:
#   Derived from plot_phenology_comparison() by
#   Markus Möller (ORCID: https://orcid.org/0000-0002-1918-7747)
#   Julius Kühn Institute (JKI); https://www.julius-kuehn.de/
#
# DEPENDENCIES:
#   - R >= 4.0.0
#   - terra          (raster I/O and reprojection)
#   - ggplot2        (plotting)
#   - sf             (spatial data handling)
#   - rnaturalearth  (background map)
#   - patchwork      (multi-panel layout)
#
# ESSD FIGURE COMPLIANCE (https://www.earth-system-science-data.net/):
#   - Single sans-serif font family (Helvetica/Arial) throughout
#   - Output width: 17.4 cm (two-column), height: 12 cm; 300 dpi
#   - Panel labels: (a), (b) – lowercase, with brackets
#   - Coordinate axis labels: degree sign + space + direction (e.g., 10° E)
#   - CVD-friendly colour schemes (viridis / plasma)
#   - Minimal non-data ink (white background, light dashed grid)
#
# VERSION HISTORY:
#   v1.0.0 (2026-03-31): Initial release – raster adaptation of
#                         plot_phenology_comparison()
#   v1.1.0 (2026-03-31): Replaced linear continuous scale with quantile-binned
#                         scale (scale_fill_stepsn) for improved spatial
#                         differentiation; added n_quantiles argument.
#   v1.2.0 (2026-03-31): Corrected BSE expansion to "Bayesian posterior
#                         standard error"; DOY legend formatted to 0 decimals,
#                         BSE legend to 2 decimals.
#   v1.3.0 (2026-03-31): Changed default quantile classification to 10 classes
#                         (decile) for finer legend differentiation.
#   v1.4.0 (2026-03-31): Increased legend bar height to 120 pt (12 pt per
#                         class) for legible class labels at 10 classes.
#   v1.5.0 (2026-05-03): Added optional AOI overlay (e.g. Uckermark test
#                         site) with halo-style outline visible on both
#                         viridis and plasma palettes; AOI accepted as sf
#                         polygon or as a GADM-level-2 name string.
#   v1.6.0 (2026-05-03): Removed the AOI centroid label (halo text) - the
#                         polygon outline alone is preferred; the AOI is
#                         identified via the figure caption instead.
#
# LICENSE:
#   This code is provided under the MIT License.
#
################################################################################

# ==============================================================================
# FUNCTION DOCUMENTATION
# ==============================================================================
#
# plot_phenology_raster_maps()
#
# ARGUMENTS:
#   doy_file (character):
#     Full path to the DOY raster file (.tif).
#     The raster may be in any CRS – it is reprojected to WGS 84 internally.
#
#   bse_file (character):
#     Full path to the BSE raster file (.tif).
#     Same CRS handling as doy_file.
#
#   plant (numeric or character, optional):
#     Crop identifier shown in the overall figure title (e.g., 202 for Winter
#     wheat). If NULL the title omits the crop token.
#
#   target_phase (numeric or character, optional):
#     Phenological phase ID shown in the overall title (e.g., 15 for shooting).
#     If NULL the title omits the phase token.
#
#   year (numeric or character, optional):
#     Observation year shown in panel subtitles and the file name.
#     If NULL, the year token is omitted from subtitles and the output filename.
#
#   output_dir (character, optional):
#     Directory for saving the PNG figure.
#     File name: [plant]_[target_phase]_[year]_DOY_BSE.png  (tokens present
#     only when the respective argument is supplied).
#     Dimensions: 17.4 x 12 cm at 300 dpi (ESSD two-column width).
#     If NULL the plot is printed to the active graphics device only.
#
#   na_colour (character, default = "white"):
#     Colour used for NA cells in both rasters (e.g., sea / no-data areas).
#
#   doy_palette (character, default = "viridis"):
#     viridis palette option for the DOY panel ("viridis", "magma", "plasma",
#     "inferno", "cividis", "mako", "rocket", "turbo").
#
#   bse_palette (character, default = "plasma"):
#     viridis palette option for the BSE panel. Using a different palette from
#     doy_palette helps readers distinguish the two variables at a glance.
#
#   n_quantiles (integer, default = 10):
#     Number of quantile classes used for colour binning in both panels.
#     Quantile breaks are computed separately for DOY and BSE so that each
#     colour band contains an equal share of non-NA raster cells, maximising
#     visual differentiation across the map regardless of the value
#     distribution.  The default of 10 (decile classification) gives fine
#     spatial detail; reduce to 5–7 for a cleaner, simpler legend.
#     Use n_quantiles = 0 to fall back to the original linear continuous scale.
#
#   point_size (numeric, NULL = unused):
#     Kept for API symmetry with plot_phenology_comparison(); has no effect on
#     raster rendering.
#
#   aoi (sf, character, or NULL; default = NULL):
#     Optional area-of-interest polygon to overlay on both panels.
#     - sf object: any polygon/multipolygon feature in any CRS; reprojected
#       to WGS 84 internally.
#     - character: a German Landkreis (NUTS-3) name. The polygon is fetched
#       from GADM level 2 via the 'geodata' package (cached in cache_dir).
#       Example: aoi = "Uckermark".
#     - NULL: no overlay (default; backward compatible).
#
#   aoi_halo (character, default = "white"):
#     Colour of the outer (halo) outline of the AOI polygon.
#
#   aoi_line (character, default = "black"):
#     Colour of the inner (foreground) outline of the AOI polygon.
#
#   aoi_linewidth (numeric length-2, default = c(0.9, 0.45)):
#     Linewidths of the (halo, inner) AOI outlines, in pt.
#
#   cache_dir (character, default = "data/aoi"):
#     Directory used for caching GADM downloads when 'aoi' is a character
#     name. Created on first use.
#
# RETURNS:
#   A named list (invisibly):
#     $doy_df      : data.frame (x, y, value) for the DOY raster (WGS 84)
#     $bse_df      : data.frame (x, y, value) for the BSE raster (WGS 84)
#     $doy_breaks  : numeric vector of quantile break points used for DOY
#     $bse_breaks  : numeric vector of quantile break points used for BSE
#     $aoi_sf      : sf object of the AOI in WGS 84 (NULL when 'aoi' is NULL)
#     $plot        : patchwork ggplot object (two-panel figure, ready for export)
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

ensure_packages(c("terra",
                  "ggplot2",
                  "sf",
                  "rnaturalearth",
                  "patchwork"))


# ==============================================================================
# HELPERS: Coordinate axis label formatters
#   ESSD requirement: degree sign + space + direction (e.g., 10° E, 50° N).
# ==============================================================================

.fmt_lon <- function(x) {
  ifelse(x == 0, paste0("0\u00b0"),
         ifelse(x > 0,
                paste0(x,      "\u00b0 E"),
                paste0(abs(x), "\u00b0 W")))
}

.fmt_lat <- function(x) {
  ifelse(x == 0, paste0("0\u00b0"),
         ifelse(x > 0,
                paste0(x,      "\u00b0 N"),
                paste0(abs(x), "\u00b0 S")))
}


# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

plot_phenology_raster_maps <- function(
    doy_file,
    bse_file,
    plant         = NULL,
    target_phase  = NULL,
    year          = NULL,
    output_dir    = NULL,
    na_colour     = "white",
    doy_palette   = "viridis",
    bse_palette   = "plasma",
    n_quantiles   = 10,            # number of quantile colour classes
    point_size    = NULL,          # unused; present for API symmetry
    aoi           = NULL,          # sf polygon or GADM Landkreis name
    aoi_halo      = "white",       # outer (halo) outline colour
    aoi_line      = "black",       # inner outline colour
    aoi_linewidth = c(0.9, 0.45),  # (halo, inner) linewidths
    cache_dir     = "data/aoi"     # cache for GADM downloads
) {

  # ---------------------------------------------------------------------------
  # INPUT VALIDATION
  # ---------------------------------------------------------------------------

  if (!file.exists(doy_file))
    stop("DOY raster not found: ", doy_file)
  if (!file.exists(bse_file))
    stop("BSE raster not found: ", bse_file)

  valid_palettes <- c("viridis", "magma", "plasma", "inferno",
                      "cividis", "mako", "rocket", "turbo")
  if (!doy_palette %in% valid_palettes)
    stop("doy_palette must be one of: ", paste(valid_palettes, collapse = ", "))
  if (!bse_palette %in% valid_palettes)
    stop("bse_palette must be one of: ", paste(valid_palettes, collapse = ", "))
  if (!is.numeric(n_quantiles) || length(n_quantiles) != 1 ||
      (!n_quantiles == 0 && n_quantiles < 2))
    stop("n_quantiles must be 0 (continuous) or an integer >= 2.")

  message("=== Phenology Raster Maps: DOY + BSE ===")

  # ---------------------------------------------------------------------------
  # STEP 1: Read rasters with terra
  # ---------------------------------------------------------------------------

  message("Reading rasters ...")
  r_doy <- terra::rast(doy_file)
  r_bse <- terra::rast(bse_file)

  # Use the first layer only (in case the file contains multiple bands)
  if (terra::nlyr(r_doy) > 1) {
    message("  DOY: multiple layers detected – using layer 1.")
    r_doy <- r_doy[[1]]
  }
  if (terra::nlyr(r_bse) > 1) {
    message("  BSE: multiple layers detected – using layer 1.")
    r_bse <- r_bse[[1]]
  }

  message("  DOY CRS : ", terra::crs(r_doy, describe = TRUE)$name)
  message("  BSE CRS : ", terra::crs(r_bse, describe = TRUE)$name)
  message("  DOY res : ", paste(round(terra::res(r_doy), 6), collapse = " x "))
  message("  BSE res : ", paste(round(terra::res(r_bse), 6), collapse = " x "))

  # ---------------------------------------------------------------------------
  # STEP 2: Reproject to WGS 84 (EPSG:4326)
  #   rnaturalearth returns WGS 84; reprojecting rasters ensures consistent
  #   coordinate alignment across background and data layers.
  # ---------------------------------------------------------------------------

  wgs84 <- "EPSG:4326"

  if (!terra::same.crs(r_doy, wgs84)) {
    message("  Reprojecting DOY to WGS 84 ...")
    r_doy <- terra::project(r_doy, wgs84, method = "bilinear")
  }
  if (!terra::same.crs(r_bse, wgs84)) {
    message("  Reprojecting BSE to WGS 84 ...")
    r_bse <- terra::project(r_bse, wgs84, method = "bilinear")
  }

  # ---------------------------------------------------------------------------
  # STEP 3: Convert rasters to plain data frames for ggplot2
  #   terra::as.data.frame(xy = TRUE) returns columns x, y, and the band name.
  #   We rename the value column to "value" for consistent downstream code.
  # ---------------------------------------------------------------------------

  message("Converting rasters to data frames ...")

  .rast_to_df <- function(r, varname) {
    df <- terra::as.data.frame(r, xy = TRUE, na.rm = FALSE)
    # The band column may have any name; rename to "value"
    band_col <- setdiff(names(df), c("x", "y"))
    names(df)[names(df) == band_col[1]] <- "value"
    message("  ", varname, ": ", nrow(df[!is.na(df$value), ]),
            " non-NA cells  |  value range [",
            round(min(df$value, na.rm = TRUE), 2), ", ",
            round(max(df$value, na.rm = TRUE), 2), "]")
    df
  }

  df_doy <- .rast_to_df(r_doy, "DOY")
  df_bse <- .rast_to_df(r_bse, "BSE")

  # ---------------------------------------------------------------------------
  # STEP 4: Germany background map + shared bounding box
  # ---------------------------------------------------------------------------

  message("Loading Germany background ...")
  germany <- rnaturalearth::ne_countries(
    scale       = "medium",
    country     = "Germany",
    returnclass = "sf"
  )

  de_bbox <- sf::st_bbox(germany)
  margin  <- 0.5   # degrees – same padding as plot_phenology_comparison()
  xlim    <- c(de_bbox["xmin"] - margin, de_bbox["xmax"] + margin)
  ylim    <- c(de_bbox["ymin"] - margin, de_bbox["ymax"] + margin)

  # ---------------------------------------------------------------------------
  # STEP 4b: Resolve optional AOI (e.g. Uckermark) and reproject to WGS 84
  #
  #   'aoi' may be:
  #     - an sf object (used directly after CRS check),
  #     - a character giving a GADM-level-2 name (Kreis), fetched via the
  #       'geodata' package and cached in cache_dir,
  #     - NULL (no overlay; default).
  # ---------------------------------------------------------------------------

  aoi_sf <- NULL

  if (!is.null(aoi)) {

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
      stop("'aoi' must be an sf object, a single character name, or NULL.")
    }

    # Ensure WGS 84 to match raster and country background
    if (sf::st_crs(aoi_sf) != sf::st_crs(wgs84)) {
      aoi_sf <- sf::st_transform(aoi_sf, wgs84)
    }
    aoi_bb <- sf::st_bbox(aoi_sf)
    message(sprintf("  AOI bbox (WGS 84): [%.3f, %.3f] x [%.3f, %.3f]",
                    aoi_bb["xmin"], aoi_bb["xmax"],
                    aoi_bb["ymin"], aoi_bb["ymax"]))
  }

  # ---------------------------------------------------------------------------
  # STEP 5: ESSD-compliant typography
  #   Mirrors the exact size choices in plot_phenology_comparison() so figures
  #   from both functions look consistent in the same publication.
  # ---------------------------------------------------------------------------

  essd_font    <- "sans"   # Helvetica on macOS/Linux, Arial on Windows.
                            # Install 'extrafont' for guaranteed Helvetica.
  sz_panel_ttl <- 9        # Panel title                      [pt]
  sz_subtitle  <- 8        # Panel subtitle                   [pt]
  sz_axis_txt  <- 7.5      # Axis tick labels                 [pt]
  sz_legend_t  <- 8        # Legend title                     [pt]
  sz_legend    <- 7.5      # Legend tick labels               [pt]
  sz_tag       <- 9        # Panel tags (a), (b)              [pt]
  sz_annot_ttl <- 10       # Overall annotation title         [pt]
  sz_annot_sub <- 8        # Overall annotation subtitle      [pt]

  # ---------------------------------------------------------------------------
  # STEP 6: Shared ggplot theme (identical to plot_phenology_comparison)
  # ---------------------------------------------------------------------------

  essd_theme <- theme_bw(base_family = essd_font,
                          base_size   = sz_axis_txt) +
    theme(
      # Background and border
      panel.background  = element_rect(fill = "white", colour = NA),
      panel.border      = element_rect(colour = "black", linewidth = 0.4),

      # Grid: light dashed lines – minimal non-data ink
      panel.grid.major  = element_line(colour   = "grey85",
                                       linewidth = 0.25,
                                       linetype  = "dashed"),
      panel.grid.minor  = element_blank(),

      # Axes
      axis.text         = element_text(size   = sz_axis_txt,
                                       family = essd_font,
                                       colour = "black"),
      axis.title        = element_blank(),   # coord labels serve as axis text
      axis.ticks        = element_line(colour = "black", linewidth = 0.3),
      axis.ticks.length = unit(1.5, "pt"),

      # Panel title and subtitle
      plot.title        = element_text(size   = sz_panel_ttl,
                                       family = essd_font,
                                       face   = "bold",
                                       hjust  = 0,
                                       margin = margin(b = 2, unit = "pt")),
      plot.subtitle     = element_text(size   = sz_subtitle,
                                       family = essd_font,
                                       colour = "grey35",
                                       hjust  = 0,
                                       margin = margin(b = 3, unit = "pt")),

      # Panel tag – ESSD: lowercase letters in brackets
      plot.tag          = element_text(size   = sz_tag,
                                       family = essd_font,
                                       face   = "bold"),
      plot.tag.position = "topleft",

      # Legend
      legend.position   = "right",
      legend.key.width  = unit(6,   "pt"),
      legend.key.height = unit(120, "pt"),
      legend.title      = element_text(size   = sz_legend_t,
                                       family = essd_font,
                                       face   = "bold"),
      legend.text       = element_text(size   = sz_legend,
                                       family = essd_font),
      legend.background = element_rect(fill = "white", colour = NA),
      legend.margin     = margin(0, 2, 0, 2, unit = "pt"),

      # Plot margins
      plot.margin       = margin(4, 4, 4, 4, unit = "pt")
    )

  # ---------------------------------------------------------------------------
  # STEP 7: Quantile break computation + colour scale helper
  #
  #   WHY QUANTILES?
  #   A linear (min–max) scale assigns equal colour-space to equal value
  #   intervals.  When values are unevenly distributed – common in phenology
  #   data where most pixels cluster in a narrow DOY band – the bulk of the
  #   map ends up in just one or two colours, hiding spatial structure.
  #   Quantile classification solves this: each colour band covers the same
  #   *number of pixels*, guaranteeing that every class is equally represented
  #   and the full palette is used across the map.
  #
  #   IMPLEMENTATION
  #   .quantile_breaks() computes n_quantiles + 1 break points from the
  #   non-NA pixel values using stats::quantile() with type = 7 (default R
  #   interpolation).  Duplicate breaks (e.g., from integer-valued rasters)
  #   are removed and a warning is issued so the user knows the effective
  #   number of classes.
  #
  #   .make_fill_scale() then builds scale_fill_stepsn():
  #     - colours : n_quantiles viridis colours sampled uniformly along the
  #                 palette (direction = -1 → darker = lower value, matching
  #                 the directional convention of plot_phenology_comparison).
  #     - breaks  : the n_quantiles - 1 interior break values.
  #     - limits  : full data range so colours are anchored to actual values.
  #     - values  : break positions rescaled to [0, 1] within limits, required
  #                 by scale_fill_stepsn to map colours to the right intervals.
  #   When n_quantiles == 0, the original linear scale_fill_viridis_c is used
  #   as a fallback.
  #
  #   LEGEND
  #   guide_colorsteps() replaces guide_colorbar() so the legend shows
  #   discrete colour bands with tick marks at the quantile break values,
  #   making the classification immediately readable.
  # ---------------------------------------------------------------------------

  .quantile_breaks <- function(values, n) {
    # n + 1 evenly-spaced probability points → n + 1 value break points
    probs  <- seq(0, 1, length.out = n + 1)
    breaks <- stats::quantile(values, probs = probs, na.rm = TRUE, type = 7)
    breaks <- unique(breaks)          # remove duplicates (integer rasters)
    if (length(breaks) < n + 1) {
      warning("Some quantile breaks were identical and were removed. ",
              "Effective number of classes: ", length(breaks) - 1, ".")
    }
    unname(breaks)
  }

  .make_fill_scale <- function(palette, label, values, n_q, label_fmt) {

    full_limits <- range(values, na.rm = TRUE)

    if (n_q == 0) {
      # ---- fallback: original linear continuous scale ----------------------
      return(
        scale_fill_viridis_c(
          option    = palette,
          name      = label,
          direction = -1,
          limits    = full_limits,
          labels    = label_fmt,
          na.value  = na_colour,
          guide     = guide_colorbar(
            barwidth        = unit(6,   "pt"),
            barheight       = unit(120, "pt"),
            title.position  = "top",
            title.hjust     = 0.5,
            ticks.colour    = "black",
            ticks.linewidth = 0.4,
            frame.colour    = "black",
            frame.linewidth = 0.4
          )
        )
      )
    }

    # ---- quantile-binned scale ---------------------------------------------
    all_breaks <- .quantile_breaks(values, n_q)
    n_classes  <- length(all_breaks) - 1   # effective after deduplication

    # Sample n_classes colours uniformly from the chosen viridis palette.
    # direction = -1: reverse so darker = lower value (earlier / less).
    pal_colours <- viridis::viridis(n_classes, option = palette, direction = -1)

    # Interior breaks only (scale_fill_stepsn uses these as class boundaries)
    interior_breaks <- all_breaks[-c(1, length(all_breaks))]

    # Rescale break positions to [0, 1] within full_limits for the 'values'
    # argument of scale_fill_stepsn (controls where colour transitions happen)
    break_positions <- (all_breaks - full_limits[1]) /
                       diff(full_limits)

    scale_fill_stepsn(
      colours  = pal_colours,
      breaks   = interior_breaks,
      values   = break_positions,
      limits   = full_limits,
      labels   = label_fmt,
      na.value = na_colour,
      name     = label,
      guide    = guide_colorsteps(
        barwidth        = unit(6,   "pt"),
        barheight       = unit(120, "pt"),
        title.position  = "top",
        title.hjust     = 0.5,
        ticks           = TRUE,
        frame.colour    = "black",
        frame.linewidth = 0.4,
        show.limits     = TRUE
      )
    )
  }

  # Ensure viridis package is available (needed for viridis::viridis())
  if (n_quantiles > 0 && !requireNamespace("viridis", quietly = TRUE)) {
    message("Installing package: viridis")
    install.packages("viridis", quiet = TRUE)
  }

  doy_limits <- range(df_doy$value, na.rm = TRUE)
  bse_limits <- range(df_bse$value, na.rm = TRUE)

  # Compute and report quantile breaks
  if (n_quantiles > 0) {
    doy_breaks <- .quantile_breaks(df_doy$value, n_quantiles)
    bse_breaks <- .quantile_breaks(df_bse$value, n_quantiles)
    message("DOY quantile breaks (", length(doy_breaks) - 1, " classes): ",
            paste(round(doy_breaks, 1), collapse = " | "))
    message("BSE quantile breaks (", length(bse_breaks) - 1, " classes): ",
            paste(round(bse_breaks, 1), collapse = " | "))
  } else {
    doy_breaks <- doy_limits
    bse_breaks <- bse_limits
    message("DOY colour scale (linear): [",
            round(doy_limits[1], 1), ", ", round(doy_limits[2], 1), "]")
    message("BSE colour scale (linear): [",
            round(bse_limits[1], 1), ", ", round(bse_limits[2], 1), "]")
  }

  # Axis break sequences
  x_breaks <- seq(floor(xlim[1]),   ceiling(xlim[2]),  by = 3)
  y_breaks <- seq(floor(ylim[1]),   ceiling(ylim[2]),  by = 2)

  # ---------------------------------------------------------------------------
  # STEP 8: Build panel subtitle
  #   Shows year when provided; omits it gracefully when NULL.
  # ---------------------------------------------------------------------------

  .panel_sub <- function(layer_name) {
    if (!is.null(year))
      paste0(layer_name, "  |  ", year)
    else
      layer_name
  }

  # ---------------------------------------------------------------------------
  # STEP 8b: Reusable AOI overlay
  #   Two stacked geom_sf calls produce a halo (outer) + inner-line effect
  #   that stays legible on both viridis (greens / yellows) and plasma
  #   (purples / pinks) backgrounds. The AOI is identified in the figure
  #   caption rather than via an inline label, to keep map ink minimal.
  # ---------------------------------------------------------------------------

  aoi_layers <- if (!is.null(aoi_sf)) {
    list(
      ggplot2::geom_sf(data        = aoi_sf,
                       fill        = NA,
                       colour      = aoi_halo,
                       linewidth   = aoi_linewidth[1],
                       inherit.aes = FALSE),
      ggplot2::geom_sf(data        = aoi_sf,
                       fill        = NA,
                       colour      = aoi_line,
                       linewidth   = aoi_linewidth[2],
                       inherit.aes = FALSE)
    )
  } else {
    NULL
  }

  # ---------------------------------------------------------------------------
  # STEP 9: Panel (a) – DOY raster
  # ---------------------------------------------------------------------------

  message("Building panel (a): DOY ...")

  p_a <- ggplot() +
    # Germany polygon as background
    geom_sf(data      = germany,
            fill      = "grey92",
            colour    = "grey55",
            linewidth = 0.25) +
    # Raster layer (fill aesthetic, not colour)
    geom_raster(data    = df_doy,
                mapping = aes(x = x, y = y, fill = value),
                interpolate = TRUE) +
    .make_fill_scale(doy_palette, "DOY", df_doy$value, n_quantiles,
                     scales::label_number(accuracy = 1)) +
    # Re-draw Germany border on top so it overlays raster edges at the coast
    geom_sf(data      = germany,
            fill      = NA,
            colour    = "grey40",
            linewidth = 0.3) +
    # Optional AOI overlay (e.g. Uckermark) – drawn last so it stays on top
    aoi_layers +
    coord_sf(xlim   = xlim,
             ylim   = ylim,
             expand = FALSE) +
    scale_x_continuous(labels = .fmt_lon, breaks = x_breaks) +
    scale_y_continuous(labels = .fmt_lat, breaks = y_breaks) +
    labs(
      title    = "Day of year (DOY)",
      subtitle = .panel_sub("DOY"),
      tag      = "(a)"
    ) +
    essd_theme

  # ---------------------------------------------------------------------------
  # STEP 10: Panel (b) – BSE raster
  # ---------------------------------------------------------------------------

  message("Building panel (b): BSE ...")

  p_b <- ggplot() +
    geom_sf(data      = germany,
            fill      = "grey92",
            colour    = "grey55",
            linewidth = 0.25) +
    geom_raster(data    = df_bse,
                mapping = aes(x = x, y = y, fill = value),
                interpolate = TRUE) +
    .make_fill_scale(bse_palette, "BSE", df_bse$value, n_quantiles,
                     scales::label_number(accuracy = 0.01)) +
    geom_sf(data      = germany,
            fill      = NA,
            colour    = "grey40",
            linewidth = 0.3) +
    # Optional AOI overlay (e.g. Uckermark) – drawn last so it stays on top
    aoi_layers +
    coord_sf(xlim   = xlim,
             ylim   = ylim,
             expand = FALSE) +
    scale_x_continuous(labels = .fmt_lon, breaks = x_breaks) +
    scale_y_continuous(labels = .fmt_lat, breaks = y_breaks) +
    labs(
      title    = "Bayesian posterior standard error (BSE)",
      subtitle = .panel_sub("BSE"),
      tag      = "(b)"
    ) +
    essd_theme

  # ---------------------------------------------------------------------------
  # STEP 11: Assemble two-panel layout
  #   guides = "collect" is NOT used here because DOY and BSE have different
  #   scales (different variables, different palettes), so each panel retains
  #   its own colour bar.
  # ---------------------------------------------------------------------------

  message("Assembling two-panel figure ...")

  # Build overall title and subtitle tokens
  title_tokens <- "Phenological raster maps"
  if (!is.null(plant) && !is.null(target_phase))
    title_tokens <- paste0(title_tokens,
                           " \u2013 crop ", plant,
                           ", phase ", target_phase)
  else if (!is.null(plant))
    title_tokens <- paste0(title_tokens, " \u2013 crop ", plant)
  else if (!is.null(target_phase))
    title_tokens <- paste0(title_tokens, " \u2013 phase ", target_phase)

  sub_tokens <- "Source: DWD Open Data (CC BY 4.0)"
  if (!is.null(year))
    sub_tokens <- paste0("Year: ", year, "  |  ", sub_tokens)
  if (n_quantiles > 0)
    sub_tokens <- paste0(sub_tokens,
                         "  |  Colour classification: ",
                         n_quantiles, "-class quantile")

  combined_plot <- (p_a | p_b) +
    patchwork::plot_annotation(
      title    = title_tokens,
      subtitle = sub_tokens,
      theme    = theme(
        plot.title    = element_text(size   = sz_annot_ttl,
                                     family = essd_font,
                                     face   = "bold",
                                     hjust  = 0),
        plot.subtitle = element_text(size   = sz_annot_sub,
                                     family = essd_font,
                                     colour = "grey35",
                                     hjust  = 0),
        plot.margin   = margin(5, 5, 5, 5, unit = "pt")
      )
    )

  # Print to active graphics device
  print(combined_plot)

  # ---------------------------------------------------------------------------
  # STEP 12: Export figure
  #   ESSD two-column width : 17.4 cm (~6.85 in)
  #   Height                : 12.0 cm (~4.72 in)
  #   Resolution            : 300 dpi
  # ---------------------------------------------------------------------------

  if (!is.null(output_dir)) {

    # Build output filename from available metadata tokens
    fn_parts <- character(0)
    if (!is.null(plant))        fn_parts <- c(fn_parts, as.character(plant))
    if (!is.null(target_phase)) fn_parts <- c(fn_parts, as.character(target_phase))
    if (!is.null(year))         fn_parts <- c(fn_parts, as.character(year))
    fn_parts <- c(fn_parts, "DOY_BSE.png")

    plot_filename <- paste(fn_parts, collapse = "_")
    output_path   <- file.path(output_dir, plot_filename)

    ggplot2::ggsave(
      filename = output_path,
      plot     = combined_plot,
      width    = 17.4,
      height   = 12.5,
      units    = "cm",
      dpi      = 300,
      bg       = "white"
    )

    message("Figure saved: ", output_path)
    message("Dimensions  : 17.4 x 12.0 cm at 300 dpi (ESSD two-column)")

  } else {
    message("output_dir not provided – figure printed to active device only.")
  }

  # ---------------------------------------------------------------------------
  # RETURN
  # ---------------------------------------------------------------------------

  invisible(list(
    doy_df     = df_doy,
    bse_df     = df_bse,
    doy_breaks = doy_breaks,
    bse_breaks = bse_breaks,
    aoi_sf     = aoi_sf,
    plot       = combined_plot
  ))
}


################################################################################
# USAGE EXAMPLE
# ==============================================================================
#
# result <- plot_phenology_raster_maps(
#   doy_file     = "DOY_202-15_1993.tif",
#   bse_file     = "BSE_202-15_1993.tif",
#   plant        = 202,          # Winter wheat
#   target_phase = 15,           # Shooting / Aehrenschieben
#   year         = 1993,
#   output_dir   = "./output",
#   na_colour    = "white",
#   doy_palette  = "viridis",    # CVD-safe; darker = earlier DOY
#   bse_palette  = "plasma",     # Distinct palette for BSE
#   n_quantiles  = 10            # 10-class decile classification (default)
# )
#
# # Use n_quantiles = 0 to switch back to the linear continuous scale:
# result_linear <- plot_phenology_raster_maps(
#   doy_file    = "DOY_202-15_1993.tif",
#   bse_file    = "BSE_202-15_1993.tif",
#   n_quantiles = 0
# )
#
# # Highlight the Uckermark test site as an AOI overlay (auto-fetches GADM):
# result_uck <- plot_phenology_raster_maps(
#   doy_file     = "DOY_202-15_2020.tif",
#   bse_file     = "BSE_202-15_2020.tif",
#   plant        = 202,
#   target_phase = 15,
#   year         = 2020,
#   output_dir   = "./output",
#   aoi          = "Uckermark"          # GADM-level-2 (Landkreis) name
# )
#
# # Same, but pass an existing sf polygon and a custom outline colour:
# library(sf)
# uck_sf <- st_read("uckermark.gpkg")
# result_custom <- plot_phenology_raster_maps(
#   doy_file = "DOY_202-15_2020.tif",
#   bse_file = "BSE_202-15_2020.tif",
#   aoi      = uck_sf,
#   aoi_halo = "white",
#   aoi_line = "#b2182b"                # warm red on the dark inner stroke
# )
#
# # Access outputs:
# result$doy_df      # data.frame with x, y, value for DOY raster (WGS 84)
# result$bse_df      # data.frame with x, y, value for BSE raster (WGS 84)
# result$doy_breaks  # quantile break points applied to DOY colour scale
# result$bse_breaks  # quantile break points applied to BSE colour scale
# result$plot        # patchwork ggplot – can be further modified or re-saved
#
# # Re-export at a custom size:
# ggplot2::ggsave("custom_output.png", result$plot,
#                 width = 17.4, height = 12, units = "cm", dpi = 300)
#
# NOTE ON FONTS:
#   essd_font = "sans" maps to Helvetica (macOS/Linux) or Arial (Windows).
#   For guaranteed cross-platform Helvetica, install the 'extrafont' package:
#     install.packages("extrafont")
#     extrafont::font_import()
#   Then change essd_font <- "Helvetica" inside the function body.
#
# NOTE ON PALETTES:
#   DOY and BSE use different viridis palette options by default so they are
#   visually distinct in the same figure. Both are perceptually uniform and
#   CVD-safe, satisfying the ESSD colour requirement.
#   Available options: "viridis", "magma", "plasma", "inferno",
#                      "cividis", "mako", "rocket", "turbo"
#
# NOTE ON QUANTILE CLASSES:
#   n_quantiles = 10 →  decile classification (default, finer differentiation)
#   n_quantiles = 7  →  septile classification
#   n_quantiles = 5  →  quintile classification (fewer, cleaner legend)
#   n_quantiles = 0  →  linear continuous scale (original behaviour)
#
################################################################################
# END OF FILE
################################################################################
