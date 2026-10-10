# SoundIn（声入）

A minimal menu-bar dictation & translation app for macOS. Hold a hotkey to dictate — transcribed with on-device Apple speech recognition or any OpenAI-compatible API — and the text lands right at your cursor. Select text in any app and rapid-tap a trigger key to translate it in place.

## Features

### 语音听写

- 菜单栏常驻，录音时显示轻量 HUD（实时波形，可在设置中关闭）。
- 两套独立全局快捷键：**单击切换**开/关 + **按住说话**（松手停止，长按阈值可设 0.5 / 0.7 / 1.0s）。
- 转写结果直接输入到光标处；开始录音时目标应用已有选中文本的，结果**替换选中内容**。
- 「去掉转写结果句末标点」开关。

### 划词翻译

- **连击翻译**：在任意应用选中文字，快速连击触发键（默认连按 3 次 Shift，次数与间隔可调）即翻译成目标语言。
- 智能写回：输入框内原地替换选区 / 写回光标处；网页、PDF 等不可编辑场景则改在选区旁弹出**翻译浮窗**（不抢焦点、可复制、自动消失）。

### 识别引擎与 AI 配置

- 双识别方式：**本机 Apple 语音识别**（免配置）或任何 OpenAI 兼容 `/audio/transcriptions`（Whisper 类）端点；识别语言（跟随系统 / 中 / 英 / 日）与麦克风可自选。
- **长录音分段转写**（API 模式）：按静音自动切段、边录边并发转写，松手即得全文。
- **多接口配置档**：转写、文字优化（润色）、翻译三处从同一套配置档（Base URL / API Key / 模型名）中各自选用；API Key 可留空（本地网关免 Key）。
- **文字优化**：可选配一个 LLM 端点（OpenAI 兼容 Chat Completions）对原始转写做二次加工，提示词可自定义、一键恢复默认。
- **翻译**同样走 OpenAI 兼容 Chat Completions 端点，目标语言可设。

### 统计与系统

- 转写历史 + GitHub 风格活跃度热力图 + 翻译记录，保留条数可调。
- 开机时启动、Sparkle 自动更新（自动检查可关，支持手动检查）、权限状态自检。
- 本地优先：API Key 仅存本机 Keychain / UserDefaults，音频除发往你配置的端点外不会离开本机。

## Requirements

- macOS 15.0+
- Swift 6.0 工具链（Xcode Command Line Tools）
- 一个 Whisper 类 API 端点（OpenAI、本地 Whisper 服务或任何兼容服务）—— Key 由你自备

## Build & Run

```bash
git clone <repo-url>
cd SoundIn
./build-app.sh
open .build-cache/app/SoundIn.app
```

`build-app.sh` 以 release 模式编译，并把产物打包签名成 `.app`，放在 `.build-cache/app`。

签名身份按以下顺序解析：`SIGN_IDENTITY` 环境变量 → 本机自动探测的 **Apple Development** 开发证书 → ad-hoc 临时签名（无证书时的兜底）。

用固定证书签名可让代码签名身份跨构建保持稳定，macOS 的 TCC 权限（麦克风 / 辅助功能等）不会因重新构建而失效。也可用环境变量显式指定：

```bash
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build-app.sh
```

## Configuration

首次启动后打开设置，添加一个 API 配置：填写 **Base URL / API Key / 模型名**。应用会向 `<baseURL>/audio/transcriptions` 发请求（OpenAI 兼容格式）。可选再配一个独立的「润色」档，对转写结果做后处理。

## Permissions

macOS 会请求**麦克风**权限；为把转写结果输入到光标处，可能还会请求**辅助功能（Accessibility）**权限。在「系统设置 → 隐私与安全性」中授予即可。

## Project Structure

| 路径 | 说明 |
| --- | --- |
| `Sources/` | Swift 源码：入口、设置页、热键管理、语音管理、HUD、统计与热力图 |
| `Resources/` | 应用图标与资源 |
| `design/` | UI 设计稿（设计演进记录，本地文件，不入库） |
| `build-app.sh` | release 编译 + 打包 + 签名 |
| `scripts/release.sh` | 本地发版：Developer ID 签名 → 公证 → GitHub Release → appcast → gh-pages |
| `Package.swift` | SwiftPM 包定义（executable target，产物名为 `SoundIn`） |

## Releases

发版走本地脚本 [scripts/release.sh](scripts/release.sh)。CI（GitHub Actions）没有开发者证书，ad-hoc 签名的产物曾因 Hardened Runtime 校验拒绝内嵌 Sparkle 框架而启动即崩（1.0.2 事故），故发版不依赖 CI。

步骤：

1. 把 `Info.plist` 里的 `CFBundleShortVersionString` / `CFBundleVersion` 改成新版本号（如 `1.0.11`）
2. 运行 `./scripts/release.sh`

脚本自动完成：构建 → Developer ID 签名 → 公证（notarize + staple）→ 创建 GitHub Release（自动生成变更说明，附 `SoundIn.app.zip`）→ 生成 appcast 并推送到 `gh-pages`。Sparkle 客户端从 `https://eliolewis77.github.io/SoundIn/appcast.xml` 拉取更新。远端已有同名 tag 时脚本会直接拒绝，防止重复发版。

> 前置条件（一次性，均已就绪）：钥匙串里的 Developer ID Application 证书、`xcrun notarytool store-credentials` 的公证凭据、登录钥匙串里的 Sparkle EdDSA 私钥。详见 `scripts/release.sh` 头部注释。
>
> [.github/workflows/release.yml](.github/workflows/release.yml) 仅保留 `workflow_dispatch` 手动触发作兜底，产物为 ad-hoc 签名、仅供版本归档，正常发版不要走它。

## License

[MIT](LICENSE) — 详见 LICENSE 文件。

## Disclaimer

个人项目，按「现状」提供，与任何转写服务商无隶属关系。你自行对配置的端点与密钥负责。
