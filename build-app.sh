#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
BUILD_DIR=".build-cache/app"
APP_DIR="$BUILD_DIR/SoundIn.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS" "$CONTENTS/Resources"
CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang" \
TMPDIR="$PWD/.build-cache/tmp" \
swift build -c release --disable-sandbox \
  --cache-path .build-cache/swift-build \
  --manifest-cache local
cp ".build/release/VoiceScribe" "$MACOS/SoundIn"
cp Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/PkgInfo" <<'EOF'
APPL????
EOF

# 签名身份：默认用本机 Apple Development 证书（稳定签名，TCC 权限跨构建保留）。
# 可通过环境变量覆盖退回临时签名：SIGN_IDENTITY="-" ./build-app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: xiaohees@foxmail.com (5V2J4DPU4L)}"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "$APP_DIR"
