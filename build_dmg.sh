#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="DiskTwin"
VERSION="1.1.0"
DMG_NAME="${APP_NAME}-v${VERSION}-macOS-arm64.dmg"
DIST_DIR="${SCRIPT_DIR}/dist"
DOCS_DIR="${SCRIPT_DIR}/docs"
STAGE_DIR="$(mktemp -d)"

echo "==> 1. Compiling ${APP_NAME}.app (arm64, macOS 14.0+)..."
mkdir -p "/Applications/${APP_NAME}.app/Contents/MacOS"
mkdir -p "/Applications/${APP_NAME}.app/Contents/Resources/icons"

cp "${SCRIPT_DIR}/disk_twin.py" "/Applications/${APP_NAME}.app/Contents/Resources/disk_twin.py"
chmod +x "/Applications/${APP_NAME}.app/Contents/Resources/disk_twin.py"
cp "${SCRIPT_DIR}/icons/"*.svg "/Applications/${APP_NAME}.app/Contents/Resources/icons/"

cp "${SCRIPT_DIR}/disk_twin.py" ~/.disk-twin/disk_twin.py

swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    "${SCRIPT_DIR}/DiskTwin.swift" \
    -o "/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" \
    -framework Cocoa

codesign --force --deep --sign - "/Applications/${APP_NAME}.app"

rm -rf "${SCRIPT_DIR}/${APP_NAME}.app"
cp -R "/Applications/${APP_NAME}.app" "${SCRIPT_DIR}/${APP_NAME}.app"

echo "==> 2. Staging DMG contents..."
cp -R "/Applications/${APP_NAME}.app" "${STAGE_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGE_DIR}/Applications"

cat << 'EOF' > "${STAGE_DIR}/Quick Start Guide.txt"
DiskTwin — macOS SSD & MicroSD Chameleon Mirror
===============================================

Installation:
1. Drag DiskTwin.app into the Applications folder.
2. Double-click DiskTwin.app in Applications to launch the Menu Bar utility.
3. On first launch, DiskTwin automatically configures ~/.disk-twin/ and its LaunchAgents.
4. Click the DiskTwin icon in the top-right macOS Menu Bar -> "Schedule & Thermal Cool-Down Settings..."
   to select your Primary External SSD, Internal MicroSD, sync schedule, and thermal cool-down intervals.

Requirements:
- macOS 14.0+ (Apple Silicon)
- Optional: Homebrew rsync (`brew install rsync`) for accelerated xxhash delta transfers
EOF

echo "==> 3. Creating compressed DMG installer..."
mkdir -p "${DIST_DIR}" "${DOCS_DIR}"
rm -f "${DIST_DIR}/${DMG_NAME}"

hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DIST_DIR}/${DMG_NAME}"

cp "${DIST_DIR}/${DMG_NAME}" "${DOCS_DIR}/${DMG_NAME}"
rm -rf "${STAGE_DIR}"

echo "==> Built DMG successfully:"
ls -lh "${DIST_DIR}/${DMG_NAME}"
