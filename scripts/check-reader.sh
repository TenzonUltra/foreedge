#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/reader-check"
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
    "$project_root/Tools/ReaderCheck.swift" \
    -o "$project_root/.build/reader-check/check"
"$project_root/.build/reader-check/check" "$project_root/.build/reader-check"
