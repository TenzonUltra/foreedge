#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_root/.build/workspace-check"
sources=()
for source in "$project_root"/Sources/Foreedge/*.swift; do
    [[ "$source" == */ForeedgeApp.swift ]] || sources+=("$source")
done
swiftc "${WORKSPACE_OPTIMIZATION:--O}" -g -I "$project_root/Sources/CSQLite" -module-cache-path "$project_root/.build/module-cache" \
    "${sources[@]}" "$project_root/Tools/WorkspaceCheck.swift" -o "$project_root/.build/workspace-check/check"
"$project_root/.build/workspace-check/check" "$project_root/.build/workspace-check"
