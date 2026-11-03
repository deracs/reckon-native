#!/bin/zsh
set -euo pipefail
check_runs=1
if [[ $# -eq 2 && "$1" == --runs && "$2" == <1-> ]]; then
  check_runs="$2"
elif [[ $# -ne 0 ]]; then
  print -u2 'Usage: ./scripts/check-window-lifecycle.sh [--runs positive-count]'
  exit 2
fi
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build --product Reckon -Xswiftc -warnings-as-errors
binary_dir="$(swift build --show-bin-path)"
app_dir="$project_dir/.build/window-checks/ReckonWindowChecks.app"
framework_dir="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
ditto Resources/Fonts "$app_dir/Contents/Resources/Fonts"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier nz.reckon.native.windowchecks' "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ReckonWindowChecks' "$app_dir/Contents/Info.plist"
ditto "$framework_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
# Import the debug app module and link its actual objects, including the delegate.
# SwiftPM renames the app's entry point, so the check runner supplies its own main.
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  Tests/ReckonWindowTests/ReckonWindowCheckRunner.swift \
  Tests/ReckonWindowTests/ReckonWindowFocusHelper.swift \
  -Xlinker -filelist -Xlinker "$binary_dir/Reckon.product/Objects.LinkFileList" \
  -I "$binary_dir/Modules" -F "$framework_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app_dir/Contents/MacOS/ReckonWindowChecks"
codesign --force --sign - "$app_dir"
helper_dir="$project_dir/.build/window-checks/ReckonFocusHelper.app"
mkdir -p "$helper_dir/Contents/MacOS" "$helper_dir/Contents/Frameworks"
cp "$app_dir/Contents/Info.plist" "$helper_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier nz.reckon.native.windowchecks.focushelper' "$helper_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Reckon Focus Helper' "$helper_dir/Contents/Info.plist"
cp "$app_dir/Contents/MacOS/ReckonWindowChecks" "$helper_dir/Contents/MacOS/ReckonWindowChecks"
ditto "$framework_dir/Sparkle.framework" "$helper_dir/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$helper_dir"
for ((check_run = 1; check_run <= check_runs; check_run++)); do
  print "Window lifecycle run $check_run/$check_runs"
  "$app_dir/Contents/MacOS/ReckonWindowChecks" --demo
done
