#!/bin/bash
# Ksign Next — build script (from the master prompt §25).
# Requires a real macOS + Xcode environment. This machine (Linux) cannot
# run xcodebuild — see Documentation/Readiness-Report.md.
set -euo pipefail
PROJECT="KsignNext.xcodeproj"
SCHEME="KsignNext"
CONFIGURATION="Release"
ARCHIVE_PATH="./build/KsignNext.xcarchive"
EXPORT_PATH="./build/Export"
mkdir -p ./build
xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme "$SCHEME"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "./ExportOptions.plist"
echo "Build completed"
