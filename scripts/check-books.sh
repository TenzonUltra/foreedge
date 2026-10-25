#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 /path/to/book.pdf [more.pdf ...]" >&2
    exit 2
fi
mkdir -p "$project_root/.build/book-check"
swiftc -O -I "$project_root/Sources/CSQLite" -module-cache-path "$project_root/.build/module-cache" \
    "$project_root/Sources/Foreedge/PaperAppearance.swift" \
    "$project_root/Sources/Foreedge/PaperTexture.swift" \
    "$project_root/Sources/Foreedge/PaperOverlay.swift" \
    "$project_root/Sources/Foreedge/PDFSource.swift" \
    "$project_root/Sources/Foreedge/PaperWorker.swift" \
    "$project_root/Sources/Foreedge/ReaderPDFView.swift" \
    "$project_root/Sources/Foreedge/PDFSurface.swift" \
    "$project_root/Sources/Foreedge/BaselineDocument.swift" \
    "$project_root/Sources/Foreedge/Catalogue.swift" \
    "$project_root/Sources/Foreedge/DocumentPool.swift" \
    "$project_root/Sources/Foreedge/ReadingReferences.swift" \
    "$project_root/Sources/Foreedge/LibraryStore.swift" \
    "$project_root/Sources/Foreedge/SearchIndex.swift" \
    "$project_root/Sources/Foreedge/BookSearch.swift" \
    "$project_root/Sources/Foreedge/LibraryContext.swift" \
    "$project_root/Sources/Foreedge/WorkspaceState.swift" \
    "$project_root/Sources/Foreedge/WorkspaceSession.swift" \
    "$project_root/Sources/Foreedge/ReaderSession.swift" \
    "$project_root/Tools/BookBenchmark.swift" \
    -o "$project_root/.build/book-check/check"
"$project_root/.build/book-check/check" "$project_root/.build/book-check" "$@"
