#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
app_dir="dist/Reckon.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" != "v$version" ]]; then
  echo "Release tag must match the app's CFBundleShortVersionString." >&2; exit 1
fi
codesign --verify --deep --strict "$app_dir"
node scripts/check-release-privacy.mjs --app "$app_dir"
mkdir -p dist/release
archive="Reckon-${version}-macOS-$(uname -m).zip"
ditto -c -k --keepParent --sequesterRsrc "$app_dir" "dist/release/$archive"
(cd dist/release && shasum -a 256 "$archive" > "$archive.sha256")
echo "Packaged dist/release/$archive"
