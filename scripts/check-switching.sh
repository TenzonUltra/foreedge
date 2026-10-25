#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -ne 1 ]; then echo "Usage: $0 /path/to/pdf-folder" >&2; exit 2; fi
mkdir -p "$project_root/.build/switch-check"
sources=()
for source in "$project_root"/Sources/Foreedge/*.swift; do
    [[ "$source" == */ForeedgeApp.swift ]] || sources+=("$source")
done
swiftc -O -I "$project_root/Sources/CSQLite" -module-cache-path "$project_root/.build/module-cache" \
    "${sources[@]}" "$project_root/Tools/SwitchCheck.swift" -o "$project_root/.build/switch-check/check"
"$project_root/.build/switch-check/check" "$project_root/.build/switch-check" "$1"
