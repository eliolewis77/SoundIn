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
cp ".build/release/SoundIn" "$MACOS/SoundIn"
cp Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/PkgInfo" <<'EOF'
APPL????
EOF

# 签名身份：默认使用临时签名（ad-hoc, "-"），无需任何个人证书即可本地运行。
# 若希望跨构建保留稳定的代码签名身份（TCC 权限不重复弹窗），用环境变量指定自己的证书：
#   SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build-app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "$APP_DIR"
