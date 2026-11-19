#!/bin/sh
# Builds hub/ in release mode and assembles build/LocalHub.app (ad-hoc signed).
# Usage: scripts/make-app.sh [--debug]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
config=release
[ "${1:-}" = "--debug" ] && config=debug

cd "$root/hub"
swift build -c "$config" --product LocalHubApp
bin=$(swift build -c "$config" --show-bin-path)

app="$root/build/LocalHub.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/LocalHubApp" "$app/Contents/MacOS/LocalHub"
cp "$root/assets/brand/LocalHub.icns" "$app/Contents/Resources/LocalHub.icns"
for bundle in "$bin"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done

version=$(sed -n 's/^public let hubVersion = "\(.*\)"/\1/p' Sources/LocalHubCore/HubServer.swift)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.localhub.LocalHub</string>
  <key>CFBundleName</key><string>LocalHub</string>
  <key>CFBundleDisplayName</key><string>LocalHub</string>
  <key>CFBundleExecutable</key><string>LocalHub</string>
  <key>CFBundleIconFile</key><string>LocalHub.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>LocalHub lets your paired tablets and computers on this network use the AI apps running on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$app"
echo "$app"
