# SoundIn（声入）

A minimal menu-bar speech-to-text app for macOS. Record audio with a global hotkey, transcribe it through any OpenAI-compatible Whisper-class API you configure, and have the text typed directly at your cursor.

## Features

- 菜单栏（状态栏）常驻，录音时显示轻量 HUD 波形。
- 两套独立全局快捷键：**单击切换**开/关 + **按住说话**（松手停止，可设 0.5 / 0.7 / 1.0s 触发阈值）。
- 可插拔转写引擎：任何兼容 OpenAI `/audio/transcriptions`（Whisper 类）的端点。
- 可选第二档「润色」配置（如一个 LLM 端点）对原始转写做二次加工。
- 转写历史 + GitHub 风格活跃度热力图。
- 「去掉句末标点」开关。
- 本地优先：API Key 仅存在本机 Keychain / UserDefaults，音频除发往你配置的端点外不会离开本机。

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

默认使用**临时签名**（`SIGN_IDENTITY=-`），无需任何个人证书即可本地运行。若希望跨构建保留稳定的代码签名身份（TCC 权限不重复弹窗），用环境变量指定你自己的证书：

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
| `design/` | UI 设计稿与评审笔记（设计演进记录） |
| `build-app.sh` | release 编译 + 打包 + 签名 |
| `Package.swift` | SwiftPM 包定义（executable target，产物名为 `SoundIn`） |

## Releases

发版是**全自动**的：把 `Info.plist` 里的 `CFBundleShortVersionString` 改成一个新版本号（如 `1.0.1`）并推送到 `main`，GitHub Actions 会自动构建 `.app`、打 `vX.Y.Z` 标签、并创建 GitHub Release（自动生成变更说明，并附上构建产物 `SoundIn.app.zip`）。同一个版本号若已发过版会自动跳过，不会重复发版。

> 注：CI 构建使用**临时签名（ad-hoc）**，产物仅供版本归档。要在你自己的 Mac 上正常使用该 `.app`，请用本地开发者证书重新签名，或按上面的 `Build & Run` 在本机自行构建。

## License

[MIT](LICENSE) — 详见 LICENSE 文件。

## Disclaimer

个人项目，按「现状」提供，与任何转写服务商无隶属关系。你自行对配置的端点与密钥负责。
