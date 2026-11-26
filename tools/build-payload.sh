#!/usr/bin/env bash
# Build carLy and stage everything the package will contain.
#
#   tools/build-payload.sh <version>
#
# Runs on macOS: the arm64e slice must come from Xcode's clang, which signs Objective-C class
# metadata the way iOS 17's arm64e runtime expects (Procursus' on-device clang does not, and its
# arm64e build crashes CarPlayTemplateUIHost at load). Theos picks the newest iPhoneOS SDK Xcode
# has. The RootHide-native .deb is assembled by build-deb.sh from packaging/payload/.
#
# Theos comes from $THEOS. A CI runner has Xcode but no Theos, and the shared workflow has no
# input to install one, so there -- and only there ($CI set, $THEOS unset) -- the commit pinned in
# tools/theos.pin is fetched from roothide/theos into .theos-toolchain/. Pinned,
# so a toolchain change can never alter a build without a commit here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: build-payload.sh <version>}"

CONTROL_VERSION="$(awk '/^Version:/ { print $2; exit }' "$ROOT/control")"
[ "$VERSION" = "$CONTROL_VERSION" ] \
    || { echo "asked to build $VERSION, but control says $CONTROL_VERSION -- bump control first"; exit 1; }

if [ -z "${THEOS:-}" ]; then
    if [ -z "${CI:-}" ]; then
        echo "set THEOS to a RootHide Theos checkout (https://github.com/roothide/theos)"
        exit 1
    fi
    PIN="$(tr -d '[:space:]' < "$ROOT/tools/theos.pin")"
    THEOS="$ROOT/.theos-toolchain"
    if [ ! -d "$THEOS/.git" ]; then
        echo "==> fetching Theos $PIN"
        git init -q "$THEOS"
        git -C "$THEOS" remote add origin https://github.com/roothide/theos.git
        git -C "$THEOS" fetch -q --depth 1 origin "$PIN"
        git -C "$THEOS" checkout -q FETCH_HEAD
        git -C "$THEOS" submodule update -q --init --recursive
    fi
    export THEOS
fi

# Fail rather than silently emitting a standard rootless DEB when a developer
# points THEOS at the wrong fork. The scheme must exist in the pinned checkout.
[ -f "$THEOS/vendor/mod/roothide/package/deb.mk" ] \
    || { echo "RootHide Theos required: $THEOS has no roothide package scheme"; exit 1; }
command -v ldid >/dev/null \
    || { echo "ldid is required for native RootHide signing (brew install ldid-procursus)"; exit 1; }
make -C "$ROOT" clean >/dev/null
make -C "$ROOT" stage FINALPACKAGE=1 TARGET_CODESIGN=ldid

PAYLOAD="$ROOT/packaging/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/root"
# RootHide stages Library/ directly; never add the standard rootless /var/jb prefix.
cp -R "$ROOT/.theos/_/." "$PAYLOAD/root/"
rm -rf "$PAYLOAD/root/DEBIAN"
printf '%s\n' "$VERSION" > "$PAYLOAD/PAYLOAD.version"

for binary in Library/MobileSubstrate/DynamicLibraries/carLy.dylib \
              Library/PreferenceBundles/carLyPrefs.bundle/carLyPrefs; do
    [ -f "$PAYLOAD/root/$binary" ] || { echo "the build did not produce $binary"; exit 1; }
    lipo "$PAYLOAD/root/$binary" -verify_arch arm64 arm64e \
        || { echo "$binary is missing arm64 or arm64e"; exit 1; }
done
echo "==> payload staged in packaging/payload/ ($(du -sh "$PAYLOAD" | cut -f1))"
