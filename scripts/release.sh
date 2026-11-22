#!/bin/bash
# Publishes a new RideCPP version to GitHub.
#
#   scripts/release.sh 1.0.0 1
#
# Stamps the version/build into project.yml, builds a signed universal app,
# packages the .dmg and uploads it as a GitHub Release tagged "v1.0.0(1)".
# Requires: gh (authenticated), xcodegen, Xcode.

set -euo pipefail

VERSION="${1:?usage: release.sh <version, e.g. 1.0.0> <build number, e.g. 1>}"
BUILD="${2:?usage: release.sh <version> <build number>}"
TAG="v${VERSION}(${BUILD})"
REPO="${REPO:-JiangWanZhengChouYv/RideCPP}"

cd "$(dirname "$0")/.."

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists in $REPO; refusing to overwrite." >&2
    exit 1
fi

echo "Stamping version $VERSION ($BUILD)…"
/usr/bin/sed -i '' -E "s/(MARKETING_VERSION: \")[^\"]*(\")/\1${VERSION}\2/" project.yml
/usr/bin/sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[^\"]*(\")/\1${BUILD}\2/" project.yml
/usr/bin/sed -i '' -E "s/(CFBundleShortVersionString: \")[^\"]*(\")/\1${VERSION}\2/" project.yml
/usr/bin/sed -i '' -E "s/(CFBundleVersion: \")[^\"]*(\")/\1${BUILD}\2/" project.yml

make dist

DMG="$(ls -t dist/*.dmg | head -1)"
echo "Uploading $DMG as release $TAG…"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "RideCPP ${VERSION} (${BUILD})" \
    --notes "RideCPP ${VERSION} (${BUILD})

下载下方的 .dmg，打开后把 RideCPP 拖进「应用程序」即可。

> 本版本使用 ad-hoc 签名、未经 Apple 公证。首次打开若提示“无法验证开发者”，
> 请在「系统设置 → 隐私与安全性」点「仍要打开」，或执行
> \`xattr -d com.apple.quarantine /Applications/RideCPP.app\`

Download the .dmg and drag RideCPP into Applications. The build is ad-hoc signed
and not notarized; if macOS blocks it, allow it in System Settings →
Privacy & Security."

echo
echo "Published: https://github.com/${REPO}/releases/tag/${TAG}"
