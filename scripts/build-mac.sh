#!/bin/sh
# Build carLy as a native RootHide iphoneos-arm64e package on macOS.
# Xcode clang must compile both arm64 and arm64e slices; ldid signs the dylib.
# Requires roothide/theos, Xcode, ldid-procursus and dpkg.
set -eu
export THEOS="${THEOS:-$HOME/theos-roothide}"
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ ! -f "$THEOS/vendor/mod/roothide/package/deb.mk" ]; then
    echo "RootHide Theos required at $THEOS" >&2
    exit 1
fi
command -v ldid >/dev/null || { echo "Install ldid-procursus first" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "Install dpkg first" >&2; exit 1; }

make clean
make package FINALPACKAGE=1 TARGET_CODESIGN=ldid "$@"

for deb in packages/*.deb; do
    [ -f "$deb" ] || { echo "No package produced" >&2; exit 1; }
    [ "$(dpkg-deb -f "$deb" Architecture)" = "iphoneos-arm64e" ] ||
        { echo "Not a RootHide-native package: $deb" >&2; exit 1; }
    echo "RootHide-native package: $deb"
done
