# SoundIn 性能独立 Review（2026-08-29）

范围：全量源码 4496 行（SpeechManager 1934 / SoundInApp 850 / HotkeyInputManager 829 / VoiceInputHUD 400 等）。
基线：`main` @ 16efa65。只做只读分析，未修改代码。

## 🔴 高：用户能直接感知的卡顿

### PERF-1 转写请求体在主线程构造（P1-7 残留）
- 位置：`SpeechManager.swift:1405` `transcribeAudioFileWithAPI` → `1827` `multipartTranscriptionBody` → `1852` `body.append(try Data(contentsOf: audioURL))`
- 事实：`SpeechManager` 是 `@MainActor`（421-422 行），`transcribeAudioFileWithAPI` 无 `nonisolated`，整个函数体跑在主线程。几分钟录音 = 几十 MB `Data` 读入 + `Data` 逐段 `append` 拼接全在主线程 → 松手到出结果之间 UI 冻结。
- 对比：静音裁剪已优化（1440 行 `nonisolated static` + `Task.detached(priority: .utility)`），只剩 body 构造这半截没挪。
- 分段模式同样命中：`transcribeSegment`（1365）→ `transcribeAudioFileWithAPI`（1392），每段几 MB，限流 2 并发（448 行）下仍是主线程串行拼接，长录音累积卡顿。
- 修法：把 body 构造整体挪到 `nonisolated` + `Task.detached`（与 1440 行同款写法），或改用 `URLSession.uploadTask(with:fromFile:)` 流式上传，彻底不进内存。

## 🟠 中：持续开销 / 可累积成卡顿

### PERF-2 每次转写都重算系统语音区域
- 位置：`SpeechManager.swift:1872` `preferredSpeechAPILanguageCode` → `1899` `supportedSystemSpeechLocaleIdentifier`；调用点 `1110`、`1747`
- 事实：每次录音/转写都跑一遍 `SFSpeechRecognizer.supportedLocales()`（该 API 首次调用会加载语音识别资源，较慢）+ 循环内多次 `Locale(identifier:)` 构造（1900-1911 行），且都在 MainActor。
- 修法：结果缓存到静态变量（启动算一次，区域变化时失效）。

### PERF-3 音频电平每 21ms 往主线程投一次事件
- 位置：`SpeechManager.swift:1093/1158` `installTap(bufferSize: 1024)` → `1077/1147` `MainActorEventSink.send` → `404-414` 每次 `Task { @MainActor }`
- 事实：1024 帧 @48kHz ≈ 21.3ms 一次回调，每次都新建一个主线程 Task + 写 `audioLevel` 属性 → 约 47 次/秒，触发 SwiftUI 依赖更新。波形是装饰性动画，无需 47Hz 精度。
- 附带：RMS 计算（1196 行起）在音频实时线程遍历全部 1024 帧 × 声道，每 21ms 一次。
- 修法：降频投递（每 2-3 帧一次，约 16-24Hz，只保留最新值）；RMS 抽样计算即可。

### PERF-4 键盘事件被双监听重复处理
- 位置：`HotkeyInputManager.swift:323-330` 同时注册 `globalMonitor` 与 `localMonitor` 监听 `.keyDown/.keyUp/.flagsChanged`
- 事实：同一事件会被两个 monitor 各处理一次 → 每次按键创建 2 个主线程 Task、跑 2 遍 `handleKeyEvent`。打字时持续双倍开销（逻辑上被内部 guard 兜住不出错，但属于纯浪费）。
- 修法：事件去重（记录最近处理的 type+keyCode+时间戳跳过重复），或按需只保留一种监听。

### PERF-5 统计页每次刷新全量扫描 UserDefaults
- 位置：`DictationStats.swift:36-42` `totalCount` → `UserDefaults.standard.dictionaryRepresentation()`
- 事实：`dictionaryRepresentation()` 是全量键值拷贝（含系统键），O(全部键数)；`heatmapCells`（54 行）再读 91 次 `integer(forKey:)`。P1-6 之后统计页实时刷新 → 每次成功输入都重算一遍。
- 修法：维护累计缓存值（record 时累加），热力图按需惰性缓存。

## 🟡 低：理论开销，暂无用户可感影响

### PERF-6 日志每条一次 open/close 文件句柄
- 位置：`HotkeyInputManager.swift:24-36` `HotkeyFileLog.log` → `FileHandle(forWritingAtPath:)` + `seekToEndOfFile` + `close`
- 事实：在后台队列执行（不阻塞主线程，这点 OK），但一次录音几十条日志 = 几十次 open/seek/write/close 系统调用。
- 修法：进程内常驻 FileHandle，配合已有的 5MB 轮转（41-49 行）。

### PERF-7 限流器 release 用 fire-and-forget Task
- 位置：`SpeechManager.swift:1386-1388`
- 事实：每次分段完成创建一个无持有 Task 释放信号量，并发高时可能积压、顺序不定（与 P2-8 同源）。
- 修法：改为同步 release 或结构化并发。

### PERF-8 HUD 波形每帧重绘
- 位置：`VoiceInputHUD.swift:321` `TimelineView(.animation)`
- 事实：录音期间 60fps 持续渲染 4 根波形柱（含正弦计算）。视觉需要，开销可接受。
- 修法：可保持；若后续发现耗电问题再降帧或简化。

## 总评

最大瓶颈是 **PERF-1**：主线程拼几十 MB 请求体。它也是唯一"用户能明确感知"的性能问题（松手后卡一下）。修法清晰（照抄 1440 行已有的 `nonisolated` + detached 写法，或改 `uploadTask fromFile` 流式上传，后者更彻底）。

其次是 PERF-2 / PERF-3 这类"每次操作都重复做"的开销，属于低垂果实，改动小。PERF-4 是白花的双倍开销，去重即可。PERF-5 是数据规模增长后会变慢的隐患，建议顺手缓存。

注意 PERF-1 与审查报告 P1-7 是同一问题的两半：静音裁剪已后台化，body 构造仍是主线程——严格说 P1-7 只修了一半。
