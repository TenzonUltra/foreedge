# Paper study 02 — controlled surface experiments

## What to compare

Select Paper, then choose a surface. Keep the viewport and display settings fixed.

| Surface | Change | Comparison |
| --- | --- | --- |
| Original | The first pass, unchanged | Historical reference; grain still darkens the whole page |
| Balanced | Grain around a steady average paper tone | Compare smooth, then increase Grain |
| Soft relief | Balanced fibers with shallow directional shading | Compare with Balanced at the same settings |
| Adaptive | Soft relief with weaker variation over dark content | Compare with Soft relief, especially over gray swatches |

Command-B toggles a smooth comparison and preserves the selected surface and sliders. The new variants compensate average texture darkening so their tone stays approximately matched to smooth paper. Original is intentionally not brightness-matched: it retains the earlier treatment and ignores the new Brightness slider.

Brightness changes the rendered paper color, not display brightness. Its range reserves white headroom so light and dark texture variations fit without requiring HDR. The application starts with Balanced at the existing warmth/grain defaults.

## Implementation

PDFKit retains its native PDF view, text, and selection. A `PDFPageOverlayViewProvider` supplies a non-interactive view. Its Core Animation layer multiplies the paper color over the page; a child layer multiplies the chosen grayscale surface into that color. It is hidden in Plain mode. There is no app-driven frame loop.

All variants share one deterministic fiber field. Balanced centers its variations around a fixed mean. The background color compensates for each cached map's measured average transmission and the current Grain opacity. Soft relief adds a shallow height-gradient shading approximation with light from the upper left. It is not a complete physical reflection or scattering model.

Adaptive uses a smooth luminance-dependent strength curve. A separate, worker-owned Core Graphics PDF generates a temporary page mask at the surface resolution. Dark areas receive a nearly uniform surface multiplier; bright paper retains the relief. This is a brightness heuristic, not text/image segmentation. Visible text is never replaced by that mask or rasterized by this feature.

The current reader prepares three shared 1224 × 1584, 8-bit grayscale maps once per process off the main actor. Adaptive maps are prepared per visible page, with a six-page cache, up to four queued pages, and one worker job in flight. Soft relief appears until a page's Adaptive map is ready. Sliders change layer properties, and resizing reuses the same image. Intermediate height fields, masks, and working arrays are released after preparation. No custom Metal shader was introduced. See [PERFORMANCE.md](PERFORMANCE.md) for the reader measurements.

Apple references: [page overlays](https://developer.apple.com/documentation/pdfkit/pdfpageoverlayviewprovider), [layer compositing](https://developer.apple.com/documentation/quartzcore/calayer/compositingfilter).

## Measurements

Historical study-02 check on September 23, 2026: Apple M2, 16 GiB RAM, macOS 14.2.1, Swift 5.10, optimized (`-O`) verification executable. These figures describe the original four-map single-page preparation. The rendering regression helper still prepares that complete set; the reader now uses shared base maps and lazy Adaptive pages.

| Measurement | Result |
| --- | --- |
| Four cached grayscale images | 7,755,264 bytes, approximately 7.40 MiB |
| Five surface-set preparation samples | 110.29, 114.16, 122.49, 127.26, 127.54 ms |
| Median CPU preparation | 122.49 ms |
| 1,000 CPU layer-property updates | 3.24 ms total |
| Largest reference white-page mean drift | 0.144 of an 8-bit red-channel level |

The mean-drift check covers Balanced, Soft relief, and Adaptive at Grain 0, 0.45, and 1, using default warmth and brightness. It compares an all-white reference page against smooth paper. It is an encoded-channel comparison, not a physical luminance or calibrated display measurement.

Preparation includes the mask, all four surfaces, and image allocation. The small sample set does not control thermal state or system load. Property-update timing excludes GPU/presentation work, and Core Animation may coalesce those submissions. The byte count excludes temporary working memory and compositor/GPU surfaces.

Historical study 01 prepared a single map in a median 67.35 ms with 1,938,816 backing bytes. The new preparation figure includes more work; neither figure is a frame-time measurement.

The connected display previously reported 2× backing scale and a 60 Hz mode. Full idle energy, GPU cost, first visible frame, frame-time spikes, and total/peak memory remain unmeasured.

## Verification

Run `./scripts/check-rendering.sh`. It exports reference images for Plain, Warm, and all four surfaces, plus the luminance mask, under `.build/rendering-check/` and writes current measurements to `results.txt`.

Checks cover deterministic surfaces, bounded final cache, invalid PDF input, approximate mean-tone preservation, dark-ink preservation, and adaptive-mask alignment. Adaptive variation is compared with relief at matching locations: the check requires strong attenuation over dark content and near-unchanged texture over bright paper.

AppKit/PDFKit checks cover click-through behavior, image reuse when changing surface or grain, no explicit animations, Plain hiding, overlay installation, retention and bounds after resizing, unchanged document identity, and native selection.

An alignment check caught the Core Graphics fitting helper centering the PDF without upscaling it on this SDK. Mask rendering now explicitly scales the media box to the sample grid and respects bitmap row stride.

Reference PNGs use offscreen Core Graphics blending. They were inspected for texture appearance and text clarity, but are not live-window screenshots or proof of pixel-identical WindowServer compositing. The negative invalid-PDF test can emit one expected Core Graphics diagnostic before the success report.

## Remaining questions

- Judge the surfaces at actual reading size over a sustained reading session. A more visible material is not automatically the most comfortable one.
- Inspect adaptive transitions at text and image edges at different zoom levels; the fixed-resolution mask may become a limitation at high zoom.
- Evaluate scans, illustrations, and colored pages. Current fixtures remain text/vector pages; multiply affects existing colors as well as white paper.
- Texture scale is tuned for the study page and stretches to each page's media box. Per-page Adaptive preparation and bounded caching are implemented; very different page sizes and extreme zoom still need visual evaluation.
- Profile idle behavior and resizing before choosing a custom Metal path. Full Xcode/Instruments is not installed.
- E-ink tonal/dithering experiments and selective ink spread remain separate future experiments.
