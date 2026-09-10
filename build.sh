#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
DERIVED_DATA_DIR="${PROJECT_DIR}/.build"
BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/Shush.app"
INSTALLED_APP="/Applications/Shush.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

cd "${PROJECT_DIR}"

echo "Building Shush…"
xcodebuild \
  -project Shush.xcodeproj \
  -scheme Shush \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

echo "Signing app bundle…"
codesign --force --deep --options runtime --sign - "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"

echo "Installing ${INSTALLED_APP}…"
pkill -x Shush 2>/dev/null || true

if [[ -d "${INSTALLED_APP}" ]]; then
  "${LSREGISTER}" -u "${INSTALLED_APP}" 2>/dev/null || true
fi

ditto "${BUILT_APP}" "${INSTALLED_APP}"
touch "${INSTALLED_APP}"
"${LSREGISTER}" -f "${INSTALLED_APP}"

echo "Launching Shush…"
open "${INSTALLED_APP}"

sleep 1
if pgrep -x Shush >/dev/null; then
  echo "Done. Look for ‘Shush’ with a microphone symbol in the menu bar."
else
  echo "Shush did not stay running. Launch it from ${INSTALLED_APP} to see the macOS error." >&2
  exit 1
fi

