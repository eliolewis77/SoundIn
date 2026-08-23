# SoundIn 项目长期备忘

## Git 工作流约定（2026-08-23 用户确认）
- 开发新功能一律切独立分支（如 `feat/xxx`），开发完验证通过后再合并回 `main`
- 不在 main 上直接做实验性功能；撤销未达预期功能时优先弃分支，而非 revert 序列
- 构建脚本：`./build-app.sh`，产物 `.build-cache/app/VoiceScribe.app`

## 关键平台坑（macOS 26 SDK）
- `AXUIElementCopyAttributeValue` 只剩 3 参数（error 出参移除）
- `AVAudioSession` 在 macOS unavailable → 指定录音设备走 CoreAudio `kAudioOutputUnitProperty_CurrentDevice` 绑定引擎输入节点
- UID→设备翻译用 `kAudioHardwarePropertyTranslateUIDToDevice`（qualifier 传 CFString UID）
- SwiftUI ViewBuilder 嵌套错位可能编译通过但 UI 不渲染（Picker 缺闭合括号吞掉后续 Toggle 的教训）

## 已回退待重启的功能
- 流式实时预览：定过方案 A（标题区显示最新转写、无省略号、通用页独立开关）；API 引擎需每 4s 强切预览段（段最短 8s+静音≥0.45s 才自然切）。详见 2026-08-22/23 日志。
