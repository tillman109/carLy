#!/usr/bin/env bash
# Assemble the .deb from the payload build-payload.sh staged.
#
#   tools/build-deb.sh [revision]
#
# The version comes from packaging/payload/PAYLOAD.version, which build-payload.sh writes, so the
# two cannot disagree about what was built. Runs on Linux and needs nothing but dpkg-deb: the
# payload crossed an artifact boundary to get here and is already built and signed.
#
# RootHide-native only: package architecture iphoneos-arm64e and Library/
# payload at the DEB root, never under /var/jb. Dynamic jailbreak data paths
# are resolved at runtime using RootHide's jbroot API.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD="$ROOT/packaging/payload"
OUT="${OUT:-$ROOT/repo/debs}"
PACKAGE=com.andi.carly

# The reusable workflow exports these; a local run falls back to the canonical values.
GH_REPO="${GH_REPO:-realAndi/carLy}"
GH_PAGES="${GH_PAGES:-realandi.github.io/carLy}"

command -v dpkg-deb >/dev/null \
    || { echo "need dpkg-deb (apt install dpkg-dev / brew install dpkg)"; exit 1; }
[ -f "$PAYLOAD/PAYLOAD.version" ] \
    || { echo "missing packaging/payload/PAYLOAD.version -- run tools/build-payload.sh first"; exit 1; }
[ -d "$PAYLOAD/root/Library" ] \
    || { echo "missing packaging/payload/root -- run tools/build-payload.sh first"; exit 1; }

read -r VERSION < "$PAYLOAD/PAYLOAD.version"
REV="${1:-}"
PKGVER="$VERSION${REV:+-$REV}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
STAGE="$STAGING/stage"
mkdir -p "$STAGE/DEBIAN"
cp -R "$PAYLOAD/root/." "$STAGE/"

# upload-artifact does not keep POSIX modes, so every mode is set here, then the two Mach-Os are
# checked: still fat arm64/arm64e images (magic cafebabe), and executable. dyld verifies the rest
# on device; otool does not exist on Linux.
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
for binary in Library/MobileSubstrate/DynamicLibraries/carLy.dylib \
              Library/PreferenceBundles/carLyPrefs.bundle/carLyPrefs; do
    path="$STAGE/$binary"
    [ -f "$path" ] || { echo "missing $binary"; exit 1; }
    magic=$(head -c 4 "$path" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "cafebabe" ] || { echo "$binary is not a fat Mach-O (magic $magic)"; exit 1; }
    chmod 755 "$path"
done

# Sileo shows this before downloading. KB, as dpkg defines it.
ISIZE=$(du -sk "$STAGE/Library" | cut -f1)

sed -e "s|@VERSION@|$PKGVER|g" \
    -e "s|@ISIZE@|$ISIZE|g" \
    -e "s|@REPO@|$GH_REPO|g" \
    -e "s|@PAGES@|$GH_PAGES|g" \
    "$ROOT/packaging/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
[ -n "$GH_PAGES" ] || sed -i.bak '/^Native-Depiction:/d;/^SileoDepiction:/d' "$STAGE/DEBIAN/control"
rm -f "$STAGE/DEBIAN/control.bak"
if grep -q '@[A-Z]*@' "$STAGE/DEBIAN/control"; then
    echo "unfilled placeholder in DEBIAN/control"; exit 1
fi
if ! grep -qx 'Architecture: iphoneos-arm64e' "$STAGE/DEBIAN/control"; then
    echo "refusing to create a non-RootHide DEB"; exit 1
fi
if [ -e "$STAGE/var/jb" ]; then
    echo "refusing standard rootless /var/jb payload inside a RootHide package"; exit 1
fi
for script in postinst prerm; do
    install -m 755 "$ROOT/packaging/DEBIAN/$script" "$STAGE/DEBIAN/$script"
done

mkdir -p "$OUT"
DEB="$OUT/${PACKAGE}_${PKGVER}_iphoneos-arm64e.deb"
# --root-owner-group: built by a CI user, installed as root.
dpkg-deb --root-owner-group -Zxz -b "$STAGE" "$DEB" >/dev/null
echo "==> built $(basename "$DEB") ($(du -h "$DEB" | cut -f1))"
