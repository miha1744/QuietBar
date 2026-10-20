#!/bin/bash
# Build and package QuietBar locally. Requires Xcode Command Line Tools on macOS.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_NAME="QuietBar"
VERSION="1.3.1"
BUILD_VERSION="5"
BUNDLE_ID="local.quietbar.app"
MIN_MACOS="14.0"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
HARDENED_RUNTIME="${HARDENED_RUNTIME:-0}"
DISTRIBUTION=0
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

usage() {
  cat <<'USAGE'
Usage: ./build.sh [--build-dir PATH] [--output-dir PATH] [--hardened-runtime] [--distribution]

Builds a universal arm64 + x86_64 macOS app and creates:
  QuietBar.app
  QuietBar-1.3.1-universal.zip
  QuietBar-1.3.1-universal.dmg
  QuietBar-source.zip
  QuietBar-инструкция.txt (when README.txt is present)

The app ZIP contains a QuietBar-1.3.1 folder with the app and README.txt.
The read-only DMG contains the app, an Applications shortcut, and README.txt.

BUILD_DIR and OUTPUT_DIR may also be supplied as environment variables.
Default build directory: build/ beside this script.
Default output directory: dist/ beside this script.

The app is signed ad hoc for local use and is not notarized. --hardened-runtime (or
HARDENED_RUNTIME=1) opts into hardened runtime after testing compatibility.
This script does not install or launch the app.

--distribution requires SIGN_IDENTITY (Developer ID Application certificate or
its SHA-1) and NOTARY_PROFILE (an existing notarytool keychain profile). It signs
with hardened runtime, submits the app and DMG to Apple, staples both tickets,
and requires Gatekeeper acceptance. Without those credentials it stops before
building. This mode does not create certificates or purchase a developer account.
The accepted set is published in OUTPUT_DIR/QuietBar-1.3.1-distribution/ only
after all checks pass. An existing distribution directory is never overwritten.
USAGE
}

while (($#)); do
  case "$1" in
    --build-dir|--output-dir)
      if (($# < 2)) || [[ -z "$2" ]]; then
        printf 'Missing path after %s\n' "$1" >&2
        exit 2
      fi
      if [[ "$1" == "--build-dir" ]]; then
        BUILD_DIR="$2"
      else
        OUTPUT_DIR="$2"
      fi
      shift 2
      ;;
    --hardened-runtime)
      HARDENED_RUNTIME=1
      shift
      ;;
    --distribution)
      DISTRIBUTION=1
      HARDENED_RUNTIME=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'QuietBar must be built on macOS with Xcode Command Line Tools.\n' >&2
  exit 1
fi
if [[ "$HARDENED_RUNTIME" != 0 && "$HARDENED_RUNTIME" != 1 ]]; then
  printf 'HARDENED_RUNTIME must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$DISTRIBUTION" == 1 ]]; then
  if [[ "$SIGN_IDENTITY" == - || -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
    printf 'Distribution requires SIGN_IDENTITY and NOTARY_PROFILE; no artifacts changed.\n' >&2
    exit 2
  fi
  MATCHED_IDENTITY=0
  while IFS= read -r IDENTITY_LINE; do
    if [[ "$IDENTITY_LINE" == *"$SIGN_IDENTITY"* && "$IDENTITY_LINE" == *'"Developer ID Application:'* ]]; then
      MATCHED_IDENTITY=1
    fi
  done < <(/usr/bin/security find-identity -v -p codesigning)
  if [[ "$MATCHED_IDENTITY" != 1 ]]; then
    printf 'A valid matching Developer ID Application identity was not found; no artifacts changed.\n' >&2
    exit 2
  fi
else
  # Certificate settings never silently opt a local build into external upload.
  SIGN_IDENTITY=-
fi

shopt -s nullglob
SOURCES=("$SCRIPT_DIR"/Sources/*.m)
if ((${#SOURCES[@]} == 0)); then
  printf 'No Objective-C sources found in %s/Sources.\n' "$SCRIPT_DIR" >&2
  exit 1
fi

SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
CLANG="$(/usr/bin/xcrun --sdk macosx --find clang)"
LIPO="$(/usr/bin/xcrun --sdk macosx --find lipo)"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
BUILD_DIR="$(cd -- "$BUILD_DIR" && pwd -P)"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
PUBLISH_ROOT="$OUTPUT_DIR"
PUBLISH_LOCK=""
PUBLISH_INCOMING=""
if [[ "$DISTRIBUTION" == 1 ]]; then
  PUBLISH_DEST="$PUBLISH_ROOT/$APP_NAME-$VERSION-distribution"
  if [[ -e "$PUBLISH_DEST" ]]; then
    printf 'Distribution destination already exists: %s\n' "$PUBLISH_DEST" >&2
    exit 2
  fi
  PUBLISH_LOCK="$PUBLISH_ROOT/.$APP_NAME-$VERSION-distribution.lock"
  if ! mkdir "$PUBLISH_LOCK" 2>/dev/null; then
    printf 'Another distribution build holds the publication lock: %s\n' "$PUBLISH_LOCK" >&2
    exit 2
  fi
  cleanup_publication() {
    if [[ -n "$PUBLISH_INCOMING" && -d "$PUBLISH_INCOMING" ]]; then rm -rf "$PUBLISH_INCOMING"; fi
    if [[ -n "$PUBLISH_LOCK" ]]; then rmdir "$PUBLISH_LOCK" 2>/dev/null || true; fi
  }
  trap cleanup_publication EXIT
  # An unsuccessful submission must never replace an existing deliverable.
  OUTPUT_DIR="$BUILD_DIR/distribution-output"
  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"
fi
STAGE_DIR="$BUILD_DIR/stage"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
SOURCE_STAGE="$BUILD_DIR/source-stage/$APP_NAME-source"
RELEASE_STAGE="$BUILD_DIR/release-stage/$APP_NAME-$VERSION"
DMG_STAGE="$BUILD_DIR/dmg-stage/$APP_NAME-$VERSION"
APP_OUTPUT="$OUTPUT_DIR/$APP_NAME.app"
APP_ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-universal.zip"
APP_DMG="$OUTPUT_DIR/$APP_NAME-$VERSION-universal.dmg"
DMG_BUILD="$BUILD_DIR/$APP_NAME-$VERSION-universal.dmg"
SOURCE_ZIP="$OUTPUT_DIR/$APP_NAME-source.zip"
README_OUTPUT="$OUTPUT_DIR/$APP_NAME-инструкция.txt"

# Reject overlapping paths so that a caller cannot accidentally package build
# products as sources or remove sources while replacing the app output.
case "$BUILD_DIR/" in
  "$SCRIPT_DIR/"|"$SCRIPT_DIR/Sources/"*)
    printf 'The build directory must not be the source root or inside Sources.\n' >&2
    exit 2
    ;;
esac
if [[ "$APP_OUTPUT" == "$SCRIPT_DIR" || "$STAGED_APP" == "$SCRIPT_DIR" ]]; then
  printf 'The app output must not replace the source directory.\n' >&2
  exit 2
fi

for ARCH in arm64 x86_64; do
  ARCH_DIR="$BUILD_DIR/$ARCH"
  mkdir -p "$ARCH_DIR"
  printf 'Building %s for %s (minimum macOS %s)…\n' "$APP_NAME" "$ARCH" "$MIN_MACOS"
  "$CLANG" \
    -arch "$ARCH" \
    -isysroot "$SDK_PATH" \
    "-mmacosx-version-min=$MIN_MACOS" \
    -fobjc-arc -fmodules -O2 -DNDEBUG \
    -Wall -Wextra \
    -framework AppKit -framework Foundation -framework ServiceManagement \
    -framework ApplicationServices -framework Security \
    "${SOURCES[@]}" \
    -o "$ARCH_DIR/$APP_NAME"
done

rm -rf "$STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
"$LIPO" -create \
  "$BUILD_DIR/arm64/$APP_NAME" \
  "$BUILD_DIR/x86_64/$APP_NAME" \
  -output "$STAGED_APP/Contents/MacOS/$APP_NAME"
"$LIPO" "$STAGED_APP/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
chmod 755 "$STAGED_APP/Contents/MacOS/$APP_NAME"

ICON_PLIST=""
ICON_SOURCE=""
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
  ICON_SOURCE="$SCRIPT_DIR/AppIcon.icns"
elif [[ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]]; then
  ICON_SOURCE="$SCRIPT_DIR/Resources/AppIcon.icns"
fi
if [[ -n "$ICON_SOURCE" ]]; then
  /usr/bin/ditto "$ICON_SOURCE" "$STAGED_APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST='  <key>CFBundleIconFile</key><string>AppIcon</string>'
fi

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
$ICON_PLIST
</dict>
</plist>
PLIST
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
for LANGUAGE in en ru; do
  mkdir -p "$STAGED_APP/Contents/Resources/$LANGUAGE.lproj"
  cat > "$STAGED_APP/Contents/Resources/$LANGUAGE.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "QuietBar";
"CFBundleName" = "QuietBar";
STRINGS
done
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"

for BUNDLE_DOCUMENT in README.txt LICENSE THIRD-PARTY-NOTICES.txt; do
  if [[ -f "$SCRIPT_DIR/$BUNDLE_DOCUMENT" ]]; then
    /usr/bin/ditto "$SCRIPT_DIR/$BUNDLE_DOCUMENT" "$STAGED_APP/Contents/Resources/$BUNDLE_DOCUMENT"
  fi
done

SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$DISTRIBUTION" == 1 ]]; then
  SIGN_FLAGS+=(--timestamp)
else
  SIGN_FLAGS+=(--timestamp=none)
fi
if [[ "$HARDENED_RUNTIME" == 1 ]]; then
  SIGN_FLAGS+=(--options runtime)
fi
/usr/bin/codesign "${SIGN_FLAGS[@]}" "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"

notarize() {
  local artifact="$1" report="$2" status
  /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 20m --output-format json > "$report"
  status=$(/usr/bin/plutil -extract status raw -o - "$report")
  if [[ "$status" != Accepted ]]; then
    printf 'Notarization was not accepted. Report: %s\n' "$report" >&2
    return 1
  fi
}
if [[ "$DISTRIBUTION" == 1 ]]; then
  # Staple the inner app too, so an extracted app retains its offline ticket.
  NOTARY_ZIP="$BUILD_DIR/$APP_NAME-notary.zip"
  rm -f "$NOTARY_ZIP"
  /usr/bin/ditto -c -k --keepParent "$STAGED_APP" "$NOTARY_ZIP"
  notarize "$NOTARY_ZIP" "$BUILD_DIR/notary-app.json"
  /usr/bin/xcrun stapler staple "$STAGED_APP"
  /usr/bin/xcrun stapler validate "$STAGED_APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP"
fi

# Use ditto for both the app copy and archives to retain bundle metadata.
rm -rf "$APP_OUTPUT"
/usr/bin/ditto "$STAGED_APP" "$APP_OUTPUT"
rm -rf "$RELEASE_STAGE"
mkdir -p "$RELEASE_STAGE"
/usr/bin/ditto "$APP_OUTPUT" "$RELEASE_STAGE/$APP_NAME.app"
if [[ -f "$SCRIPT_DIR/README.txt" ]]; then
  /usr/bin/ditto "$SCRIPT_DIR/README.txt" "$RELEASE_STAGE/README.txt"
fi
rm -f "$APP_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$RELEASE_STAGE" "$APP_ZIP"

# Build a plain read-only image without mounting it or changing Finder settings.
# README.txt deliberately has an ASCII filename for portable archive handling;
# the instruction text itself is preserved in its original Russian.
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
/usr/bin/ditto "$APP_OUTPUT" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
if [[ -f "$SCRIPT_DIR/README.txt" ]]; then
  /usr/bin/ditto "$SCRIPT_DIR/README.txt" "$DMG_STAGE/README.txt"
fi
/usr/bin/hdiutil create \
  -srcfolder "$DMG_STAGE" \
  -volname "$APP_NAME $VERSION" \
  -fs HFS+ -format UDZO -ov \
  "$DMG_BUILD"
/usr/bin/hdiutil verify "$DMG_BUILD"
if [[ "$DISTRIBUTION" == 1 ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_BUILD"
  /usr/bin/codesign --verify --strict "$DMG_BUILD"
  notarize "$DMG_BUILD" "$BUILD_DIR/notary-dmg.json"
  /usr/bin/xcrun stapler staple "$DMG_BUILD"
  /usr/bin/xcrun stapler validate "$DMG_BUILD"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_BUILD"
fi
if [[ "$DMG_BUILD" != "$APP_DMG" ]]; then
  mv -f "$DMG_BUILD" "$APP_DMG"
fi

rm -rf "$SOURCE_STAGE"
mkdir -p "$SOURCE_STAGE"
/usr/bin/ditto "$SCRIPT_DIR/Sources" "$SOURCE_STAGE/Sources"
/usr/bin/ditto "$SCRIPT_DIR/build.sh" "$SOURCE_STAGE/build.sh"
for SOURCE_DIRECTORY in docs scripts ci .github; do
  if [[ -d "$SCRIPT_DIR/$SOURCE_DIRECTORY" ]]; then
    /usr/bin/ditto "$SCRIPT_DIR/$SOURCE_DIRECTORY" "$SOURCE_STAGE/$SOURCE_DIRECTORY"
  fi
done
# Bytecode caches are local tooling byproducts, not distributable sources.
/usr/bin/find "$SOURCE_STAGE" -type d -name __pycache__ -prune -exec /bin/rm -rf '{}' +
for SOURCE_FILE in "$SCRIPT_DIR"/README* "$SCRIPT_DIR"/LICENSE* "$SCRIPT_DIR"/NOTICE* \
    "$SCRIPT_DIR"/THIRD-PARTY-NOTICES.txt "$SCRIPT_DIR"/CHANGELOG.md \
    "$SCRIPT_DIR"/CONTRIBUTING.md "$SCRIPT_DIR"/SECURITY.md "$SCRIPT_DIR"/.gitignore; do
  if [[ -f "$SOURCE_FILE" ]]; then
    /usr/bin/ditto "$SOURCE_FILE" "$SOURCE_STAGE/$(basename -- "$SOURCE_FILE")"
  fi
done
if [[ -n "$ICON_SOURCE" ]]; then
  /usr/bin/ditto "$ICON_SOURCE" "$SOURCE_STAGE/AppIcon.icns"
fi
rm -f "$SOURCE_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$SOURCE_STAGE" "$SOURCE_ZIP"
if [[ -f "$SCRIPT_DIR/README.txt" ]]; then
  /usr/bin/ditto "$SCRIPT_DIR/README.txt" "$README_OUTPUT"
fi

if [[ "$DISTRIBUTION" == 1 ]]; then
  # Publish the complete accepted set with one same-volume directory rename.
  PUBLISH_INCOMING=$(/usr/bin/mktemp -d "$PUBLISH_ROOT/.$APP_NAME-$VERSION.incoming.XXXXXX")
  /usr/bin/ditto "$OUTPUT_DIR" "$PUBLISH_INCOMING"
  mv "$PUBLISH_INCOMING" "$PUBLISH_DEST"
  PUBLISH_INCOMING=""
  APP_OUTPUT="$PUBLISH_DEST/$APP_NAME.app"
  APP_ZIP="$PUBLISH_DEST/$APP_NAME-$VERSION-universal.zip"
  APP_DMG="$PUBLISH_DEST/$APP_NAME-$VERSION-universal.dmg"
  SOURCE_ZIP="$PUBLISH_DEST/$APP_NAME-source.zip"
  README_OUTPUT="$PUBLISH_DEST/$APP_NAME-инструкция.txt"
fi

printf '\nCreated:\n  %s\n  %s\n  %s\n  %s\n' "$APP_OUTPUT" "$APP_ZIP" "$APP_DMG" "$SOURCE_ZIP"
if [[ -f "$SCRIPT_DIR/README.txt" ]]; then
  printf '  %s\n' "$README_OUTPUT"
fi
if [[ "$DISTRIBUTION" == 1 ]]; then
  printf 'Signing: Developer ID, hardened runtime, notarized app and DMG\n'
  exit 0
fi
printf 'Signing: ad hoc'
if [[ "$HARDENED_RUNTIME" == 1 ]]; then
  printf ', hardened runtime'
fi
printf ', not notarized\n'
