#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
case "$configuration" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac

# Keep compiler and package caches within the project.
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
build_options=(
    --package-path "$project_root"
    --scratch-path "$project_root/.build"
    --cache-path "$project_root/.build/package-cache"
    --config-path "$project_root/.build/package-config"
    --security-path "$project_root/.build/package-security"
    --configuration "$configuration"
)
if [[ -n "${FOREEDGE_SDK_PATH:-}" ]]; then
    build_options+=(--sdk "$FOREEDGE_SDK_PATH")
fi

swift build "${build_options[@]}" --product Foreedge
binary_directory="$(swift build "${build_options[@]}" --show-bin-path)"
app_path="$project_root/.build/app/$configuration/Foreedge.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_directory/Foreedge" "$app_path/Contents/MacOS/Foreedge"
cp "$project_root/Configuration/Info.plist" "$app_path/Contents/Info.plist"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
# Local ad-hoc signature: no developer account or signing certificate required.
/usr/bin/codesign --force --sign - --timestamp=none "$app_path"
echo "Built $app_path"
