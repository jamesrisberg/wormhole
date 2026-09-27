#!/usr/bin/env bash
set -euo pipefail

# Verifies that the portal window can be freely repositioned by an external
# process via the Accessibility API (System Events) -- the same mechanism
# window-management tools like Rectangle/Moom use, and the whole point of
# Stream E (making the portal window a normal, freely positionable window
# instead of one that's re-anchored top-right every time it's shown).
#
# Flow: launch the built app with `--show-portal` (bypasses the global
# hotkey, whose registration can be flaky when driven headlessly), wait for
# the portal window to appear, move it with `osascript`/System Events, read
# the position back, and print PASS/FAIL. Quits the app when done.
#
# Requires the app to already be built (see CLAUDE.md's build command) and
# requires Terminal/iTerm (whatever is running this script) to have
# Accessibility permission under System Settings > Privacy & Security.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

PROJECT_PATH="wormhole.xcodeproj"
SCHEME="wormhole"
CONFIGURATION="${CONFIGURATION:-Debug}"

echo "==> Locating built app..."
BUILT_PRODUCTS_DIR=$(xcodebuild -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')

if [[ -z "${BUILT_PRODUCTS_DIR}" ]]; then
  echo "FAIL: could not determine BUILT_PRODUCTS_DIR from xcodebuild -showBuildSettings"
  exit 1
fi

APP_PATH="${BUILT_PRODUCTS_DIR}/wormhole.app"
EXECUTABLE="${APP_PATH}/Contents/MacOS/wormhole"

if [[ ! -x "${EXECUTABLE}" ]]; then
  echo "FAIL: built executable not found at ${EXECUTABLE}"
  echo "      Run: xcodebuild -project ${PROJECT_PATH} -scheme ${SCHEME} -configuration ${CONFIGURATION} build"
  exit 1
fi

echo "==> App: ${APP_PATH}"

# Only ever touch the instance this script launches: an installed Wormhole may be
# running with the same process name. The test build shares its UserDefaults
# domain, so the saved portal frame is put back afterwards.
APP_PID=""
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
SAVED_FRAME="$(defaults read "${BUNDLE_ID}" "NSWindow Frame PortalWindow" 2>/dev/null || true)"

cleanup() {
  if [[ -n "${APP_PID}" ]]; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
  fi
  sleep 0.5
  if [[ -n "${SAVED_FRAME}" ]]; then
    defaults write "${BUNDLE_ID}" "NSWindow Frame PortalWindow" "${SAVED_FRAME}"
  fi
}
trap cleanup EXIT

echo "==> Launching app with --show-portal..."
"${EXECUTABLE}" --show-portal &
APP_PID=$!
disown
PROC="(first process whose unix id is ${APP_PID})"

# Wait for the process to register with System Events.
READY=0
for _ in $(seq 1 30); do
  if osascript -e "tell application \"System Events\" to (name of ${PROC})" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.5
done

if [[ "${READY}" -ne 1 ]]; then
  echo "FAIL: process ${APP_PID} never appeared in System Events"
  exit 1
fi

# Wait for the portal window itself (applicationDidFinishLaunching delays
# showPortalWindow(), triggered by --show-portal, by 0.5s).
WINDOW_READY=0
for _ in $(seq 1 30); do
  COUNT=$(osascript -e "tell application \"System Events\" to tell ${PROC} to count windows" 2>/dev/null || echo 0)
  if [[ "${COUNT}" -ge 1 ]]; then
    WINDOW_READY=1
    break
  fi
  sleep 0.5
done

if [[ "${WINDOW_READY}" -ne 1 ]]; then
  echo "FAIL: no window found for process ${APP_PID} (setup wizard may be showing instead -- check dependencyState/isFirstLaunch)"
  exit 1
fi

ORIGINAL=$(osascript -e "tell application \"System Events\" to tell ${PROC} to get position of window 1" 2>/dev/null || echo "")
echo "==> Original position: ${ORIGINAL}"

TARGET_X=222
TARGET_Y=333

echo "==> Setting window position to {${TARGET_X}, ${TARGET_Y}}..."
osascript <<EOF
tell application "System Events"
  tell ${PROC}
    set position of window 1 to {${TARGET_X}, ${TARGET_Y}}
  end tell
end tell
EOF

sleep 0.5

READBACK=$(osascript -e "tell application \"System Events\" to tell ${PROC} to get position of window 1")
echo "==> Read back position: ${READBACK}"

# osascript returns a comma-separated list, e.g. "222, 333"
READ_X=$(echo "${READBACK}" | awk -F', *' '{print $1}')
READ_Y=$(echo "${READBACK}" | awk -F', *' '{print $2}')

if [[ "${READ_X}" == "${TARGET_X}" && "${READ_Y}" == "${TARGET_Y}" ]]; then
  echo "PASS: portal window moved to (${READ_X}, ${READ_Y}) and read back correctly"
  exit 0
else
  echo "FAIL: expected (${TARGET_X}, ${TARGET_Y}), got (${READ_X}, ${READ_Y})"
  exit 1
fi
