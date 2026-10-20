#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    print -u2 "Usage: ./scripts/build-app.sh [release|debug]"
    exit 1
fi
"$project_dir/scripts/build-icon.sh"
node_binary="${RECKON_NODE_BINARY:-$(command -v node)}"
node_binary="$($node_binary -p 'process.execPath')"
"$node_binary" -e 'if (Number(process.versions.node.split(".")[0]) < 24) { console.error("The bundled backend requires Node 24 or later."); process.exit(1) }'
"$node_binary" "$project_dir/scripts/build-backend.mjs"
node_license="${RECKON_NODE_LICENSE:-${node_binary:h:h}/LICENSE}"
if [[ ! -f "$node_license" ]]; then
    print -u2 "Node LICENSE was not found. Set RECKON_NODE_LICENSE to the runtime license file."
    exit 1
fi
if ! otool -L "$node_binary" | awk 'NR > 1 && $1 !~ /^\/(usr\/lib|System\/Library)\// { foreign=1 } END { exit foreign }'; then
    print -u2 "Use a standalone Node runtime that depends only on macOS system libraries."
    exit 1
fi
swift build -c "$configuration" --product Reckon -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/reckon-native"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/dist/Reckon.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources/Backend"
cp "$binary_dir/Reckon" "$app_dir/Contents/MacOS/Reckon"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/Reckon.icns" "$app_dir/Contents/Resources/Reckon.icns"
cp "$node_binary" "$app_dir/Contents/Helpers/node"
cp "$node_license" "$app_dir/Contents/Resources/Backend/NODE-LICENSE.txt"
cp "$project_dir/.build/backend/backend.cjs" "$app_dir/Contents/Resources/Backend/backend.cjs"
cp "$project_dir/.build/backend/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/Backend/THIRD-PARTY-NOTICES.txt"
strip -S "$app_dir/Contents/MacOS/Reckon"
chmod +x "$app_dir/Contents/Helpers/node"
codesign --force --sign - "$app_dir/Contents/Helpers/node"
codesign --force --sign - "$app_dir"
print "Built $app_dir"
