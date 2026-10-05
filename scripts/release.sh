#!/bin/bash
# SoundIn 本地发版流水线：
#   构建(Developer ID 签名) → 公证 → staple → GitHub Release → appcast → gh-pages
#
# 背景：CI（.github/workflows/release.yml）没有开发者证书，产物是 ad-hoc 签名，
# 1.0.2 曾因此启动即崩（Hardened Runtime 库校验拒绝 ad-hoc 的内嵌 Sparkle 框架）。
# 发版从此走本脚本：证书/公证档/Sparkle 私钥全在本机钥匙串，不依赖任何 secret。
# CI 保留 workflow_dispatch 手动触发做兜底，但正常情况下不要用它发版。
#
# 前置（一次性，均已就绪）：
#   1. 钥匙串里有 "Developer ID Application: TAO LIU (UAT3Y8UXCQ)"
#   2. xcrun notarytool store-credentials nightcat-notary（与 NightCat 共用）
#   3. Sparkle EdDSA 私钥在登录钥匙串（generate_keys 生成，公钥已写入 Info.plist）
#
# 发版步骤：改 Info.plist 的 CFBundleShortVersionString/CFBundleVersion → 运行本脚本
# 同版本已发过（远端有同名 tag）会直接拒绝，防误触。
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="UAT3Y8UXCQ"
IDENTITY="Developer ID Application: TAO LIU ($TEAM)"
NOTARY_PROFILE="${NOTARY_PROFILE:-nightcat-notary}"
APP_NAME="SoundIn"
STAGE="build-release"
# 必须绝对路径：第 4 步会 cd 进 staging 目录，相对路径会在那里失效
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
[ -n "$VERSION" ] && [ -n "$BUILD_NUM" ] || { echo "error: Info.plist 版本号为空" >&2; exit 1; }

# ── 防重发：远端已有同名 tag 说明这版发过了 ──
if git ls-remote --tags origin "refs/tags/v$VERSION" | grep -q .; then
  echo "error: v$VERSION 已存在于远端，先在 Info.plist 里升版本号" >&2
  exit 1
fi

# 签名身份必须在，别静默掉进 ad-hoc
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
  echo "error: 钥匙串里找不到 $IDENTITY" >&2; exit 1; }

echo "==> 发版 $APP_NAME $VERSION (build $BUILD_NUM)"

# ── 1. 构建 + Developer ID 签名（build-app.sh 认 SIGN_IDENTITY 环境变量）──
echo "==> 构建"
SIGN_IDENTITY="$IDENTITY" ./build-app.sh
APP=".build-cache/app/$APP_NAME.app"

# ── 2. 公证 + staple ──
echo "==> 公证（走 Apple 服务，约 1-2 分钟）"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto -c -k --keepParent "$APP" "$STAGE/app-for-notary.zip"
xcrun notarytool submit "$STAGE/app-for-notary.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"
rm "$STAGE/app-for-notary.zip"

# staple 后重新打包（zip 里必须是 stapled 版本）
ditto -c -k --keepParent "$APP" "$STAGE/$APP_NAME.app.zip"

# ── 3. GitHub Release（tag 由 release create 顺带打出）──
echo "==> 创建 Release v$VERSION"
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --generate-notes \
  "$STAGE/$APP_NAME.app.zip"

# ── 4. appcast + gh-pages ──
# generate_appcast 不带 --ed-key-file 时默认用钥匙串里的 Sparkle 私钥；
# enclosure URL 会按 zip 内 app 的 SUFeedURL 自动推导，和 CI 产物一致。
echo "==> 生成 appcast"
(cd "$STAGE" && "$SPARKLE_BIN/generate_appcast" .)
grep -q "shortVersionString>$VERSION<" "$STAGE/appcast.xml" || {
  echo "error: appcast 里没有 $VERSION 条目，中止推送" >&2; exit 1; }

echo "==> 推送 gh-pages"
REPO_DIR="$PWD"
cd "$STAGE"
git init -q .
git config user.name  "$(git -C "$REPO_DIR" config user.name  2>/dev/null || echo eliolewis77)"
git config user.email "$(git -C "$REPO_DIR" config user.email 2>/dev/null || echo eliolewis77@users.noreply.github.com)"
git checkout -q -B gh-pages
git add appcast.xml "$APP_NAME.app.zip"
git commit -q -m "appcast: v$VERSION"
REMOTE_URL="$(git -C "$REPO_DIR" remote get-url origin)"
git push -q --force "$REMOTE_URL" gh-pages

echo
echo "✅ v$VERSION 发版完成"
echo "   Release: https://github.com/eliolewis77/$APP_NAME/releases/tag/v$VERSION"
echo "   appcast: https://eliolewis77.github.io/$APP_NAME/appcast.xml"
