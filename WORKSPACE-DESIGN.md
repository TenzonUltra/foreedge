# Academic reading workspace — proposed design

Status: implementation started September 24, 2026. Rendering is accepted for now. The first increment implements the quiet shell, persistence, command palette, outline/page/text navigation, history, and local/global marks. Slice 3 now adds folder discovery, overlapping named collections, scoped fuzzy quick-open, recent books, and a bounded warm-document cache. Slice 4 now adds named workspaces, a four-pane split tree, independent tabs/positions/histories, focus/move/maximize/close controls, and automatic layout restoration. Directional focus uses Control-Option-arrows; adding Shift swaps panes. The reading surface has aligned, headerless tiles with a strip only for multiple tabs, two-point dividers, and no PDF scrollbars or workspace toolbar. Slice 5 adds stable passage anchors, directed personal links with notes, page/book backlinks, keyboard follow/beside navigation, and local passage URLs. Slice 6 adds a shared persistent SQLite FTS5 text index, page-grouped ranked retrieval, transparent broader-word fallback, and book/collection/library search with native passage navigation. Semantic retrieval remains future work.

Implementation notes: the initial store uses an atomic versioned JSON snapshot inside SQLite, rather than separate tables for every model; each pane now owns a reader session with independent tab histories; one LibraryContext owns shared metadata and discovery. Revision detection uses modification time/size, not content hashing; overlapping roots deduplicate file identity, while byte-identical copies remain separate. Schema 4 preserves the original schema-1, schema-2, or schema-3 snapshot during migration. Named bookmarks, manual printed-page offsets, JSON export, and anchor repair/relink interfaces remain deferred. See README.md for supported commands and limitations.

## Product shape

A personal, local academic reading workspace: a quiet book surface, fast keyboard navigation, several independent reading positions, and durable connections between passages. Open PDFs in place. No accounts, collaboration, cloud service, or general plugin framework in this phase.

Default window: headerless reading panes, with a strip only when a pane has multiple tabs. Hide rendering controls in Appearance settings and diagnostics in a developer command. The catalogue/outline sidebar and reference pane are summoned when needed. No permanent activity feed or semantic dashboard. Restore the previous session; show a minimal open/recent view when no session exists. Retain the generated rendering fixture through a developer command.

Vocabulary (collections and separate workspaces confirmed):

- **Book:** a stable local record for a document, independent of its filename, opened views, and catalogue membership.
- **Catalogue:** a named collection, such as Topology or Current Reading. Books can belong to several. A disk folder may supply a catalogue, but membership need not move files.
- **Workspace:** a saved study context, such as Research seminar: active catalogue, split layout, open book tabs, and reading positions.
- **Pane:** one independently navigable view. Two panes can show different places in the same book.
- **Location:** a durable destination within a specific book revision, used by history, marks, searches, notes, and links.

Use books/locations/workspace state from the beginning. Add catalogue and workspace management interfaces when they become useful; avoid front-loading an elaborate library UI.

## Feature sequence and completion checks

| Slice | Visible result | Technical work | Completion check |
| --- | --- | --- | --- |
| 1. Quiet shell and continuity | Minimal toolbar; Appearance settings; reopen where you left off; command palette | Stable book identity, location/viewport capture, versioned local store, command routing, one pane model | Quit/relaunch restores book, position, zoom mode, appearance; palette and menu invoke identical actions; scrolling remains responsive |
| 2. Navigate and return | Searchable outline, page-label jumps, in-book find, back/forward, keyboard marks | Shared navigation operation; per-pane jump history; local/global marks; optional Vim bindings | Jump to a chapter, find a passage, set a mark, follow a link, and return to the original viewport entirely by keyboard |
| 3. Catalogues and quick switching | Register Books folder; named overlapping collections; fuzzy quick-open; recent books; catalogue switch | Background file discovery, metadata, duplicate/relocation handling, capped warm-document cache | Switch between Sample A/Sample B/Sample C and back without losing each position; same book in two catalogues retains one identity and marks |
| 4. Tiled study workspaces | Split horizontally/vertically, focus/move/close panes, independent tabs, maximize/restore pane, save layout | Split-tree layout, per-pane navigation and viewport, shared document resources, global texture budget | Same book in two panes remains independent; two different books scroll correctly; close/relaunch restores layout; 1/2/4-pane memory and responsiveness comparison |
| 5. References and research navigation | Peek a destination, pin it into a pane, link passages across books, backlinks, short link notes | Region/text anchors, reference edges, bounded preview lifecycle, promote preview to normal pane | Connect a definition in Sample A to a passage in Sample B; reopen, follow in either direction, and return without losing the reading position |
| 6. Search across the collection | Ranked passages with snippets; book/catalogue/workspace scope; small reading-history boost | Incremental text extraction, lexical index, progressive cancellable results, explicit ranking features | Useful exact results arrive without waiting for semantic work; stale results never replace a newer query; changed PDFs invalidate old index entries |
| 7. Optional semantic assistance | Suggested subjects, related passages, alternate treatments, assisted reference resolution | Versioned chunk index, replaceable retrieval/enrichment providers, evidence and suggestion provenance | Every suggested relationship opens supporting source passages; accepted/manual links remain distinguishable from inferred ones; reading works while indexing is disabled |

This order places cheap fuzzy book/outline/command matching early. Collection-wide full-text indexing and semantic retrieval are later. Slice 5 can initially create references entirely by hand; it does not depend on slice 6 or 7.

## Navigation contract

All deliberate jumps go through one operation: destination, originating pane, presentation (`replace`, `peek`, `adjacentPane`), and reason (`outline`, `search`, `mark`, `reference`, `page`, `history`). Menus, keyboard bindings, palette entries, and future semantic results use that operation.

Each pane has a back/forward trail spanning books. Capture departure viewport and destination on deliberate jumps. Ordinary wheel/trackpad scrolling updates the current position without creating hundreds of history entries. Revisiting through history must not recursively append history. New jumps after going back discard the forward branch. Preview does not change the original pane or its history until committed. Track PDFKit's own internal link navigation too, rather than maintaining a separate incompatible trail.

Offer native shortcuts and optional Vim-style navigation when the PDF pane has focus. Proposed marks: `ma` sets a local mark; backtick then `a` restores it. Uppercase marks are workspace-independent cross-book destinations. Named bookmarks use the same location model. Key sequences must not consume text typed into search, notes, or page fields; show pending sequences briefly, support Escape, and keep bindings configurable. Final shortcut choices should be checked against macOS and existing app shortcuts.

Separate three meanings of “index”:

1. Embedded PDF table of contents: expose and fuzzy-filter it first.
2. Printed contents or back-of-book index: initially pin a location and peek at it; those pages are not necessarily machine-readable navigation structures.
3. Extracted headings/definitions/theorems: later inferred structures, visibly distinct from the publisher's outline.

Store physical page index separately from printed page label. Support Roman front matter and document page labels where supplied; provide manual page-offset mapping where absent. Do not assume one offset covers every PDF section. OCR and automatic printed-index parsing are later work. When text or outline is absent, say so and retain page/region navigation.

## Model and implementation boundaries

Keep Swift + SwiftUI/AppKit + PDFKit and the existing paper rendering. Introduce a few concrete types/services inside the existing executable; a package or plugin split is unnecessary now.

| Model/service | Responsibility |
| --- | --- |
| `BookRecord` / `DocumentRevision` | Stable book UUID; file locator/bookmark; metadata; revision fingerprint. Distinguish the saved identity from an in-memory document instance |
| `BookLocation` / `TextAnchor` | Book/revision ID, physical page, normalized page coordinates; optional quoted text and surrounding context/region |
| `ViewportState` | Location, fit mode or explicit zoom, alignment; restore only after view layout is ready |
| `PaneSession` | Active book/tab, viewport, selection, jump trail. PDFView stays within the native adapter |
| `WorkspaceState` | Active catalogue and pane; recursive split tree with axis/ratio or leaf pane ID; per-pane tabs |
| `CommandRegistry` | Stable command IDs, availability, parameters, display title, keyboard bindings; dispatch to the focused pane |
| `LibraryStore` | Durable metadata, locations, marks, collections, workspaces, references, and schema migrations |
| `DocumentPool` | Bounded live document handles and warm inactive books; clear ownership of main-actor PDFKit objects |
| `SearchService` | Query + scope + context in; cancellable batches of source-backed results out |
| `ReferenceStore` | Directed location-to-location edges with relation, note, provenance; backlinks queried from incoming edges |

The current `ReaderBook.id` is recreated on every open and cannot identify persistent marks. `ReaderSession` combines file loading, one-book state, and view commands; split those responsibilities incrementally while implementing slices 1–4. Do not simply instantiate the whole current singleton-based reader in every tile.

The workspace implementation gives `PaperWorker` a four-document LRU and twelve shared Adaptive page results keyed by file identity/revision/page. Per-view caches remain capped at six maps, with four visible panes maximum. Serial worker execution deduplicates generation; simultaneous native loads are also coalesced. Active native document leases are shared across PDFViews, with independent viewport and selection behavior verified. The following remains the direction for further tuning: Before tiling, introduce bounded worker document ownership keyed by book revision and shared Adaptive results keyed by revision/page/render configuration. Deduplicate in-flight jobs, prioritize visible panes, and release documents/images when no longer needed. Start with serial background work and measure before adding concurrency. PDFKit objects used for display remain main-actor-owned; extraction/render workers own separate documents. Verify whether sharing one display PDFDocument among views behaves correctly; use independent handles if necessary without duplicating persistent identity.

Proposed persistence: a local SQLite database, behind a serial store boundary, with versioned migrations. Structured records hold books/marks/links; a versioned JSON value can hold the split tree. Commit marks and explicit edits promptly; debounce transient viewport saves and flush on orderly shutdown. Keep a simple JSON export for personal annotations/workspace metadata. Decide direct SQLite versus a small Swift wrapper when implementing storage; no dependency added for this proposal.

Use file resource identity/bookmarks to reconnect ordinary moves, and background content fingerprinting to recognize exact duplicate/replaced files. Do not block book opening on hashing. A revised edition is not automatically the same content. If an anchor no longer resolves, retain the record and offer relocation; never silently claim an incorrect passage is the original. Text context helps later repair but cannot guarantee it.

## Search and future semantic engine

Use distinct matching strategies behind a consistent search UI:

- Small lists (books, outline entries, marks, commands): fast local fuzzy matching.
- Long text: incremental lexical full-text index with page/chunk provenance; FTS5 is a candidate, not a generic typo-tolerant matcher.
- Behavior: modest boosts for explicitly chosen results, recent books, pinned material, and current catalogue. Avoid treating every scroll/pause as interest or understanding. Preserve strong exact matches, allow neutral ranking, and keep order stable during keyboard selection.
- Semantic: additional retrieval and enrichment providers, not a prerequisite for opening or navigating books.

A search result should carry a stable ID, book location, snippet, result kind, score components/reason, and source revision. A provider should accept query/scope/context and support cancellation and incremental results. The UI only needs to render and navigate those results; it should not depend on which embedding model or service produced them.

Index incrementally in a low-priority worker: page text with geometry where available → section-aware chunks → lexical index → optional embeddings/inferred relationships. Bound queues and memory; suspend or reduce work during active navigation. Persist extraction/model versions and checkpoints; rebuild derived indexes when necessary without touching user marks or links. Math notation, scans, multi-column text, and differing terminology need targeted evaluation; embeddings alone will not reliably resolve theorem references.

User-created collections and relationships are authoritative personal records. Inferred subjects and links live alongside them with provenance, evidence, and an accept/dismiss state. Subject membership is many-to-many: topology and geometry may overlap. Begin with a “related passages” list and suggested tags. A graph database, elaborate ontology, or graph visualization is not required. Model/runtime choice, local versus remote inference, OCR engine, and vector storage remain deferred until there is an actual benchmark and use case.

## Evaluation and additional ideas

Evaluate navigation using concrete tasks, not feature count: resume yesterday's paragraph; find a definition and return; compare two treatments; reopen a multi-book study session. Track interaction count, wrong destinations, and perceived latency alongside measured timings.

Provisional performance goals, to validate on this Mac: visible command feedback within a frame when idle; warm small-list search p95 under 50 ms at a declared corpus size. Measure cold and warm book switching separately and compare presented-frame pacing and memory at 1/2/4 panes. These are proposed goals, not existing guarantees. Indexing must not become a dependency of the reading path.

Prioritized extra ideas:

- **Peek → pin:** inspect a definition without losing context, then keep it beside the book if useful.
- **Reading desk:** restore a subject-specific arrangement, including two positions in the same book.
- **Reference shelf:** a few pinned definitions, theorem statements, or diagrams represented by source locations; later add region previews.
- **Copy passage link:** a durable internal location link for personal notes; register an app URL scheme only when external linking is implemented.
- **Manual subject/relationship labels:** useful immediately and valuable evidence for future semantic suggestions.

Defer a full note editor, automatic theorem understanding, learned ranking, graph visualization, EPUB, syncing, and renderer replacement. Brief notes on links/marks are sufficient to test the academic workflow first.

## References

- [Sioyek usage](https://sioyek-documentation.readthedocs.io/en/latest/usage.html): precedent for marks, history, previews, portals, and keyboard commands. Borrow interaction principles while choosing our own workspace model.
- [PDFDocument outlineRoot](https://developer.apple.com/documentation/pdfkit/pdfdocument/outlineroot): native embedded outline access.
- [PDFPage label](https://developer.apple.com/documentation/pdfkit/pdfpage/label): labels distinct from physical page indices.
- [SQLite FTS5](https://www.sqlite.org/fts5.html): lexical indexing, ranking, and snippets. Verify system build capabilities before implementation.
