#!/usr/bin/env bash
#
# Build a SideStore / AltStore sideload IPA for Band.
#
# Generates Band.xcodeproj, compiles the Band scheme unsigned for generic iOS,
# strips the embedded Watch app, embeds ad-hoc HealthKit + App Group entitlements
# (via Tools/prepare-ios-sideload-app.sh), and zips Payload/Band.app.
#
# Usage:
#   Tools/build-sideload-ipa.sh [output.ipa]
#
# Environment:
#   BUNDLE_ID_PREFIX   default com.bandapp (installs beside com.noopapp.noop)
#   DERIVED_DATA       default <repo>/build/sideload-dd
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_ARG="${1:-}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.bandapp}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/sideload-dd}"

command -v xcodegen >/dev/null || {
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
}

echo "→ xcodegen generate"
xcodegen generate

echo "→ xcodebuild Band (Release, generic iOS, unsigned)"
echo "  BUNDLE_ID_PREFIX=${BUNDLE_ID_PREFIX} IOS_APP_DISPLAY_NAME=Band NOOP_PERSONAL_BUILD=YES"
xcodebuild \
  -project Band.xcodeproj \
  -scheme Band \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  BUNDLE_ID_PREFIX="$BUNDLE_ID_PREFIX" \
  IOS_APP_DISPLAY_NAME=Band \
  NOOP_PERSONAL_BUILD=YES \
  build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Band.app"
if [ ! -d "$APP" ]; then
  APP="$(find "$DERIVED_DATA/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' -type d | head -1 || true)"
fi
[ -n "${APP:-}" ] && [ -d "$APP" ] || {
  echo "Band.app not found under $DERIVED_DATA/Build/Products/Release-iphoneos" >&2
  exit 1
}

rm -rf "$APP/Watch"

WIDGET="$APP/PlugIns/NOOPWidgets.appex"
[ -d "$WIDGET" ] || {
  echo "widget extension missing: $WIDGET" >&2
  exit 1
}

"$ROOT/Tools/prepare-ios-sideload-app.sh" "$APP"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$APP/Info.plist")"

OUT="${OUT_ARG:-$ROOT/Band-ios-v${VER}.ipa}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

STAGE="$(mktemp -d /tmp/band-sideload-ipa.XXXXXX)"
cleanup() {
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ]; then
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT

mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/Band.app"
(
  cd "$STAGE"
  zip -qr "$OUT" Payload
)

BYTES="$(wc -c < "$OUT" | tr -d ' ')"
echo "✓ $OUT ($BYTES bytes)"
echo "  version ${VER} (${BUILD})  bundle ${BUNDLE_ID}  group ${APP_GROUP}"
