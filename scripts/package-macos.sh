#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -quiet -scheme Coffer -configuration Release \
    -derivedDataPath .build/macos12-universal \
    -destination 'generic/platform=macOS' \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build

app_bundle=".build/macos12-universal/Build/Products/Release/Coffer.app"
codesign --verify --deep --strict "$app_bundle"
for architecture in arm64 x86_64; do
    lipo "$app_bundle/Contents/MacOS/Coffer" -verify_arch "$architecture"
done
minimum_version=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_bundle/Contents/Info.plist")
if [[ "$minimum_version" != "12.0" ]]; then
    printf 'Unexpected minimum macOS version: %s\n' "$minimum_version" >&2
    exit 1
fi

mkdir -p .build/distribution
package_dir=$(mktemp -d "$PWD/.build/distribution/package.XXXXXX")
ditto "$app_bundle" "$package_dir/Coffer.app"
cp docs/install-macos.md "$package_dir/INSTALL.md"
ditto -c -k --sequesterRsrc "$package_dir" .build/distribution/Coffer-macOS12-universal.zip
shasum -a 256 .build/distribution/Coffer-macOS12-universal.zip \
    > .build/distribution/Coffer-macOS12-universal.zip.sha256
printf 'Package: %s/.build/distribution/Coffer-macOS12-universal.zip\n' "$PWD"
