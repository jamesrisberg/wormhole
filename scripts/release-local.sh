#!/usr/bin/env bash
set -euo pipefail

# Local release script for Wormhole.
#
# Usage:
#   scripts/release-local.sh               build, notarize, sign, update appcast
#   scripts/release-local.sh appcast-urls  rewrite every enclosure URL in
#                                          releases/appcast.xml from DOWNLOAD_BASE_URL
#
# Flow: archive -> developer-id export -> notarize -> staple -> zip ->
# sparkle sign -> prepend appcast item -> (optionally) copy appcast into
# SITE_DIR. The zip itself is uploaded to GitHub Releases (see the printed
# next steps and docs/RELEASING.md); it is not committed.
#
# Configuration comes from .env (gitignored; see .env.example):
#   APPLE_TEAM_ID, APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD  signing/notarization
#   DOWNLOAD_BASE_URL  enclosure URL prefix; the item URL is
#                      ${DOWNLOAD_BASE_URL}/v<version>/wormhole.zip
#   APPCAST_URL        where the appcast is served (must match SUFeedURL)
#   SITE_DIR           optional local folder the appcast is copied into
#   SPARKLE_SIGN_UPDATE optional explicit path to Sparkle's sign_update
# Set NOTARIZE=0 to skip notarization, SKIP_APPCAST=1 to skip the Sparkle signature and
# the appcast (the zip is still built, notarized and stapled).
#
# Version/build are taken from the project as-is; bump MARKETING_VERSION /
# CURRENT_PROJECT_VERSION in Xcode before releasing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Credentials: .env, else $HUD_ENV_FILE, else ~/.config/machud/release.env (the MacHUD
# family's release credentials; see hudkit/docs/CONVENTIONS.md, "Releasing").
ENV_FILE=".env"
[[ -f "${ENV_FILE}" ]] || ENV_FILE="${HUD_ENV_FILE:-${HOME}/.config/machud/release.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

APP_NAME="wormhole"
PROJECT_PATH="wormhole.xcodeproj"
SCHEME="wormhole"
APPCAST_PATH="releases/appcast.xml"
MIN_SYSTEM_VERSION="14.6"

DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://github.com/jamesrisberg/wormhole/releases/download}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"
APPCAST_URL="${APPCAST_URL:-https://viawormhole.xyz/appcast.xml}"
SITE_DIR="${SITE_DIR:-}"

download_url() {
  echo "${DOWNLOAD_BASE_URL}/v$1/${APP_NAME}.zip"
}

# Rewrite each <enclosure url="..."> from the item's shortVersionString.
rewrite_appcast_urls() {
  local tmp="${APPCAST_PATH}.tmp"
  awk -v base="${DOWNLOAD_BASE_URL}" -v app="${APP_NAME}" '
    /<sparkle:shortVersionString>/ {
      v = $0
      sub(/.*<sparkle:shortVersionString>/, "", v)
      sub(/<\/sparkle:shortVersionString>.*/, "", v)
    }
    /<enclosure url="/ && v != "" {
      sub(/url="[^"]*"/, "url=\"" base "/v" v "/" app ".zip\"")
    }
    /<\/item>/ { v = "" }
    { print }
  ' "${APPCAST_PATH}" > "${tmp}"
  mv "${tmp}" "${APPCAST_PATH}"
}

if [[ "${1:-}" == "appcast-urls" ]]; then
  rewrite_appcast_urls
  echo "Rewrote enclosure URLs in ${APPCAST_PATH} using ${DOWNLOAD_BASE_URL}"
  exit 0
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [appcast-urls]" >&2
  exit 2
fi

if [[ "${DOWNLOAD_BASE_URL}" == *"/OWNER/"* ]]; then
  echo "Error: DOWNLOAD_BASE_URL still has the OWNER placeholder; set it in .env." >&2
  exit 1
fi

FEED_IN_PLIST=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" wormhole/Info.plist 2>/dev/null || true)
if [[ "${FEED_IN_PLIST}" != "${APPCAST_URL}" ]]; then
  echo "Error: APPCAST_URL (${APPCAST_URL}) does not match SUFeedURL in wormhole/Info.plist (${FEED_IN_PLIST})." >&2
  exit 1
fi

BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"

NOTARIZE="${NOTARIZE:-1}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing env: ${name}" >&2
    exit 1
  fi
}

require_tool() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing tool: ${name}" >&2
    exit 1
  fi
}

# Locate Sparkle's sign_update. Prefer an explicit path, then the SPM
# artifacts in this project's own DerivedData, then the newest copy in any
# DerivedData, then PATH.
find_sign_update() {
  local rel="SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    [[ -x "${SPARKLE_SIGN_UPDATE}" ]] && { echo "${SPARKLE_SIGN_UPDATE}"; return 0; }
    echo "SPARKLE_SIGN_UPDATE is set but not executable: ${SPARKLE_SIGN_UPDATE}" >&2
    return 1
  fi
  local products
  products=$(xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '$1 ~ /^ *BUILD_DIR$/ { print $2; exit }')
  if [[ -n "${products}" ]]; then
    local derived="${products%/Build/Products}"
    [[ -x "${derived}/${rel}" ]] && { echo "${derived}/${rel}"; return 0; }
  fi
  local newest
  newest=$(ls -t "${HOME}"/Library/Developer/Xcode/DerivedData/*/${rel} 2>/dev/null | head -n 1 || true)
  [[ -n "${newest}" && -x "${newest}" ]] && { echo "${newest}"; return 0; }
  command -v sign_update 2>/dev/null && return 0
  return 1
}

require_tool xcodebuild
require_tool ditto
require_tool zip
require_tool xcrun

require_env APPLE_TEAM_ID
if [[ "${NOTARIZE}" == "1" ]]; then
  require_env APPLE_ID
  require_env APPLE_APP_SPECIFIC_PASSWORD
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Archiving"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -destination 'generic/platform=macOS' \
  archive

echo "==> Exporting"
cat > "${BUILD_DIR}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
  -exportPath "${EXPORT_PATH}"

APP_PATH="$(find "${EXPORT_PATH}" -maxdepth 1 -name "*.app" | head -n 1)"
if [[ -z "${APP_PATH}" ]]; then
  echo "Export failed: no .app found in ${EXPORT_PATH}" >&2
  exit 1
fi

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${INFO_PLIST}")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFO_PLIST}")
echo "==> Version: ${VERSION} (${BUILD_NUMBER})"

if grep -q "sparkle:shortVersionString>${VERSION}<" "${APPCAST_PATH}"; then
  echo "Error: version ${VERSION} is already in ${APPCAST_PATH}; bump MARKETING_VERSION first." >&2
  exit 1
fi

if [[ "${NOTARIZE}" == "1" ]]; then
  echo "==> Zipping app for notarization"
  NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
  rm -f "${NOTARIZE_ZIP}"
  ditto -c -k --keepParent "${APP_PATH}" "${NOTARIZE_ZIP}"

  echo "==> Notarizing"
  xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --apple-id "${APPLE_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --team-id "${APPLE_TEAM_ID}" \
    --wait

  echo "==> Stapling .app bundle"
  xcrun stapler staple "${APP_PATH}"
else
  echo "==> Skipping notarization (NOTARIZE=0)"
fi

echo "==> Creating distribution ZIP"
# Important: use /usr/bin/zip -X (skip extended attributes / resource forks)
# rather than `ditto -c -k --keepParent`. ditto bakes xattrs as `._*`
# AppleDouble entries inside the zip — when extracted by anything other than
# `ditto -x -k` (Safari, Archive Utility on Tahoe, Sparkle's installer), those
# expand into real files inside the bundle and corrupt the codesign
# ("could not verify it's not malware" on launch).
rm -f "${ZIP_PATH}"
ZIP_ABS_PATH="$(cd "$(dirname "${ZIP_PATH}")" && pwd)/$(basename "${ZIP_PATH}")"
APP_PARENT_DIR="$(cd "$(dirname "${APP_PATH}")" && pwd)"
APP_BASENAME="$(basename "${APP_PATH}")"
( cd "${APP_PARENT_DIR}" && /usr/bin/zip --symlinks --recurse-paths -X -q "${ZIP_ABS_PATH}" "${APP_BASENAME}" )

ZIP_SIZE=$(stat -f%z "${ZIP_PATH}")

if [[ "${SKIP_APPCAST:-0}" == "1" ]]; then
  echo ""
  echo "==> Done (SKIP_APPCAST=1: no Sparkle signature, appcast unchanged)"
  echo "Build:    ${ZIP_PATH} (${ZIP_SIZE} bytes, sha256 $(shasum -a 256 "${ZIP_PATH}" | cut -d' ' -f1))"
  echo "Version:  ${VERSION} (${BUILD_NUMBER})"
  echo "Download: $(download_url "${VERSION}")"
  exit 0
fi

echo "==> Generating Sparkle signature"
SIGN_UPDATE="$(find_sign_update)" || {
  echo "Error: Sparkle's sign_update tool not found. Looked for:" >&2
  echo "  - \$SPARKLE_SIGN_UPDATE" >&2
  echo "  - this project's DerivedData: SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" >&2
  echo "  - ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" >&2
  echo "  - sign_update on PATH" >&2
  echo "Resolve Swift packages (open the project in Xcode or run xcodebuild -resolvePackageDependencies)," >&2
  echo "or download the Sparkle tools from https://github.com/sparkle-project/Sparkle/releases" >&2
  echo "and set SPARKLE_SIGN_UPDATE in .env." >&2
  exit 1
}
echo "Using ${SIGN_UPDATE}"
# wormhole uses the default Sparkle keychain account (no --account flag)
SPARKLE_SIG=$("${SIGN_UPDATE}" "${ZIP_PATH}" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
echo "Signature: ${SPARKLE_SIG:0:20}..."

echo "==> Updating appcast"
DOWNLOAD_URL="$(download_url "${VERSION}")"
PUB_DATE=$(date +"%a, %d %b %Y %H:%M:%S %z")
NEW_ITEM_FILE="${BUILD_DIR}/appcast-item.xml"
cat > "${NEW_ITEM_FILE}" <<EOF
        <item>
            <title>${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <enclosure url="${DOWNLOAD_URL}" length="${ZIP_SIZE}" type="application/octet-stream" sparkle:edSignature="${SPARKLE_SIG}"/>
        </item>
EOF
awk -v new_item_file="${NEW_ITEM_FILE}" '
  BEGIN {
    new_item = ""
    while ((getline line < new_item_file) > 0) { new_item = new_item line ORS }
    close(new_item_file)
  }
  { print }
  /<title>wormhole<\/title>/ && !inserted { printf "%s", new_item; inserted = 1 }
' "${APPCAST_PATH}" > "${APPCAST_PATH}.tmp"
mv "${APPCAST_PATH}.tmp" "${APPCAST_PATH}"

if [[ -n "${SITE_DIR}" ]]; then
  echo "==> Copying appcast to ${SITE_DIR}"
  if [[ ! -d "${SITE_DIR}" ]]; then
    echo "Error: SITE_DIR ${SITE_DIR} not found" >&2
    exit 1
  fi
  cp "${APPCAST_PATH}" "${SITE_DIR}/appcast.xml"
fi

echo ""
echo "==> Done!"
echo ""
echo "Build:    ${ZIP_PATH}"
echo "Version:  ${VERSION} (${BUILD_NUMBER})"
echo "Download: ${DOWNLOAD_URL}"
echo ""
echo "Next steps:"
echo "  1. Commit ${APPCAST_PATH} and the version bump in project.pbxproj"
echo "  2. Upload the zip so the download URL resolves, e.g.:"
echo "       gh release create v${VERSION} ${ZIP_PATH} --title \"Wormhole ${VERSION}\""
if [[ -n "${SITE_DIR}" ]]; then
  echo "  3. Deploy ${SITE_DIR} so ${APPCAST_URL} serves the new appcast"
else
  echo "  3. Publish ${APPCAST_PATH} at ${APPCAST_URL}"
fi
