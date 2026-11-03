import AppKit
import ApplicationServices
import Carbon
import Foundation

// MARK: - 噪音过滤

/// 句子级噪音判定：代码/命令行/URL/碎片不进语料。纯函数，方便后续调整阈值。
enum TypingFilters {
    /// 单句长度上限：超长基本是整段粘贴/大文档，不是"高频语句"
    static let maxSentenceLength = 500

    /// URL / 域名
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://|www\."#, options: [.caseInsensitive])
    /// 路径样：/usr/bin、~/Downloads、a/b/c
    private static let pathRegex = try! NSRegularExpression(pattern: #"(?:^|\s)(?:/|~/)[\w./-]+|\w+/\w+/[\w-]+"#)
    /// 常见命令行开头
    private static let commandPrefixes = ["git ", "npm ", "pnpm ", "yarn ", "cd ", "sudo ", "brew ", "pip ", "python ", "cargo ", "docker ", "kubectl ", "make ", "ls ", "ssh "]
    /// 代码特征字符：ASCII 花括号/分号/运算符/反引号在自然语言（含中文聊天）里基本不出现
    private static let codeCharacters: Set<Character> = ["{", "}", ";", "`"]

    static func isNoise(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= maxSentenceLength else { return true }

        let range = NSRange(text.startIndex..., in: text)
        if urlRegex.firstMatch(in: text, options: [], range: range) != nil { return true }
        if pathRegex.firstMatch(in: text, options: [], range: range) != nil { return true }
        let lowered = text.lowercased()
        if commandPrefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        if text.contains(where: { codeCharacters.contains($0) }) { return true }
        if text.contains("=>") || text.contains("==") || text.contains("!=") || text.contains("&&") || text.contains("||") { return true }

        // 符号占比 >40% 视为代码；中文标点计入符号但不至于把正常句子顶过线
        var symbols = 0, digits = 0, letters = 0, cjk = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                cjk += 1
            case 0x30...0x39:
                digits += 1
            case 0x41...0x5A, 0x61...0x7A:
                letters += 1
            case 0x20...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E, 0x3000...0x303F, 0xFF00...0xFFEF:
                symbols += 1
            default:
                break
            }
        }
        let meaningful = symbols + digits + letters + cjk
        if meaningful == 0 { return true }
        if cjk == 0 && letters == 0 { return true }   // 纯数字/标点（数字救不了无字母无汉字的句子）
        if Double(symbols) / Double(meaningful) > 0.4 { return true }
        return false
    }
}

// MARK: - 采集存储

/// 采集结果明文持久层：按天一个 JSONL 文件，串行队列写盘。
/// 数据只落本机 Application Support，30 天滚动清理；界面/导出全走内存快照。
@MainActor
final class TypingCollectionStore: ObservableObject {
    static let shared = TypingCollectionStore()

    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let app: String
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    /// 保留天数（UserDefaults），0 = 永久保留（默认，不再自动删除）。
    /// 改动经设置页 onChange 即时触发 purgeExpired；启动与每日定时各清一次
    nonisolated static var retentionDays: Int {
        guard UserDefaults.standard.object(forKey: Self.retentionKey) != nil else { return 0 }
        return UserDefaults.standard.integer(forKey: Self.retentionKey)
    }
    private nonisolated static let retentionKey = "typingCollection.retentionDays"
    private nonisolated static let maxEntriesPerDay = 2000
    private nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SoundIn/typing-collection", isDirectory: true)
    private let ioQueue = DispatchQueue(label: "com.eliokit.soundin.typing-collection")

    private init() {}

    /// 记一条（flush 时调用）。单日条数超限直接丢弃，防止异常场景写爆磁盘。
    func record(text: String, app: String) {
        let entry = Entry(id: UUID(), timestamp: Date(), app: app, text: text)
        let day = dayKey(entry.timestamp)
        if isDailyCapReached(day) {
            HotkeyFileLog.shared.log("collector: daily cap reached, dropped entry")
            return
        }
        entries.insert(entry, at: 0)
        let line = Self.encodeLine(entry)
        ioQueue.async { Self.appendLine(line, day: day) }
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        let day = dayKey(entry.timestamp)
        let lines = entries.filter { dayKey($0.timestamp) == day }.map { Self.encodeLine($0) }
        ioQueue.async { Self.rewriteDay(day: day, lines: lines) }
    }

    func clear() {
        entries = []
        ioQueue.async { Self.removeDirectoryContents() }
    }

    /// 启动时加载存量 + 按保留设置清理 + 挂每日定时清理
    func load() {
        ioQueue.async {
            Self.removeExpiredFiles()
            let loaded = Self.readAllEntries()
            Task { @MainActor in
                self.entries = loaded
            }
        }
        scheduleDailyPurge()
    }

    /// 每日定时清理：常驻进程下保留期限也要准时生效（只靠启动清理会拖到下次启动）
    private var purgeTimer: Timer?
    private func scheduleDailyPurge() {
        purgeTimer?.invalidate()
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                TypingCollectionStore.shared.purgeExpired()
            }
        }
    }

    /// 按当前保留设置清理过期天（内存 + 日文件）。0 = 永久保留，不动
    func purgeExpired() {
        let days = Self.retentionDays
        guard days > 0 else { return }
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date())) else { return }
        var expired: Set<String> = []
        for entry in entries {
            let key = dayKey(entry.timestamp)
            if let day = Self.dayDate(key), day < cutoff { expired.insert(key) }
        }
        guard !expired.isEmpty else { return }
        entries.removeAll { expired.contains(dayKey($0.timestamp)) }
        ioQueue.async {
            for day in expired {
                try? FileManager.default.removeItem(at: Self.dayFilePath(day))
            }
        }
        HotkeyFileLog.shared.log("collector: purged \(expired.count) expired days (retention=\(days))")
    }

    /// 删除若干天的全部记录（按天/按周删共用，days = yyyy-MM-dd 集合）。
    /// 日文件整删：天内的记录全走该文件，与内存过滤天然一致
    func deleteDays(_ days: Set<String>) {
        guard !days.isEmpty else { return }
        entries.removeAll { days.contains(dayKey($0.timestamp)) }
        ioQueue.async {
            for day in days {
                try? FileManager.default.removeItem(at: Self.dayFilePath(day))
            }
        }
    }

    /// 批量删除指定 id 的记录（跨天）；受影响的天各自整文件重写
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let affectedDays = Set(entries.filter { ids.contains($0.id) }.map { dayKey($0.timestamp) })
        entries.removeAll { ids.contains($0.id) }
        for day in affectedDays {
            let lines = entries.filter { dayKey($0.timestamp) == day }.map { Self.encodeLine($0) }
            ioQueue.async { Self.rewriteDay(day: day, lines: lines) }
        }
    }

    /// 导出 Markdown：去重聚合，按出现频次降序——喂给 AI 整理英文的高频语句清单。
    /// entries 为 nil 时导出全部；传某天/某周的条目即分段导出
    func exportMarkdown(from entries: [Entry]? = nil) -> String {
        let source = entries ?? self.entries
        var stats: [String: (count: Int, latest: Date)] = [:]
        for entry in source {
            let key = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = stats[key] {
                stats[key] = (existing.count + 1, max(existing.latest, entry.timestamp))
            } else {
                stats[key] = (1, entry.timestamp)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "# SoundIn 输入采集",
            "",
            "导出于 \(formatter.string(from: Date()))，共 \(source.count) 条记录（去重后 \(stats.count) 种），按出现频次降序。",
            "",
        ]
        let sorted = stats.sorted { lhs, rhs in
            lhs.value.count != rhs.value.count
                ? lhs.value.count > rhs.value.count
                : lhs.value.latest > rhs.value.latest
        }
        for (text, info) in sorted {
            let display = text.replacingOccurrences(of: "\n", with: " ")
            lines.append("- \(display)\(info.count > 1 ? " ×\(info.count)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 日期键（主线程调用，DateFormatter 不跨线程）

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayKey(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private func isDailyCapReached(_ day: String) -> Bool {
        entries.filter { dayKey($0.timestamp) == day }.count >= Self.maxEntriesPerDay
    }

    // MARK: - 文件 IO（全部在 ioQueue 上执行；nonisolated 纯函数，只碰 Sendable 参数）

    private nonisolated static func dayFilePath(_ day: String) -> URL {
        directory.appendingPathComponent("\(day).jsonl")
    }

    private nonisolated static func encodeLine(_ entry: Entry) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry), let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }

    private nonisolated static func appendLine(_ line: String, day: String) {
        guard !line.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = dayFilePath(day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data((line + "\n").utf8))
    }

    private nonisolated static func rewriteDay(day: String, lines: [String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = lines.isEmpty ? Data() : Data((lines.joined(separator: "\n") + "\n").utf8)
        try? payload.write(to: dayFilePath(day), options: .atomic)
    }

    private nonisolated static func decodeLine(_ line: String) -> Entry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: Data(line.utf8))
    }

    private nonisolated static func readAllEntries() -> [Entry] {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [Entry] = []
        for url in fileURLs where url.pathExtension == "jsonl" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                if let entry = decodeLine(String(line)) {
                    result.append(entry)
                }
            }
        }
        return result.sorted { $0.timestamp > $1.timestamp }
    }

    private nonisolated static func removeExpiredFiles() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let retention = retentionDays
        let cutoff = Calendar.current.date(byAdding: .day, value: -retention, to: Date()) ?? Date()
        for url in fileURLs where url.pathExtension == "jsonl" {
            let day = url.deletingPathExtension().lastPathComponent
            guard let date = dayDate(day) else {
                try? FileManager.default.removeItem(at: url)   // 非法文件名顺手清掉
                continue
            }
            if retention > 0, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private nonisolated static func removeDirectoryContents() {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in fileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func dayDate(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
}

// MARK: - 输入采集器

/// 常驻采集各应用输入框中用户键入的文本：每个前台应用一个 AXObserver（alt-tab-macos
/// 同款模式，observer 与元素所属 app 绑定），任意时刻只观察一个焦点元素的值变化；
/// diff 出"本次新增的已提交文本"进缓冲，由句末标点/清空/切焦点/静默四个触发条件切句入库。
/// 中文经拼音上屏后的最终文本天然可见（marked text 段剔除，拼音碎片不进语料）。
@MainActor
final class TypingCollector: ObservableObject {
    static let shared = TypingCollector()

    private static let enabledKey = "typingCollection.enabled"

    @Published private(set) var isEnabled: Bool

    /// 每个前台应用一个 AXObserver
    private var observers: [pid_t: AXObserver] = [:]
    /// 已在 app 元素上注册过焦点变化通知的 pid：注册一次即可，app 存活期内持续有效
    private var focusSubscribedPids: Set<pid_t> = []
    private var workspaceToken: NSObjectProtocol?

    private var watchedElement: AXUIElement?
    /// 挂值通知时用的 observer：解绑必须用同一个，不能用"当前前台 App"去找——
    /// 焦点切换后两者不一致会让旧注册残留，重挂时报 notificationAlreadyRegistered
    private var watchedObserver: AXObserver?
    private var watchedAppName = ""
    /// 上一次"已提交文本"快照：diff 基准，排除未上屏拼音串与既有内容
    private var baseline = ""
    private var buffer = ""
    /// IME 组词暂存：VSCode 等 Chromium 应用不暴露 marked text，组词拼音直接进 AXValue。
    /// 中文 IME 活跃期间的纯字母增量先进隔离区——候选上屏（拼音被中文替换）则丢弃，
    /// 2.5s 无后续（回车上屏拼音/真的在打英文）则转正入缓冲。
    private var quarantine = ""
    private var lastQuarantineAt = Date.distantPast
    private var silenceTimer: Timer?
    /// 轮询兜底：AX 值变化通知在部分 App 上不可靠（注册成功但不投递/严重延迟），
    /// 0.6s 轮询 watched 元素的值走同一条幂等 diff 路径，保证最终都能采到
    private var pollTimer: Timer?
    /// Electron 激活后异步重试订阅的防重入标记
    private var retryingFocus = false

    private static let silenceFlushInterval: TimeInterval = 5
    private static let pollInterval: TimeInterval = 0.6
    private static let sentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?", ";", "；", "\n"]
    private static let maxWatchedValueLength = 10000

    /// 命令行/密码管理器/钥匙串：输入即命令或敏感信息，整段排除
    private static let excludedAppBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.termius.dmg",
        "com.apple.Passwords", "com.apple.KeychainAccess",
        "com.1password.1password", "com.bitwarden.desktop", "org.keepassxc.KeePassXC",
    ]

    /// AXObserver 回调携带的 CF 对象非 Sendable，无法直接跨越隔离域；
    /// 用 @unchecked Sendable 装载（AXUIElement/CFString 是线程安全的不可变 CF 对象），
    /// 且回调必在主 run loop 触发，assumeIsolated 后实际没有任何跨线程传递。
    private struct AXEvent: @unchecked Sendable {
        let element: AXUIElement
        let notification: String
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var enabled: Bool { isEnabled }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        isEnabled = on
        if on { start() } else { stop() }
    }

    // MARK: - 生命周期

    func start() {
        guard isEnabled, workspaceToken == nil else { return }
        guard AXIsProcessTrusted() else {
            HotkeyFileLog.shared.log("collector: start skipped, AX not trusted")
            return
        }
        TypingCollectionStore.shared.load()
        let center = NSWorkspace.shared.notificationCenter
        workspaceToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleFocusChanged()
            }
        }
        // 启动即对齐一次当前焦点（启动时不会有 didActivate 事件）
        handleFocusChanged()
        startPolling()
        HotkeyFileLog.shared.log("collector: started")
    }

    /// 轮询兜底：与通知共用 handleValueChange 的幂等 diff，重复读同值无副作用
    private var lastPolledValueLen = -1
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, let element = self.watchedElement else { return }
                let len = self.rawValue(of: element).count
                if len != self.lastPolledValueLen {
                    self.lastPolledValueLen = len
                    HotkeyFileLog.shared.log("collector: poll saw valueLen=\(len)")
                }
                self.handleValueChange(element: element)
            }
        }
    }

    func stop() {
        flushBuffer(reason: "stop")
        silenceTimer?.invalidate()
        silenceTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let token = workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceToken = nil
        }
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        focusSubscribedPids.removeAll()
        watchedElement = nil
        watchedObserver = nil
        baseline = ""
        HotkeyFileLog.shared.log("collector: stopped")
    }

    // MARK: - AXObserver 接线

    private func ensureObserver(pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success, let observer else {
            HotkeyFileLog.shared.log("collector: AXObserverCreate failed for pid \(pid)")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        return observer
    }

    /// C 回调：run loop source 挂在主 run loop 上，回调必在主线程，直接 assumeIsolated
    /// 保持事件顺序（Task 跳 actor 会乱序，破坏 diff 基准）。
    private static let axCallback: AXObserverCallback = { _, element, notification, _ in
        let event = AXEvent(element: element, notification: notification as String)
        MainActor.assumeIsolated {
            TypingCollector.shared.handleAXEvent(event)
        }
    }

    private func handleAXEvent(_ event: AXEvent) {
        if event.notification == kAXFocusedUIElementChangedNotification as String {
            handleFocusChanged()
        } else if event.notification == kAXValueChangedNotification as String {
            handleValueChange(element: event.element)
        }
    }

    private func handleFocusChanged() {
        guard isEnabled else { return }
        flushBuffer(reason: "focus")
        silenceTimer?.invalidate()
        // 不能在 AX 通知投递栈内嵌套注册新通知：注册会返回 success 但永远不装配
        // （实测 TextEdit 上值事件从此不投递；启动路径的顶层订阅则一切正常）。
        // 跳出当前 MIG 调用栈，到下一个 main runloop tick 再重订阅。
        Task { @MainActor [weak self] in
            self?.resubscribeFocus()
        }
    }

    /// 对齐到当前前台应用的焦点元素。Electron 类应用首次会拿不到焦点元素，
    /// 激活其无障碍树后延迟重试一次（异步等待，不阻塞主线程）。
    private func resubscribeFocus() {
        unsubscribeValueWatch()
        retryingFocus = false
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard let observer = ensureObserver(pid: pid) else { return }
        if !focusSubscribedPids.contains(pid) {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.3)
            let err = AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, nil)
            if err == .success {
                focusSubscribedPids.insert(pid)
            } else {
                HotkeyFileLog.shared.log("collector: focus notification add failed pid \(pid) err \(err.rawValue)")
            }
        }
        let bundleID = app.bundleIdentifier
        let appName = app.localizedName ?? bundleID ?? "?"
        if subscribeValueWatch(pid: pid, bundleID: bundleID, appName: appName, observer: observer) { return }
        guard !retryingFocus else { return }
        retryingFocus = true
        HotkeyInputManager.activateElectronAccessibility(pid: pid)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.retryingFocus, self.isEnabled,
                  let observer = self.observers[pid] else { return }
            self.retryingFocus = false
            _ = self.subscribeValueWatch(pid: pid, bundleID: bundleID, appName: appName, observer: observer)
        }
    }

    /// 对新焦点元素挂值变化通知。返回 false 表示当前元素不可采集（非输入框/超长/黑名单）。
    private func subscribeValueWatch(pid: pid_t, bundleID: String?, appName: String, observer: AXObserver) -> Bool {
        guard let element = HotkeyInputManager.focusedAXElement(frontmostPID: pid) else {
            HotkeyFileLog.shared.log("collector: subscribe no focused element pid=\(pid)")
            return false
        }

        // 角色白名单（AXSecureTextField 不在其中）；再显式查一次安全角色作纵深防御，
        // 防止未来白名单扩展时把密码框放进来
        let role = HotkeyInputManager.axRole(of: element)
        guard HotkeyInputManager.editableAXRoles.contains(role), role != "AXSecureTextField" else {
            HotkeyFileLog.shared.log("collector: subscribe skip role=\(role) pid=\(pid)")
            return false
        }
        if let bundleID {
            if bundleID == Bundle.main.bundleIdentifier || Self.excludedAppBundleIDs.contains(bundleID) {
                HotkeyFileLog.shared.log("collector: subscribe skip blacklisted \(bundleID)")
                return false
            }
        }

        let value = rawValue(of: element)
        guard value.count <= Self.maxWatchedValueLength else {
            // 超长基本是网页正文/文档容器误报为输入框，diff 与存储都不该碰它
            HotkeyFileLog.shared.log("collector: skip oversized element (\(value.count) chars)")
            return false
        }

        watchedElement = element
        watchedObserver = observer
        watchedAppName = appName
        baseline = Self.committedText(value: value, markedRange: markedRange(of: element))
        let err = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, nil)
        if err == .notificationAlreadyRegistered {
            // 已注册即达到目的（常见于快速切换焦点后的重订阅），照常视为成功
            HotkeyFileLog.shared.log("collector: value notification already registered, reuse pid=\(pid)")
        } else if err != .success {
            HotkeyFileLog.shared.log("collector: value notification add failed err \(err.rawValue) role=\(role) pid=\(pid)")
            watchedElement = nil
            watchedObserver = nil
            return false
        }
        HotkeyFileLog.shared.log("collector: watching pid=\(pid) app=\(appName) role=\(role) baselineLen=\(baseline.count)")
        return true
    }

    private func unsubscribeValueWatch() {
        if let element = watchedElement, let observer = watchedObserver {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        }
        watchedElement = nil
        watchedObserver = nil
        watchedAppName = ""
        baseline = ""
    }

    // MARK: - 值变化 → diff → 缓冲

    private func handleValueChange(element: AXUIElement) {
        guard isEnabled, let watched = watchedElement, CFEqual(element, watched) else { return }
        // 每次事件重查安全角色：网页密码框可能在同元素上切换显示形态
        if HotkeyInputManager.axRole(of: element) == "AXSecureTextField" { return }

        let value = rawValue(of: element)
        let committed = Self.committedText(value: value, markedRange: markedRange(of: element))
        let baselineNS = baseline as NSString
        let committedNS = committed as NSString
        let bufferLenBefore = buffer.count

        if committedNS.hasPrefix(baselineNS as String) {
            if committedNS.length > baselineNS.length {
                let delta = committedNS.substring(from: baselineNS.length)
                appendDelta(delta)
                emitCompleteSentences()
            }
        } else if baselineNS.hasPrefix(committedNS as String),
                  buffer.count >= baselineNS.length - committedNS.length {
            // 尾部回删（打错字）：缓冲同步去掉同样长度的尾巴，修正内容不进语料
            let removed = baselineNS.length - committedNS.length
            buffer = String(buffer.dropLast(removed))
            quarantine = String(quarantine.dropLast(min(removed, quarantine.count)))
        } else if !quarantine.isEmpty {
            // 候选词上屏：组词拼音被替换成中文。丢弃隔离区，把新上屏的内容接回缓冲
            // （部分提交时残余拼音经 appendDelta 重新隔离）；缓冲里更早的内容不 flush
            quarantine = ""
            let newSegment = Self.substringAfterCommonPrefix(baselineNS, committedNS)
            if !newSegment.isEmpty {
                appendDelta(newSegment)
                emitCompleteSentences()
            }
        } else {
            // 中间编辑/整体替换：收走已缓冲内容后重置基准，本次差异不采集
            flushBuffer(reason: "edit")
        }
        baseline = committed
        // 只在缓冲真的变化时重排静默 flush：轮询每 0.6s 都会走到这里，
        // 无条件重排会让空闲轮询把 flush 永远推后、永不触发
        if buffer.count != bufferLenBefore {
            scheduleSilenceFlush()
        }
        promoteStaleQuarantine()
    }

    /// 增量分流：中文 IME 活跃时的纯字母增量疑似组词拼音，进隔离区观察；
    /// 其余（中文上屏、标点、ABC 输入源的英文）直接进缓冲
    private func appendDelta(_ delta: String) {
        if Self.isPinyinLike(delta), Self.chineseIMEActive() {
            quarantine += delta
            lastQuarantineAt = Date()
            return
        }
        buffer += quarantine
        quarantine = ""
        buffer += delta
    }

    /// 隔离区超时转正：2.5s 内没有候选上屏的替换事件，说明用户是真的要这些字符
    /// （回车上屏拼音、或在中文 IME 下打英文）。由轮询 tick 周期调用。
    private func promoteStaleQuarantine() {
        guard !quarantine.isEmpty else { return }
        guard Date().timeIntervalSince(lastQuarantineAt) > 2.5 else { return }
        let before = buffer.count
        buffer += quarantine
        quarantine = ""
        emitCompleteSentences()
        if buffer.count != before {
            scheduleSilenceFlush()
        }
    }

    /// 缓冲中的完整句（句末标点/换行结尾）立即切出入库，残句留给 flush 触发条件
    private func emitCompleteSentences() {
        while let idx = buffer.firstIndex(where: { Self.sentenceTerminators.contains($0) }) {
            let segment = String(buffer[...idx])
            buffer = String(buffer[buffer.index(after: idx)...])
            collect(segment)
        }
    }

    private func flushBuffer(reason: String) {
        guard !buffer.isEmpty || !quarantine.isEmpty else { return }
        emitCompleteSentences()
        let remainder = buffer + quarantine
        buffer = ""
        quarantine = ""
        collect(remainder)
        HotkeyFileLog.shared.log("collector: flushed (\(reason))")
    }

    private func collect(_ rawSegment: String) {
        let text = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        guard !TypingFilters.isNoise(text) else {
            HotkeyFileLog.shared.log("collector: noise dropped (\(text.count) chars)")
            return
        }
        TypingCollectionStore.shared.record(text: String(text.prefix(TypingFilters.maxSentenceLength)), app: watchedAppName)
    }

    private func scheduleSilenceFlush() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Self.silenceFlushInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushBuffer(reason: "silence")
            }
        }
    }

    // MARK: - AX 读取辅助

    private func rawValue(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return "" }
        return text
    }

    /// 未上屏的拼音/候选串（marked text）范围。nil 表示无标记段。
    /// kAXMarkedTextRangeAttribute 在 Swift 里不可见，AX 属性常量本质就是 CFString，
    /// 与现有代码用 "AXManualAccessibility" 字面量同一做法。
    private func markedRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMarkedTextRange" as CFString, &ref) == .success,
              let axValue = ref, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        return range
    }

    /// 剔除未上屏段后的"已提交文本"。范围按 UTF-16 单位算（CFRange 语义），
    /// 用 NSString 索引保证中英混排下位置不错位。
    private static func committedText(value: String, markedRange: CFRange?) -> String {
        guard let range = markedRange else { return value }
        let ns = value as NSString
        let location = min(range.location, ns.length)
        let length = min(range.length, ns.length - location)
        return ns.replacingCharacters(in: NSRange(location: location, length: length), with: "")
    }

    /// b 相对 a 新增的尾部内容（去掉公共前缀，UTF-16 对齐）
    nonisolated private static func substringAfterCommonPrefix(_ a: NSString, _ b: NSString) -> String {
        var i = 0
        let max = min(a.length, b.length)
        while i < max, a.character(at: i) == b.character(at: i) { i += 1 }
        return b.substring(from: i)
    }

    /// 疑似组词拼音：全部由字母（及组词分隔符空格/'）组成且至少含一个字母。
    /// 中文、数字、标点、大写开头的英文都走正常路径。
    nonisolated private static func isPinyinLike(_ delta: String) -> Bool {
        var hasLetter = false
        for ch in delta.unicodeScalars {
            if ch == " " || ch == "'" { continue }
            guard (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") else { return false }
            hasLetter = true
        }
        return hasLetter
    }

    /// 当前选中输入源是否为输入法（非 ABC 键盘布局）。
    /// 只在增量疑似拼音时才调用，TIS 查询频率与组词键入同频，开销可忽略。
    nonisolated private static func chineseIMEActive() -> Bool {
        let filter = [kTISPropertyInputSourceIsSelected as String: kCFBooleanTrue] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for src in list {
            // TISGetInputSourceProperty 是 Get 规则：返回引用不保留，
            // 用 takeRetainedValue 会过度释放 TIS 缓存的属性对象，后续 retain 直接崩
            guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID as CFString) else { continue }
            let cf = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if let id = cf as? String, id.contains("inputmethod") {
                return true
            }
        }
        return false
    }
}
