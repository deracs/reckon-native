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
cargo reckon build-backend
# Clang module-cache breadcrumbs point to unavailable .pcm files after path remapping.
swift build -c "$configuration" --product Reckon -Xswiftc -warnings-as-errors -Xswiftc -Xfrontend -Xswiftc -no-clang-module-breadcrumbs -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/reckon-native"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/dist/Reckon.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/Frameworks" "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources/Backend"
cp "$binary_dir/Reckon" "$app_dir/Contents/MacOS/Reckon"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/Reckon.icns" "$app_dir/Contents/Resources/Reckon.icns"
cp "$project_dir/.build/rust/release/reckon-backend" "$app_dir/Contents/Helpers/reckon-backend"
cp "$project_dir/.build/backend/THIRD-PARTY-NOTICES.txt" "$app_dir/Contents/Resources/Backend/THIRD-PARTY-NOTICES.txt"
sparkle_dir="$project_dir/.build/artifacts/sparkle/Sparkle"
ditto "$sparkle_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_dir/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"
strip -S "$app_dir/Contents/MacOS/Reckon"
chmod +x "$app_dir/Contents/Helpers/reckon-backend"
codesign --force --sign - "$app_dir/Contents/Helpers/reckon-backend"
codesign --force --sign - "$app_dir"
print "Built $app_dir"
