#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
iconset="$project_dir/.build/Reckon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$project_dir/Resources/AppIcon-source.png" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$project_dir/Resources/AppIcon-source.png" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$project_dir/Resources/Reckon.icns"
