#!/bin/bash
# Builds a distributable disk image from an already-signed RideCPP.app.
#
# The image contains the app plus a shortcut to /Applications, so recipients can
# drag it in. An unsigned/ad-hoc image is still useful for local archiving, but
# it will be rejected by Gatekeeper on other Macs (see README, "分发").
#
# Usage: scripts/make-dmg.sh path/to/RideCPP.app output-directory
# Prints the path of the created .dmg on stdout as the last line.

set -euo pipefail

APP="${1:?usage: make-dmg.sh path/to/RideCPP.app output-directory}"
OUT_DIR="${2:?usage: make-dmg.sh path/to/RideCPP.app output-directory}"
[ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/RideCPP" 2>/dev/null | tr ' ' '-')"
mkdir -p "$OUT_DIR"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ridecpp-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/RideCPP.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/读我.txt" <<'TXT'
RideCPP
======

把 RideCPP.app 拖到 Applications 文件夹即可安装。

如果 macOS 提示“无法验证开发者”（本包未经过 Apple 公证）：
  1. 打开“系统设置 → 隐私与安全性”，在最下方点“仍要打开”；或
  2. 在终端执行：xattr -d com.apple.quarantine /Applications/RideCPP.app

首次运行时 RideCPP 需要调用本机的 clang++ / g++ 来编译程序，
因此没有启用 App Sandbox，也没有上架 Mac App Store。

------------------------------------------------------------------------
Install: drag RideCPP.app onto the Applications folder.

If macOS reports the developer cannot be verified (this build is not notarized):
  1. Open System Settings → Privacy & Security and click "Open Anyway"; or
  2. Run: xattr -d com.apple.quarantine /Applications/RideCPP.app

RideCPP runs your local clang++ / g++ to compile code, so it is not
sandboxed and is not distributed through the Mac App Store.
TXT

DMG="$OUT_DIR/RideCPP-${VERSION}-${ARCHS}.dmg"
rm -f "$DMG"
# `hdiutil` is the long-standing tool and works everywhere (including CI
# runners); the newer `diskutil image create` is only a fallback.
dmgs_created="no"
if hdiutil create -volname "RideCPP ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov \
        "$DMG" >/dev/null 2>&1; then
    dmgs_created="yes"
elif diskutil image create from --format UDZO --volumeName "RideCPP ${VERSION}" "$STAGE" "$DMG" >/dev/null 2>&1; then
    dmgs_created="yes"
fi
[ "$dmgs_created" = "yes" ] && [ -f "$DMG" ] || { echo "failed to create disk image" >&2; exit 1; }

echo "$DMG"
