# Paper reader for macOS — proposed plan

## Next direction: academic reading workspace

The current rendering is accepted for now. Quiet UI, persistent reading state, command palette, in-book navigation/history, and marks are implemented in the first increment. The next increment adds collections, folder discovery, scoped fuzzy quick-open, and bounded native-document reuse. Tiling is next. The staged sequence is quiet UI and reading continuity → in-book navigation/history/marks → catalogues and quick switching → tiled workspaces → cross-book references → collection search → optional semantic assistance. See [WORKSPACE-DESIGN.md](WORKSPACE-DESIGN.md) for feature boundaries, acceptance checks, architecture, and deferred decisions. That proposal supersedes the parked-reader ordering below; the existing rendering milestones remain historical context.

Status: native, PDF-first direction accepted. Build setup uses Swift Package Manager, Swift 5.10, and a macOS 14 deployment target with no third-party dependencies. Plain/Warm/Paper includes Original, Balanced, Soft relief, and Adaptive experiments. Local PDF opening, continuous scrolling, page jumps, and fit width now support real-book performance testing. Rendering and reader checks pass; full display/GPU/energy baselines remain open. See RENDERING.md and PERFORMANCE.md.

## Product direction

A native, local macOS reader with a quiet, paper-like reading surface and fast navigation. Start with PDFs inside a standalone app.

The immediate deliverable is a rendering experiment with measurable baselines on real books. Basic navigation and opening another book are available for testing; bookmarks and library features remain deferred. Source documents remain unchanged.

## Recommended stack

- Swift for application code, compiled natively for Apple silicon.
- SwiftUI for the app shell, toolbar, settings, and eventual library.
- AppKit and PDFKit's PDFView, embedded through NSViewRepresentable, for the reading surface.
- A cached, static paper texture with native compositing. Evaluate Core Image for generating the texture or applying optional effects; introduce custom Metal rendering only if profiling and visual requirements justify it.
- Apple frameworks only for the first prototype. Swift Package Manager builds a native executable, and a local script packages an ad-hoc signed app. Persistence technology remains deferred.

References: [PDFKit](https://developer.apple.com/documentation/pdfkit), [PDFView](https://developer.apple.com/documentation/pdfkit/pdfview), [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable), [Core Image performance](https://developer.apple.com/videos/play/wwdc2020/10008/).

## Rendering approach and first technical risk

The supplied example creates transparent windows over every display. It demonstrates grain, but does not implement a reader, document navigation, or page-specific paper appearance.

Start with PDFView so text, links, zoom, and navigation can use the native PDF implementation. Keep its view and document instances stable across unrelated SwiftUI state updates.

Prototype a page-confined, non-interactive appearance layer. Combine a warm paper tone with subtle, static grain. Initially verify alignment at fixed scale and during resizing; later verify zoom, scrolling, selection, and links before expanding the reader. Do not assume that changing the viewer background recolors opaque white PDF pages.

Evaluate text PDFs, scans, illustrations, and colored pages. A simple tint or multiply treatment can also alter artwork and scanned backgrounds. Prefer an adjustable, gentle effect and a clear off switch; defer aggressive recoloring or background removal.

Preserve native text rendering as the default. If PDFKit cannot deliver the intended appearance cleanly, evaluate a separate rendered-page reading mode as an explicit tradeoff: it would need additional work for selection, search highlighting, accessibility, and crisp zoom.

## Milestones

0. **Baseline harness:** Display one PDF page in a minimal native window with no paper effect. Record the Mac, macOS version, display resolution, backing scale, refresh setting, brightness, and relevant display adjustments. Measure release builds after separating cold startup from warmed runs. Record load-to-render-ready time separately from actual presentation latency where measurable, idle CPU/GPU activity, memory, and energy observations. Do not label rendering completion as pixels appearing on screen.
1. **Paper experiments:** Compare the exact same page and viewport in three modes: plain, warm tint only, and tint plus cached static grain. Use deterministic texture generation and identical display settings. Measure texture creation separately from steady-state compositing and resizing. Start with text and scanned-page fixtures; include an illustrated page before accepting the treatment. Verify that small text remains crisp, the page is covered correctly, and grain has no distracting tiling or shimmer. Check that the app schedules no recurring redraws while idle and that resource use returns close to the plain baseline. Establish numeric budgets from measured results, then add one visual refinement at a time.
2. **Useful first reader:** File picker and drag-and-drop, single-page and continuous reading, keyboard page navigation, fit-to-width, zoom, full screen, and paper warmth/grain controls. Handle invalid and password-protected documents gracefully.
3. **Reading continuity:** Recent books, per-book page and viewport restoration, stable document identity, and reliable access after restarting the app. Separate reading metadata from PDF content. Security-scoped file bookmarks, if needed for sandboxed access, are distinct from user-visible reading bookmarks.
4. **Library and customization:** Named bookmarks, search UI, table of contents, thumbnails, presets, and library browsing. Plan EPUB as a separate reflowable renderer rather than as a PDF extension. Treat DRM-protected formats as outside the initial scope.

Milestone 2 is partially implemented for performance testing: file picker, continuous reading, keyboard navigation, page entry, fit width, and graceful rejection of invalid or locked files. Remaining reader conveniences and milestones 3–4 are parked. Keep the existing surfaces while evaluating real-book responsiveness. Each later material experiment must explain a visible improvement and its measured cost; custom GPU work is not a milestone by itself.

## Performance principles

- Avoid any app-driven animation or recurring texture generation while a page is idle.
- Keep expensive work off the UI path where framework thread-safety allows; isolate ownership rather than concurrently accessing the same PDF objects without a documented guarantee.
- Generate and cache the texture once per necessary configuration, not once per frame.
- Bound document, thumbnail, and any custom page-render caches. Never pre-render an entire book by default.
- Cancel stale background work when the reader changes documents or navigation direction.
- Start with single-page load, texture setup, resizing, memory, and idle energy on the user's Mac in release builds. Measure warm switching, page navigation, and scrolling when those features enter scope.
- Include large scanned PDFs as well as ordinary text documents in the performance samples. Set numeric budgets after a baseline; native frameworks alone do not guarantee responsiveness.

## Decisions for the next discussion

- Record the test Mac and display in detail. Setup host: Apple silicon, macOS 14.2.1, Apple Swift 5.10, Command Line Tools; full Xcode is not installed. Initial deployment target: macOS 14.
- Local sample documents supplement the generated rendering and navigation fixtures. Add a large synthetic scanned fixture when available.
- Books currently open in place. Managed imports and additional reading layouts remain deferred.

The app opens real PDFs and retains a generated baseline for comparison. Three shared base maps are cached once, while Adaptive prepares visible pages with bounded work and rejects stale results after document switches. Page overlays preserve PDFKit's native text. Measurements are recorded in RENDERING.md and PERFORMANCE.md. Full idle/GPU/energy measurements and targeted scanned/illustrated fixtures remain to be added. No third-party dependencies or system-level environment changes were introduced.
