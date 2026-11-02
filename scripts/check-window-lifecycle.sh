#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build --product Reckon -Xswiftc -warnings-as-errors
binary_dir="$(swift build --show-bin-path)"
app_dir="$project_dir/.build/window-checks/ReckonWindowChecks.app"
framework_dir="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier nz.reckon.native.windowchecks' "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ReckonWindowChecks' "$app_dir/Contents/Info.plist"
ditto "$framework_dir/Sparkle.framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
# Import the debug app module and link its actual objects, including the delegate.
# SwiftPM renames the app's entry point, so the check runner supplies its own main.
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  Tests/ReckonWindowTests/ReckonWindowCheckRunner.swift \
  -Xlinker -filelist -Xlinker "$binary_dir/Reckon.product/Objects.LinkFileList" \
  -I "$binary_dir/Modules" -F "$framework_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app_dir/Contents/MacOS/ReckonWindowChecks"
codesign --force --sign - "$app_dir"
"$app_dir/Contents/MacOS/ReckonWindowChecks" --demo
