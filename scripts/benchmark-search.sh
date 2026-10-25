#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /path/to/book.pdf [cache.sqlite]" >&2
    exit 2
fi
mkdir -p "$project_root/.build/search-check"
swiftc -O -I "$project_root/Sources/CSQLite" -module-cache-path "$project_root/.build/module-cache" \
    "$project_root/Sources/Foreedge/PDFSource.swift" "$project_root/Sources/Foreedge/SearchIndex.swift" \
    "$project_root/Tools/SearchBenchmark.swift" -o "$project_root/.build/search-check/benchmark"
"$project_root/.build/search-check/benchmark" "$1" "${2:-$project_root/.build/search-check/benchmark.sqlite}"
