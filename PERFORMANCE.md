# Performance notes

Foreedge keeps its repeatable checks independent of a personal library. Generated PDFs cover rendering, navigation, catalogues, tiling, references, and indexed search. Optional real-document benchmarks accept paths at runtime; their inputs and generated results remain ignored by Git.

## Current constraints

- PDF files remain file-backed and are never copied or modified.
- Paper textures are generated once and shared across pages.
- Adaptive analysis runs on a serial worker, cancels stale work, and uses bounded caches.
- Inactive documents use a three-entry, 64 MiB source-size cache.
- Workspaces support at most four visible panes.
- Search extraction is incremental, cancellable, and persisted by document revision.

These bounds control Foreedge-owned work. PDFKit, Core Graphics, and the macOS compositor keep their own caches, so they do not establish a total process-memory limit.

## Reproduce

```sh
./scripts/build.sh release
./scripts/check-rendering.sh
./scripts/check-reader.sh
./scripts/check-catalogue.sh
./scripts/check-workspace.sh
./scripts/check-tiling.sh
./scripts/check-search.sh
./scripts/check-references.sh
```

Optional local samples:

```sh
./scripts/check-books.sh /path/to/sample.pdf
./scripts/check-switching.sh /path/to/pdf-folder
./scripts/benchmark-search.sh /path/to/sample.pdf "search phrase"
```

Generated results live under `.build/` and are not committed.

## Interpretation

The standalone checks measure CPU-side operations and data-structure limits. They do not measure presented frame pacing, GPU utilization, idle energy, or end-to-end input latency. Those require release builds and Instruments on the machine being evaluated.

Compare cold and warm document opens separately. For scrolling, compare identical pages and directions with Plain and Paper surfaces after caches are warm. Record the OS, hardware, display scale, refresh rate, document characteristics, and exact build locally with the result rather than adding personal test-library details to the repository.
