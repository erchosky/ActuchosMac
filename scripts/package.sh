#!/bin/sh
# Compila ActuchosMac en Release (firma ad hoc) y genera un ZIP en dist/.
set -eu

cd "$(dirname "$0")/.."
DERIVED_DATA="${TMPDIR:-/tmp}/ActuchosMac-DerivedData"

xcodebuild \
  -project ActuchosMac.xcodeproj \
  -scheme ActuchosMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

mkdir -p dist
APP="$DERIVED_DATA/Build/Products/Release/ActuchosMac.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="dist/ActuchosMac-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc "$APP" "$ZIP"
echo "Creado $ZIP"
