# SoundIn 代码独立 Review（2026-08-23）

> 由两个独立审查视角（核心引擎 / UI 与数据层）交叉得出，主要指控已人工核实。
> 规模：8 个 Swift 文件、约 4200 行、18 个提交。

## 🔴 P0：会实际咬人的

### P0-1 `isStarting` 卡死录音入口
- 位置：SpeechManager.swift `startAPIRecording`（sampleRate 守卫）、`startLocalRecording`（recognizer 不可用 / sampleRate 守卫）
- 问题：三处「设 errorMessage 后直接 return」的早退路径不复位 `isStarting`，而 `toggleRecording` 有 `guard !isStarting`。麦克风热插拔瞬间采样率为 0 并不罕见，一旦命中，菜单栏入口永久锁死到重启。
- 修复：早退路径改 throw，或在 startRecordingSafe 出口统一根据 isRecording 复位 isStarting。

### P0-2 配置档 JSON 损坏时静默回滚旧 Key
- 位置：APIProfiles.swift init
- 问题：`vs.apiProfiles` 解码失败会走迁移逻辑重建「默认」档，但旧键（vs.apiBaseURL 等 6 个）从未删除，等于把升级前的旧 API Key 复活且无任何提示。
- 修复：迁移成功后删除全部旧键；解码失败时写日志，不再依赖已删除的旧键"复活"数据。

## 🟠 P1：边界 bug

### P1-1 菜单栏状态是死代码
- `.voicePhaseChanged` 通知在 `currentPhase.didSet` 发布，但全项目无任何订阅者；菜单栏图标永远显示品牌图、"就绪"。
- 修复：App 侧 `.onReceive(NotificationCenter.default.publisher(for: .voicePhaseChanged))` 更新 phase。

### P1-2 Esc 取消泄漏全部临时音频文件
- 取消路径 `resetSession` 只清引用不删文件，每次 Esc 在 /tmp 漏 full.wav + segment-*.wav。
- 修复：resetSession / writer.reset 中先取消 in-flight 段任务，再删除文件。

### P1-3 分段转写单段失败被静默跳过
- 某段网络失败该段文字直接消失，前后段无缝拼接照常粘贴。
- 修复：失败段自动重试一次；仍失败插入可见占位标记，不让缺段无感混入。

### P1-4 权限弹窗期间误报"录音启动失败"
- 首次 `notDetermined` 时 `startRecordingSafe` 转入异步权限申请并返回，热键路径同步检查 `isRecording == false` 立即判失败、丢弃会话；授权后录音无人接收，再按热键还会取消掉已开始的识别任务。
- 修复：startRecordingSafe 区分"进入权限申请流程"与"启动失败"，权限申请期间热键路径保持会话挂起、不报错。

### P1-5 HUD 在窗口不可见时吞掉失败提示
- `update(phase:message:)` 末尾 `guard window.isVisible else { return }`；权限拒绝恰恰发生在窗口未显示时，错误完全不可达（叠加 P1-1）。
- 修复：failure/cancelled 分支若窗口不可见，先 show 再倒计时隐藏。

### P1-6 统计页数据不响应刷新
- `DictationStats` 不是可观察对象，统计页开着时新听写不刷新。
- 修复：改为 @Observable，record/清零时 bump revision，视图读取 revision 触发重算。

### P1-7 非分段长录音在主线程拼 multipart（挂账）
- 几分钟录音 = 几十 MB Data 拷贝 + body 拼接全在 MainActor，识别前 UI 卡顿。
- 修复方向：body 组装移到 detached 任务 / 流式上传。涉及较大重构，本轮暂缓。

## 🟡 P2：值得排期但不急（本轮不修）

- SettingsView 约 660 行上帝视图，引擎页/润色页大段复制体 → 抽公共组件
- HUD 窗口尺寸常量双份维护（136×72 写了两遍）→ 收敛到一处
- HUD 多屏定位用 `NSScreen.main`（key window 所在屏）→ 改用鼠标所在屏
- API Key 明文存 UserDefaults → 迁 Keychain
- DateFormatter 循环内反复新建 → static 缓存
- 「清空历史」无确认；连接测试结果在改完配置后不失效
- `stopRecordingAndWaitForText` 轮询 + 1.2s 魔法数截断（慢网丢尾字）→ continuation 竞速
- MainActorEventSink 不保证投递顺序；限流器 release 用 fire-and-forget Task
- detectSelectedText 主线程同步 AX 调用可能阻塞；粘贴成功判定靠固定 sleep 320ms
- HotkeyFileLog 无轮转；`case .failure(let _)` 等格式杂项

## 总评

最值得做的一次重构：把散落在 SpeechManager / HotkeyInputManager / VoiceScribeApp 三处的状态标志（isStarting / isRecording / isActive / currentPhase / sessionID×2）收敛为显式状态枚举 + 单一所有者。P0-1 与 P1-4、P1-5 都是这一结构性缺陷的症状。其次是临时文件生命周期统一交给 writer 类管理。
