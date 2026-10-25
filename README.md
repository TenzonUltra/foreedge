# Foreedge

A personal, native macOS PDF reader with a quiet paper surface and keyboard navigation. Books open in place; PDFs are never modified. Collections, fast book switching, tabs, and tiled study workspaces are available. Passage links and backlinks connect reading across books; indexed book/collection search is available; semantic retrieval is a later stage.

## Build and run

Requires macOS 14+ and Swift 5.10+ from Apple's Command Line Tools or Xcode. Uses Apple frameworks and system SQLite; no third-party package or developer account is needed.

```sh
./scripts/run.sh                          # Release build; restore last workspace
./scripts/run.sh release --pdf '/path/to/book.pdf'
./scripts/run.sh debug
./scripts/build.sh                        # Build without launching
./scripts/install.sh                      # Install to ~/Applications for Spotlight
```

Bundles are ad-hoc signed at `.build/app/{release,debug}/Foreedge.app`. Quit the running app before launching another build. Closing the last window quits and flushes reading state. Release builds are the performance baseline; debug builds are for development. The installed Command Line Tools emit a harmless XCTest-path warning; the standalone checks do not require XCTest. Instruments requires full Xcode, which is not installed on this machine. Because local builds are ad-hoc signed, macOS may ask for Documents-folder access again after a rebuild. Allow that system prompt for background folder discovery; reading and discovery do not bypass macOS permissions.

## Reading

Reading tiles have no header or workspace toolbar. Only panes with multiple tabs show a tab strip. Commands and appearance controls are summoned from the keyboard or macOS Reading menu. The app restores the last workspace, books, viewports, zoom modes, and appearance; a fresh library shows Open PDF and, when available, recent books.

| Action | Shortcut |
| --- | --- |
| Open PDF | Command-O |
| Fuzzy quick-open book | Command-P |
| Browse library | Command-Shift-O |
| Switch collection/folder | Command-Option-P |
| Fuzzy command palette | Command-Shift-P |
| Appearance and Vim settings | Command-comma |
| Searchable embedded contents | Command-Shift-T |
| Find words/phrases in this book | Command-F |
| Search active collection | Command-Shift-F |
| Go to page label / physical page | Command-L |
| Back / forward through jumps | Command-[ / Command-] |
| Previous / next PDF page | Command-Up / Command-Down |
| Fit width | Command-0 |
| Reading marks | Command-Shift-M |
| Copy passage/location reference | Command-Shift-C |
| Link copied passage to here | Command-Shift-L |
| References and backlinks | Command-Shift-R |
| Open copied reference | Command-Option-R |
| Compare smooth paper | Command-B |

Use arrows and Return in the command and contents pickers; Escape closes a panel. Page entry uses PDF-supplied labels (including Roman numerals), or `#12` for the 12th physical PDF page. Numeric input falls back to physical page number if no label matches. Printed contents/index pages are not automatically parsed.

Enable Vim navigation in Appearance for `j`/`k` scrolling and `/` search. `ma` sets mark **a**; backtick followed by `a` restores it. Lowercase marks belong to a book; uppercase marks can jump across books. The marks panel provides the same actions without Vim mode, and a context menu deletes marks. Key sequences expire after three seconds and Escape cancels them. Panel text entry and native shortcuts take priority.

History records deliberate page/outline/search/mark jumps, native PDF destination navigation, and successful book switches. Scrolling updates the saved viewport without adding history entries. Back/forward restores position and scale; a new jump after going back clears the forward branch. History is capped at 200 back entries.

In-book search runs on a separately owned PDF document off the UI thread. It is case/diacritic-insensitive literal search, with progressive results and a 500-match cap. It cancels obsolete queries and resolves results to native text selections. Scanned books without text need OCR, which is not implemented. Search closes after choosing a result; repeat-search navigation is a later convenience.

## Collections and quick switching

On first launch of this version, the app registers `/path/to/pdf-folder` if it exists. Use Command-Shift-O to browse. **Add Folder** registers another directory; discovery is recursive and runs in the background without loading PDF content. It refreshes on launch or with the refresh button. Folder roots are stored by path; if you move a root folder, register its new location. File-level identities and marks reconnect during discovery. Hidden files, packages, and symlink entries are skipped. Stop cancels the current scan; the folder-management menu stops scanning a registered root without removing reading records.

Command-P fuzzy-matches titles, filenames, and known authors within the active scope. Use arrows and Return to open a result at its last position. The scope picker chooses All Books, Recent, a named collection, or a registered folder. Command-Option-P provides a keyboard collection switcher. Recent includes books actually opened, not everything discovered by a scan.

Create a named collection in the library, then single-click books in All Books or a folder and use the **Collections** menu (or a row’s context menu) to add them. Command-click toggles individual books; Shift-click selects a range. The footer shows how many books are selected. Double-click a book to open it. A book may belong to several collections. Right-click a collection to rename or delete it. Removing membership or deleting a collection never changes the PDF or its marks. Each workspace remembers its active collection scope separately from its layout and reading positions.

Overlapping roots and repeated scans reconnect the same files. Ordinary renames preserve identities, memberships, and marks. Missing files retain their reading records and appear as unavailable in All Books and manual collections after a refresh. A failed or canceled scan does not empty the library. Byte-identical copies at different file identities remain separate; content hashing/deduplication is deferred.

The document cache retains at most three recently opened PDFKit documents, with a combined **64 MiB source-file-size budget**. Larger PDFs still open but are not retained in the inactive cache. Up to four visible panes also hold active document leases; panes showing the same file revision share a document, including simultaneous restoration. Inactive tabs and workspaces retain locations rather than native views. This is not a limit on rendered/total process memory; the active view and PDFKit have their own allocations. A file’s size/modification signature is checked before reuse. Cache eviction does not discard reading state.

## Workspaces and panes

Command-Control-P switches saved study contexts and manages their names. Command-Shift-P opens the command palette for split, focus, move, maximize, close, and tab actions; these commands also remain in the macOS Reading menu. A split duplicates the current reading position; open another book with Command-P in that pane. Click or scroll in a pane to focus it; a thin accent line identifies the active pane. Reading commands target that pane.

| Action | Shortcut |
| --- | --- |
| Split right / below | Command-backslash / Command-Shift-backslash |
| Focus neighboring pane | Control-Option + arrow |
| Swap pane with neighbor | Control-Option-Shift + arrow |
| Cycle next / previous pane | Control-Tab / Control-Shift-Tab |
| Maximize / restore pane | Command-Control-M |
| Close pane | Command-Control-W |
| New book tab | Command-T |
| Close current book tab | Command-Shift-W |
| Next / previous tab | Command-Shift-] / Command-Shift-[ |
| Workspace picker | Command-Control-P |

Two-point dividers separate flush-aligned tiles and remain draggable. Fit width (Command-0) follows pane and window resizing while keeping the reading position anchored; manual zoom retains its chosen scale. Directional focus and movement follow the visible geometry, prefer the closest center-aligned neighbor, and stop at outer edges. A move swaps whole panes, including their tabs and histories, and focus follows the moved pane. PDF scrollbars are hidden; trackpad scrolling and keyboard navigation remain native. Only panes with several tabs show a tab strip; single-book panes use the full reading surface. Each tab has its own position and back/forward trail; marks and appearance are shared. Workspaces save automatically, including collection scope, split ratios, active pane, tabs, and positions. Maximizing is temporary; relaunch restores the full layout.

This first version supports four visible panes. The final pane and its final tab stay open; close the window to quit. New workspaces begin empty with the current collection scope. Deleting a workspace removes only its saved arrangement, never books, collections, or marks.

## Indexed search

Command-F searches this book; Command-Shift-F searches the active collection. The scope picker also searches the whole discovered library. Results are ranked, with one row per PDF page, a section heading where the publisher supplied an outline, and an occurrence count. Phrase matches (including word forms such as group/groups) precede pages containing all the words separately. Nearby pages receive a small ranking penalty to show more varied contexts. The picker shows the top 80 pages; refine the query to narrow a broad result set.

Up/down selects a page; Option-left/right or the arrow buttons moves between its occurrences (up to 100 retained per page). Return opens the selected match, Command-Return opens it in a neighboring pane, and Command-[ returns. Single-click selects; double-click opens. Matches use original PDF character ranges, including across line breaks, common ligatures, and end-of-line hyphenation. Once opened, use Command-Shift-C to capture a search result as a passage reference.

If no page contains all the words, results may fall back to individual query words, clearly labelled **Broader match** with the words actually found. If none occur, search reports no matching passages. This is ranked lexical retrieval with word forms and transparent partial matching, not an embedding model or a claim that different mathematical concepts are equivalent. OCR and conceptual/semantic similarity remain future work.

An opened book is queued for background indexing after a short idle delay; collection/library searches queue their scoped books on demand. One utility-priority worker owns a separate PDF document and yields between pages. Searches share the index across panes, reuse extracted text while typing, and show progress plus partial results during the first build. Closing the picker cancels its query without discarding useful indexing work. Later searches and app restarts reuse the disk cache. File size and modification date invalidate a changed book's text and offsets.

Generated text lives beside the library in `Library.search-v1.sqlite` (with SQLite WAL/SHM files while open), separately from marks, links, and workspaces. It contains extracted book text and can be regenerated; no PDF is modified and no text leaves the Mac. Indexing can take several seconds on a new large book; the benchmark below distinguishes this from cached query latency.

## Passage references

Select text and press Command-Shift-C to copy a durable passage reference. Without selected text, it captures the current reading position, so scanned pages work too. Move to another passage (in any book or pane), press Command-Shift-L, optionally describe the relationship, and press Return. The copied passage points to the current passage; backlinks appear automatically. This writes personal library metadata, never PDF annotations.

Command-Shift-R opens a searchable list of outgoing links and incoming backlinks for the current page. Broaden it to This book or All links to find other connections. Arrows choose a result; Return opens it, Command-Return opens it beside the source, and Option-Return opens the other end. Double-click also opens a row. Opening beside reuses a neighboring pane, or creates a right split if there is only one pane. Command-[ returns through normal history. The menu on a selected link edits its note or removes the link; removing a link retains its independently copied passage URLs.

Copied text includes a citation and a `foreedge://reference/<id>` URL for personal notes. Opening that URL in Foreedge resolves it in this local library; it is not a portable or shared book URL. Command-Option-R opens the reference currently on the clipboard. Text anchors retain revision-specific character ranges and a short quote, and selected text is highlighted when followed. Capture is bounded to the first 16 selected pages / 64 text ranges and a 2,000-character preview. Location-only references use the saved viewport. Changed PDFs retain the old reference and report a revision mismatch rather than guessing a replacement. OCR, arbitrary region selections, and anchor repair remain future work.

## Local data and identity

Reading metadata lives in `~/Library/Application Support/Foreedge/Library.sqlite` (plus SQLite WAL/SHM files while open). On first launch, Foreedge safely copies an existing Paperman library and search index through SQLite, leaving the old files intact as a rollback copy. Version 4 stores an atomic, versioned state snapshot behind a serial I/O boundary. It contains book identities, file bookmarks, viewport state, preferences, marks, history, collections, folder roots, active scope, named workspaces with split trees and per-tab histories, passage anchors, and directed links with notes. It contains no PDF copies. Version-1, version-2, and version-3 libraries migrate automatically; the original snapshot is retained in the database’s `migration_backup` table before the first version-4 save. The previous reader becomes a single-pane “Reading desk.” Later library/search features can introduce normalized tables behind the same boundary.

Ordinary file moves reconnect through macOS file bookmarks/resource identity. Book identity is separate from each live PDF rendering instance. Modification time and byte size form the initial revision signature: a changed signature prevents restoring old marks silently. This is not a content hash and does not identify byte-identical duplicates or safely relocate passages across editions. An unreadable/newer library is left untouched, with an error shown. Failed PDF opens preserve the currently displayed book.

Viewport writes are debounced after scrolling and flushed on orderly quit; abrupt process termination may lose the last unsaved fraction of a second. Marks/preferences are queued for atomic saving. Password-protected PDFs currently require an unlocked copy. There is no annotation export or file-relink UI yet. If a saved tab’s PDF has changed, its old location is retained and a warning is shown; open the book normally to choose a new position.

## Paper rendering

Plain, Warm, and Paper modes remain available. Paper offers Original, Balanced (default), Soft relief, and Adaptive. Warmth, Brightness, and Grain adjust the treatment. Brightness affects rendered color, not the display backlight; Original retains its historical brightness behavior. Command-B temporarily compares smooth paper without changing the selected surface.

PDFKit keeps native text and selection. Page-confined, click-through multiply layers use deterministic cached grayscale maps. Three base images are shared once per process; Adaptive prepares visible pages with a six-page cache per pane and up to four queued pages per pane. One serial worker shares revision/page results across panes, retaining at most twelve page maps and four worker documents globally. Temporary buffers, active overlays, PDFKit, and GPU resources are additional allocations. No app-driven frame loop or book-wide texture preparation is introduced. See [RENDERING.md](RENDERING.md) and [PERFORMANCE.md](PERFORMANCE.md) for measurements and limits.

The command palette includes developer commands for the generated rendering fixture and CPU loading measurements. Those measurements are not GPU cost, FPS, or first-frame latency.

## Verification

```sh
./scripts/check-rendering.sh
./scripts/check-reader.sh
./scripts/check-workspace.sh
./scripts/benchmark-search.sh '/path/to/book.pdf'  # Isolated cold/warm search measurements
./scripts/check-search.sh                  # Persistent index, grouping, collection search, native navigation
./scripts/check-references.sh              # Passage links, backlinks, keyboard flow, migration
./scripts/check-tiling.sh
./scripts/check-catalogue.sh
./scripts/check-library-interaction.sh
./scripts/check-switching.sh "/path/to/pdf-folder"
./scripts/check-books.sh '/path/to/book.pdf' '/path/to/another.pdf'
```

Rendering checks cover brightness, native selection, overlay placement, and image reuse. Reader checks use a generated 1,000-page fixture to verify navigation and bounded Adaptive work. Workspace checks use isolated databases and generated books to cover restart restoration, viewport/marks/history, file moves, changed-file rejection, background search cancellation, and command dispatch. Catalogue checks cover discovery, overlapping membership, migration, cache reuse/eviction, and native quick-picker typing. The switching check uses the Sample A/Sample B/Sample C filenames in the test Books folder, with an isolated in-memory session. The book harness samples real PDFs read-only.

Tiling checks exercise shared-document viewports, text selection, directional focus/swaps in grid and unequal layouts, edge behavior, headerless tile alignment, responsive width fitting, manual zoom and reading anchors through pane/window resizing, hidden scrollbars, tabs, maximize/resize, restart, and bounded shared Adaptive work. Pass two PDF paths to `check-tiling.sh` to repeat the checks read-only on real books with an isolated temporary library. It reports process memory and synchronous jump/return intervals for 1/2/4 panes; these are not frame timings.

Library interaction checks send native mouse events to toolbar padding, sidebar whitespace, and book-row whitespace, and invoke the Collections popup actions, covering single-click selection, Command/Shift multi-selection, membership persistence, scope changes, and double-click opening.

Artifacts live under ignored `.build/`. AppKit view-cache PNGs help inspect shell/panel layout but omit some native/composited content; they are not screenshots of the final on-screen PDF rendering.

## Code map

- `Catalogue.swift` / `CataloguePanels.swift`: folder discovery, scoped fuzzy matching, collections, and library/quick-open UI.
- `WorkspaceState.swift` / `WorkspaceSession.swift` / `WorkspaceView.swift`: durable split trees, tabs, workspace switching, native focus, and resizing.
- `LibraryContext.swift`: shared library, discovery, preferences, and persistence owner.
- `DocumentPool.swift`: bounded, main-actor-owned PDF document cache.
- `ReaderSession.swift`: current pane's reading state, navigation, restoration, and marks.
- `LibraryStore.swift`: durable book/location models and serial SQLite persistence.
- `ReaderCommands.swift`: shared menu/palette command definitions and routing.
- `ReaderPanels.swift`: commands, appearance, outline, find, page, and mark panels.
- `BookSearch.swift`: cancellable text extraction/search and small-list fuzzy matching.
- `ReaderPDFView.swift` / `PDFSurface.swift`: native navigation hooks and stable PDFKit bridge.
- `ReadingStudy.swift`: quiet reading shell; its historical filename is retained.
- `PaperWorker.swift`, `PaperTexture.swift`, `PaperOverlay.swift`, `PaperAppearance.swift`: paper rendering.
- `BaselineDocument.swift`: repeatable developer fixture.

See [WORKSPACE-DESIGN.md](WORKSPACE-DESIGN.md) for the staged academic-reader design and remaining work.

Reference checks use generated temporary PDFs, a separate SQLite library, and a private pasteboard. They verify passage and viewport capture, highlighting, keyboard linking/backlinks, cross-book history, adjacent-pane reuse, URL parsing, note persistence/deletion, unchanged PDF bytes, revision rejection, and a byte-for-byte schema-3 migration backup.

Search checks cover shared extraction, cached restart, page grouping/occurrences, phrase ordering, partial-match labelling, Unicode/line-break offset recovery, query cancellation, collection scope, native keyboard open/beside/back navigation, unchanged PDFs, and revision invalidation.
