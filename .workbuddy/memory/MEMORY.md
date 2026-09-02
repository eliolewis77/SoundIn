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

## 触发架构（2026-08-29 定版）
- **两个独立快捷键**：`clickShortcut`（单击切换开/关）+ `holdShortcut`（按住说话、松手停，含 `holdThreshold` 0.5/0.7/1.0s），同时生效、无二选一模式
- Carbon 注册两个热键 id=1(click)/id=2(hold) 按 id 分派；纯修饰键热键走 NSEvent flagsChanged（Click/Hold 各自 armed）
- 设置页交互约定：点击快捷键显示区即录制，不要单独"录制"按钮、不要多余操作提示（用户明确反馈）
- 授权/接管类橙色提示只在快捷键页最底部合并显示一处（去重），不要每块都重复
- 状态栏 displayShortcut 只显示单击键；两个 UserDefaults 键 voiceInputClickShortcut / voiceInputHoldShortcut

## 通用页设置项（2026-08-29 增补）
- 「去掉句末标点」开关：UserDefaults 键 `voiceInputStripTrailingPunctuation`（默认 false），stop() 仅在全部标点跟随逻辑之后、AX 权限检查之前剥除最后一个终止标点（。！？!?…）。

## 已回退待重启的功能
- 流式实时预览：定过方案 A（标题区显示最新转写、无省略号、通用页独立开关）；API 引擎需每 4s 强切预览段（段最短 8s+静音≥0.45s 才自然切）。详见 2026-08-22/23 日志。
