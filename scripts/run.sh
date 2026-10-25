#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
if [ "$#" -gt 0 ]; then shift; fi
"$project_root/scripts/build.sh" "$configuration"
exec "$project_root/.build/app/$configuration/Foreedge.app/Contents/MacOS/Foreedge" "$@"
