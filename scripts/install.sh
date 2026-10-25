#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$HOME/Applications/Foreedge.app"

"$project_root/scripts/build.sh" release
mkdir -p "$(dirname "$destination")"
/usr/bin/ditto --rsrc --extattr "$project_root/.build/app/release/Foreedge.app" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"

echo "Installed $destination"
