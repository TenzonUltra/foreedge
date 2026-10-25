#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/catalogue-check"
sources=()
for source in "$project_root"/Sources/Foreedge/*.swift; do
    [[ "$source" == */ForeedgeApp.swift ]] || sources+=("$source")
done
swiftc -O -I "$project_root/Sources/CSQLite" -module-cache-path "$project_root/.build/module-cache" \
    "${sources[@]}" "$project_root/Tools/CatalogueCheck.swift" -o "$project_root/.build/catalogue-check/check"
"$project_root/.build/catalogue-check/check" "$project_root/.build/catalogue-check"
