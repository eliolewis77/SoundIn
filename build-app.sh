#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
BUILD_DIR=".build-cache/app"
APP_DIR="$BUILD_DIR/SoundIn.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$PWD/.build-cache/clang" "$PWD/.build-cache/tmp"
CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang" \
TMPDIR="$PWD/.build-cache/tmp" \
swift build -c release --disable-sandbox \
  --cache-path .build-cache/swift-build \
  --manifest-cache local
cp ".build/release/SoundIn" "$MACOS/SoundIn"
cp Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Sparkle 以 SPM 二进制 target 形式链接，产物在 .build/release/Sparkle.framework。
# 必须手动拷进 Contents/Frameworks/ 并补 rpath，否则启动即崩：
#   dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
# rpath 用 @executable_path/../Frameworks（= Contents/Frameworks）而不是
# @loader_path/Frameworks —— 后者对主可执行文件解析成 Contents/MacOS/Frameworks，找不到。
SPARKLE_FRAMEWORK=".build/release/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  # 刻意不删旧目录：SPM 产物带符号链接（Versions/Current 等），rm + cp -R 在
  # 带链接时容易留下半残结构。直接 cp -R 覆盖，SPM 版本不变时内容幂等。
  cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/"
  # 全新拷贝的二进制，直接 Add rpath（不会重复追加）
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/SoundIn" 2>/dev/null || true
  # 框架内二进器的 LC_ID_DEREFENCE 需与外层引用一致，否则嵌套加载同样失败
  /usr/bin/install_name_tool -id "@rpath/Sparkle.framework/Versions/B/Sparkle" \
    "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Sparkle" 2>/dev/null || true
  echo "Sparkle.framework bundled"
else
  echo "warning: 未找到 $SPARKLE_FRAMEWORK，若代码引用了 Sparkle 将无法启动" >&2
fi

# Info.plist 里写入 Sparkle 需要的键值（用 PlistBuddy 就地合并，不覆盖源文件的其他内容）
PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
if [ -n "$PUBLIC_ED_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_ED_KEY" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_ED_KEY" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

cat > "$CONTENTS/PkgInfo" <<'EOF'
APPL????
EOF

# 签名身份解析顺序：
#   1. 环境变量 SIGN_IDENTITY（显式指定，CI 用它拿 Developer ID + 公证）
#   2. 本机可用的 "Apple Development" 开发证书（自动探测）
#   3. ad-hoc 临时签名（"-"，CI 无证书时的兜底）
#
# 为什么必须优先用开发证书：ad-hoc 签名的代码哈希**每次构建都变**，而 macOS 的 TCC
# 数据库（辅助功能 / 麦克风 / 语音识别授权）是按代码签名身份匹配的——身份一变，
# 之前授过的权全部作废，且授权项在系统设置里会变成不可勾选。固定证书可让授权长期有效。
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep 'Apple Development:' \
    | /usr/bin/head -1 \
    | /usr/bin/sed -E 's/.*"(.+)".*/\1/')"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="-"
  echo "warning: 未找到 Apple Development 证书，回退 ad-hoc 签名；TCC 授权会在下次构建后失效" >&2
else
  echo "签名身份: $SIGN_IDENTITY"
fi
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp --options runtime "$APP_DIR"
echo "$APP_DIR"
