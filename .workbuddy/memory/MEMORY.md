# SoundIn 项目长期备忘

## Git 工作流约定（2026-08-23 用户确认）
- 开发新功能一律切独立分支（如 `feat/xxx`），开发完验证通过后再合并回 `main`
- 不在 main 上直接做实验性功能；撤销未达预期功能时优先弃分支，而非 revert 序列
- 构建脚本：`./build-app.sh`，产物 `.build-cache/app/SoundIn.app`（已从 VoiceScribe.app 改名）
- **构建结果判断**：`./build-app.sh 2>&1 | tail -40` 拿到的是 tail 的退出码，必须 `grep "error:"` 判断真实结果；沙箱会拦 SwiftPM 写 `~/.swiftpm/security`（file-write-unlink）导致后台任务误报 failed，只要 stdout 有 `Build complete!` 就是成功，需要干净退出码时用 `dangerouslyDisableSandbox` 重跑
- **zsh 提交信息**：`-m "..."` 里含反引号会被当成命令替换，整条命令 parse error 且不执行。用 `git commit -F - <<'EOF'`（quoted heredoc）最稳

## 关键平台坑（macOS 26 SDK）
- `AXUIElementCopyAttributeValue` 只剩 3 参数（error 出参移除）
- `AVAudioSession` 在 macOS unavailable → 指定录音设备走 CoreAudio `kAudioOutputUnitProperty_CurrentDevice` 绑定引擎输入节点
- UID→设备翻译用 `kAudioHardwarePropertyTranslateUIDToDevice`（qualifier 传 CFString UID）
- SwiftUI ViewBuilder 嵌套错位可能编译通过但 UI 不渲染（Picker 缺闭合括号吞掉后续 Toggle 的教训）

## SwiftUI 设置页布局坑（2026-09-03 踩坑）
- **`GeometryReader` 不要直接当 Form/Section（底层 List 行）的外层布局元素**：行高测量时被提议高度 0，它会把 0 当自己的高度报回去 → 整行塌成 0、内容被裁掉，表现是"视图消失"。
- **不要用"量自身宽度反推子元素尺寸"做自适应**：会形成循环依赖（子元素尺寸 ← 量到的宽度 ← 容器宽度 ← 子元素尺寸），实测卡死在兜底最小值（热力图格子被压成 6pt）。
- 结论：设置页 Form 里的网格类视图，**用固定格子尺寸最稳**。若确实要自适应，须先确认容器能被撑满宽度（如有 `Spacer()`/固定 frame），再量宽度，不能靠内容宽度反推。

## Swift 6 并发坑（2026-09-03）
- **复用 `DateFormatter` / `ISO8601DateFormatter` 时，不要写成 `static let`**：两者都非 `Sendable`，Swift 6 会报 error「static property is not concurrency-safe ... may have shared mutable state」。这**不是误报**——日志/统计这类工具方法可能从主线程或网络回调线程发起，格式化器本身非线程安全。
- 正确解法：把格式化器作为**实例属性**，并把对它的使用**限制在一条串行队列内**（如 HotkeyFileLog 的 `queue`），靠队列串行化保证安全。**不要用 `nonisolated(unsafe)` 静默**——那只是关掉检查，竞争依然存在。
- 相关：`FileHandle` 的 `write(_:)` 在此工程里按非 throwing 调用（照抄既有写法即可），`close()` 需要 `try?`。
- **`MainActorEventSink`（P2-8，2026-09-03 已文档化关闭）**：非主线程 `send` 走 `Task { @MainActor in ... }` 入队，MainActor 串行消费，故「入队顺序=消费顺序」仅在**生产者是单一串行队列**时成立；并发 `send` 会乱序。调用方须满足其一：① 顺序无关（标量/last-wins，如 `audioLevel`；或消费端自带重排如分段转写按 `index` 在 `finishSegmentedTranscription` 里 `sorted`）；② 自带单调序号在消费端重组。当前四个 sink 生产者（installTap 回调、`SFSpeechRecognizer` resultHandler）均串行，实际不乱序——坑只在未来有人从并发线程接新 sink。已在 `SpeechManager.swift` 的 `MainActorEventSink` 注释写死不变式。

## 触发架构（2026-08-29 定版）
- **两个独立快捷键**：`clickShortcut`（单击切换开/关）+ `holdShortcut`（按住说话、松手停，含 `holdThreshold` 0.5/0.7/1.0s），同时生效、无二选一模式
- Carbon 注册两个热键 id=1(click)/id=2(hold) 按 id 分派；纯修饰键热键走 NSEvent flagsChanged（Click/Hold 各自 armed）
- 设置页交互约定：点击快捷键显示区即录制，不要单独"录制"按钮、不要多余操作提示（用户明确反馈）
- 授权/接管类橙色提示只在快捷键页最底部合并显示一处（去重），不要每块都重复
- 状态栏 displayShortcut 只显示单击键；两个 UserDefaults 键 voiceInputClickShortcut / voiceInputHoldShortcut

## 通用页设置项（2026-08-29 增补）
- 「去掉句末标点」开关：UserDefaults 键 `voiceInputStripTrailingPunctuation`（默认 false），stop() 仅在全部标点跟随逻辑之后、AX 权限检查之前剥除最后一个终止标点（。！？!?…）。

## 已回退待重启的功能
- 热力图「占满宽度」改动（2026-09-03 已回退）：原需求「把宽度占满、不强制显示三个月」。实现上先因外层 GeometryReader 把 Form 行高撑成 0 导致热力图消失，改背景量宽后又因循环依赖卡在 6pt 兜底值、格子被压极小。最终用户要求恢复原样：固定 cellSize=14、gap=3，无 GeometryReader，Section 标题回到「最近 13 周」。若日后重做自适应，须先解决容器撑满宽度的问题（见上方 SwiftUI 布局坑）。
- 流式实时预览：定过方案 A（标题区显示最新转写、无省略号、通用页独立开关）；API 引擎需每 4s 强切预览段（段最短 8s+静音≥0.45s 才自然切）。详见 2026-08-22/23 日志。
