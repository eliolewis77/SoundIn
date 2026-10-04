import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.eliokit.soundin", category: "hotkey")

/// 文件诊断日志：~/Library/Logs/SoundIn-debug.log（不受系统日志沙箱限制）
final class HotkeyFileLog: @unchecked Sendable {
    static let shared = HotkeyFileLog()
    private let queue = DispatchQueue(label: "com.eliokit.soundin.filelog")

    private static let logPath = NSString(string: "~/Library/Logs/SoundIn-debug.log").expandingTildeInPath
    private static let rotationByteLimit = 5 * 1024 * 1024

    /// 复用时间戳格式化器：原先每条日志都新建一个 ISO8601DateFormatter（PERF-6）。
    /// 用实例属性而非 static：static 会被 Swift 6 判为跨线程共享可变状态
    /// （ISO8601DateFormatter 非 Sendable，且 log() 可能从主线程/网络回调线程发起）。
    /// 实例属性只在下面的串行 queue 上访问，既通过并发检查，也确实没有竞争。
    private let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 常驻文件句柄：原先每条日志都 open / seekToEnd / write / close（PERF-6）
    private var handle: FileHandle?
    /// 当前日志文件的大小估算：写入时累加，超过上限触发轮转。
    /// 仅在打开句柄时按真实大小校准一次，取代原先每条日志一次的 stat。
    private var knownSize = 0

    private init() {
        let dir = (Self.logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func log(_ message: String) {
        queue.async {
            self.writeLine(message)
        }
    }

    /// 只在 queue 上串行调用。时间戳也在这里生成（而不是在调用方线程），
    /// 以保证 stampFormatter 只被这一条串行队列访问。
    private func writeLine(_ message: String) {
        let line = "\(stampFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { openHandle() }
        if knownSize > Self.rotationByteLimit {
            rotateLocked()
            openHandle()
        }
        guard let handle else { return }
        handle.write(data)
        knownSize += data.count
    }

    /// 打开（或轮转后重新建立）日志文件，并把 knownSize 校准到文件真实大小
    private func openHandle() {
        let path = Self.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let opened = FileHandle(forWritingAtPath: path) else { return }
        opened.seekToEndOfFile()
        handle = opened
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        knownSize = (attrs?[.size] as? Int) ?? 0
    }

    /// 归档当前日志为 .old（只保留最近一份旧日志），句柄置空；
    /// 下次写入会重新建文件。轮转语义与改造前一致：先删旧 .old，再把当前文件改名。
    private func rotateLocked() {
        let path = Self.logPath
        let oldPath = path + ".old"
        if let handle { try? handle.close() }
        handle = nil
        try? FileManager.default.removeItem(atPath: oldPath)
        try? FileManager.default.moveItem(atPath: path, toPath: oldPath)
        knownSize = 0
    }
}

@MainActor
final class HotkeyInputManager {
    static let shared = HotkeyInputManager()

    /// 最近一次快捷键注册的结果；nil 表示成功
    private(set) var lastRegistrationError: String?

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt16
        var modifiersRawValue: UInt

        var modifiers: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        }

        /// ⌘/⌃/⌥/⇧ 四个真实修饰键
        static let realModifierKeys: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

        /// 该 keyCode 是否为修饰键本身（用于识别"纯修饰键热键"）
        static func isModifierKeyCode(_ code: UInt16) -> Bool {
            [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(code)
        }

        /// 纯修饰键热键（如只按 ⌘⌥，不带其他按键）
        var isModifierOnly: Bool {
            !modifiers.intersection(Self.realModifierKeys).isEmpty &&
            Self.isModifierKeyCode(keyCode)
        }

        func matches(_ event: NSEvent) -> Bool {
            event.keyCode == keyCode &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
        }

        var displayText: String {
            let ordered: [(NSEvent.ModifierFlags, String)] = [
                (.control, "⌃"), (.shift, "⇧"), (.option, "⌥"), (.command, "⌘")
            ]
            let modifierText = ordered.filter { modifiers.contains($0.0) }.map(\.1).joined()
            // 纯修饰键热键只显示修饰符本身
            if Self.isModifierKeyCode(keyCode) {
                return modifierText.isEmpty ? Self.keyName(keyCode) : modifierText
            }
            return modifierText + Self.keyName(keyCode)
        }

        /// 键码 → 显示名。原实现只映射了 Space / F1–F12 / 数字 1–5，
        /// 其余一律显示成 "Key 35"——连击翻译的触发键要让用户能挑字母数字标点，
        /// 这里补全成完整常用键位表。未知键码仍回退到 "Key N"。
        static func keyName(_ code: UInt16) -> String {
            if let name = keyNames[code] { return name }
            return "Key \(code)"
        }

        /// 键名表。internal 而非 private：连击翻译的触发键白名单要查它。
        static let keyNames: [UInt16: String] = [
            // 字母（ANSI 键位）
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            // 数字行
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            25: "9", 26: "7", 28: "8", 29: "0",
            // 标点
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            // 功能键
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12",
            49: "Space"
        ]
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isShortcutHeld = false
    private var isHoldActive = false
    private var isActive = false
    private var isFinishing = false
    private var sessionID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var longPressTask: Task<Void, Never>?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?
    private var isCaptureMode = false
    static let defaultShortcut = Shortcut(
        keyCode: 111,
        modifiersRawValue: NSEvent.ModifierFlags([.function, .command, .option])
            .intersection(.deviceIndependentFlagsMask).rawValue
    )

    /// 两块独立触发：单击切换 + 长按说话，两个快捷键同时生效
    enum TriggerKind: String { case click, hold }
    enum CaptureTarget: String { case click, hold }

    var clickShortcut: Shortcut = loadClickShortcut() {
        didSet { saveClickShortcut(); registerCarbonHotKey() }
    }
    var holdShortcut: Shortcut = loadHoldShortcut() {
        didSet { saveHoldShortcut(); registerCarbonHotKey() }
    }

    static let defaultHoldThreshold: TimeInterval = 0.7

    var holdThreshold: TimeInterval = (UserDefaults.standard.object(forKey: "voiceInputHoldThreshold") as? Double) ?? defaultHoldThreshold {
        didSet {
            UserDefaults.standard.set(holdThreshold, forKey: "voiceInputHoldThreshold")
        }
    }

    /// 是否去掉转写结果句末的最后一个终止标点（。！？!?…）。默认关闭，保留现有行为。
    var stripTrailingPunctuation: Bool = UserDefaults.standard.bool(forKey: "voiceInputStripTrailingPunctuation") {
        didSet {
            UserDefaults.standard.set(stripTrailingPunctuation, forKey: "voiceInputStripTrailingPunctuation")
        }
    }

    // MARK: - 连击翻译触发设置

    /// 连击翻译的触发键（纯按键，不带修饰键）。默认 Space。
    var translateKey: UInt16 = {
        let raw = UserDefaults.standard.object(forKey: "voiceInputTranslateKey") as? Int
        guard let raw, HotkeyInputManager.isAllowedTranslateKey(UInt16(truncatingIfNeeded: raw)) else {
            return UInt16(kVK_Space)
        }
        return UInt16(truncatingIfNeeded: raw)
    }() {
        didSet { UserDefaults.standard.set(Int(translateKey), forKey: "voiceInputTranslateKey") }
    }

    /// 连击到该次数即触发翻译。默认 3。
    var translateTapCount: Int = {
        let raw = UserDefaults.standard.object(forKey: "voiceInputTranslateTapCount") as? Int ?? 3
        return min(5, max(2, raw))
    }() {
        didSet { UserDefaults.standard.set(translateTapCount, forKey: "voiceInputTranslateTapCount") }
    }

    /// 相邻两次按键的最大间隔，超时则重新计数。默认 0.6 秒。
    var translateInterval: TimeInterval = {
        let raw = UserDefaults.standard.object(forKey: "voiceInputTranslateInterval") as? Double ?? 0.6
        return min(2.0, max(0.3, raw))
    }() {
        didSet { UserDefaults.standard.set(translateInterval, forKey: "voiceInputTranslateInterval") }
    }

    /// 触发键合法白名单：只放"按下后只会往输入框里插字符"的键。
    /// Return/Tab/Esc/删除键/方向键/F 键/修饰键全部排除——它们在翻译开始前
    /// 就已经改变了输入状态（提交表单、切焦点、删内容），无法用后续写回补救。
    static func isAllowedTranslateKey(_ code: UInt16) -> Bool {
        Shortcut.keyNames[code] != nil && !Self.forbiddenTranslateKeys.contains(code)
    }

    private static let forbiddenTranslateKeys: Set<UInt16> = [
        36,   // Return
        48,   // Tab
        51,   // Delete
        53,   // Escape
        115,  // Home
        116,  // PageUp
        117,  // Forward Delete
        119,  // End
        121,  // PageDown
        123, 124, 125, 126, // 方向键
        96, 97, 98, 99, 100, 101, 103, 109, 111, // F3 / F5…F12
        118, 120, 122 // F4 / F2 / F1
    ]

    /// 候选触发键 candidate 是否与某个语音快捷键撞键。
    /// 必须传 candidate 而不是拿当前 translateKey 比——录制时 translateKey 还没更新，
    /// 拿旧值比会漏掉"用户正在录的键正好撞上"这种最该拦的情况。
    /// 只算"纯单键"快捷键：带修饰键的（如 ⌘Space）不会吞掉裸键，不构成冲突。
    func translateKeyConflicts(with shortcut: Shortcut, candidate: UInt16? = nil) -> Bool {
        let key = candidate ?? translateKey
        return shortcut.keyCode == key && shortcut.modifiers.isEmpty
    }

    var onStateChange: ((VoiceInputPhase) -> Void)?

    static var isShortcutCaptureActive = false

    /// 连击翻译触发键录制中。与 isShortcutCaptureActive 分开：
    /// 后者会让常驻 handleKeyEvent 直接返回 false，两者语义不同、作用域也不同。
    static var isTriggerKeyCaptureActive = false

    // 录制快捷键使用独立的监视器，避免覆盖 start() 的常驻监听
    private var captureGlobalMonitor: Any?
    private var captureLocalMonitor: Any?
    private var captureCompletion: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    private var captureCancelHandler: (() -> Void)?
    // 录制"纯修饰键热键"时的中间状态：按下的修饰键组合 + 第一个修饰键的 keyCode
    private var capturePendingModifiers: NSEvent.ModifierFlags = []
    private var captureFirstModifierKeyCode: UInt16 = 0

    func beginSystemCapture(
        onCancel: @escaping () -> Void,
        onComplete: @escaping (UInt16, NSEvent.ModifierFlags) -> Void
    ) {
        endSystemCapture()
        logger.notice("shortcut capture begin")
        HotkeyFileLog.shared.log("capture begin")
        isCaptureMode = true
        Self.isShortcutCaptureActive = true
        captureCompletion = onComplete
        captureCancelHandler = onCancel
        capturePendingModifiers = []
        captureFirstModifierKeyCode = 0

        // 关键：Carbon 热键是系统级拦截，事件不会进入应用事件队列。
        // 不注销的话，用户重录当前组合键时录制监听器永远收不到按键。
        unregisterCarbonHotKey()

        captureGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            logger.notice("capture: global event type=\(event.type.rawValue, privacy: .public) keyCode=\(event.keyCode, privacy: .public)")
            Task { @MainActor in
                self?.finishSystemCapture(with: event)
            }
        }
        captureLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let captured = event
            logger.notice("capture: local event type=\(event.type.rawValue, privacy: .public) keyCode=\(event.keyCode, privacy: .public)")
            Task { @MainActor in
                self?.finishSystemCapture(with: captured)
            }
            return nil
        }
    }

    /// 主动取消录制（设置界面再次点击按钮时调用）
    func cancelSystemCapture() {
        guard isCaptureMode else { return }
        HotkeyFileLog.shared.log("capture cancelled programmatically")
        endSystemCapture()
    }

    // MARK: - 连击翻译触发键录制

    /// 录制触发键期间的回调。非法键会走 onRejected，录制**不结束**，用户可直接重按。
    private var triggerKeyCaptureReject: ((String) -> Void)?

    /// 开始录制连击翻译的触发键。与快捷键录制的区别：
    /// 1. 不接受修饰键（带修饰键的组合一律拒绝）
    /// 2. 撞语音快捷键 → 拒绝，提示换键
    /// 3. 非法键（Return/Tab/方向键/F 键…）→ 拒绝，保持录制态
    /// 完成/取消都通过 onTriggerKeyCaptureComplete / onTriggerKeyCaptureCancelled 回调。
    func beginTriggerKeyCapture(onReject: @escaping (String) -> Void) {
        endTriggerKeyCapture()
        logger.notice("translate key capture begin")
        HotkeyFileLog.shared.log("translate-key capture begin")
        Self.isTriggerKeyCaptureActive = true
        triggerKeyCaptureReject = onReject

        captureGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleTriggerKeyCapture(event)
            }
        }
        captureLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let captured = event
            Task { @MainActor in
                self?.handleTriggerKeyCapture(captured)
            }
            return nil
        }
    }

    func endTriggerKeyCapture() {
        if let captureGlobalMonitor { NSEvent.removeMonitor(captureGlobalMonitor) }
        if let captureLocalMonitor { NSEvent.removeMonitor(captureLocalMonitor) }
        captureGlobalMonitor = nil
        captureLocalMonitor = nil
        Self.isTriggerKeyCaptureActive = false
        triggerKeyCaptureReject = nil
        HotkeyFileLog.shared.log("translate-key capture ended")
    }

    private func handleTriggerKeyCapture(_ event: NSEvent) {
        guard Self.isTriggerKeyCaptureActive else { return }
        guard !event.isARepeat else { return }
        let code = event.keyCode

        // Esc 取消
        if code == UInt16(kVK_Escape) {
            endTriggerKeyCapture()
            onTriggerKeyCaptureCancelled?()
            return
        }
        // 修饰键单独按下走 flagsChanged，keyDown 阶段不会到这里；这里只挡"带修饰键的组合"
        let hasModifier = !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if hasModifier {
            triggerKeyCaptureReject?("触发键不支持带修饰键，请直接按一个字母、数字或空格")
            return
        }
        guard Self.isAllowedTranslateKey(code) else {
            let name = Shortcut.keyName(code)
            triggerKeyCaptureReject?("「\(name)」会改变输入状态，请改用字母、数字或标点")
            return
        }
        if let clash = [clickShortcut, holdShortcut].first(where: { translateKeyConflicts(with: $0, candidate: code) }) {
            triggerKeyCaptureReject?("「\(clash.displayText)」已被语音快捷键占用，请换一个键")
            return
        }

        HotkeyFileLog.shared.log("translate-key captured: \(code)")
        endTriggerKeyCapture()
        onTriggerKeyCaptureComplete?(code)
    }

    /// 触发键录制完成回调（由设置页注入；单独存放以避免与 begin 系统参数耦合）
    var onTriggerKeyCaptureComplete: ((UInt16) -> Void)?
    var onTriggerKeyCaptureCancelled: (() -> Void)?

    private func finishSystemCapture(with event: NSEvent) {
        guard isCaptureMode else { return }
        // 先取出回调再 endSystemCapture（后者会清空回调句柄）
        let cancelHandler = captureCancelHandler
        let completion = captureCompletion

        // ── flagsChanged：支持录制纯修饰键热键（如只按 ⌘⌥）──
        if event.type == .flagsChanged {
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(Shortcut.realModifierKeys)
            if mods.isEmpty {
                // 所有修饰键已松开：若期间按过修饰键且没被普通按键打断，则完成录制
                if !capturePendingModifiers.isEmpty {
                    let mods2 = capturePendingModifiers
                    let code = captureFirstModifierKeyCode
                    logger.notice("capture completed (modifier-only)")
                    HotkeyFileLog.shared.log("capture completed modifiers=\(mods2.rawValue) (modifier-only)")
                    endSystemCapture()
                    completion?(code, mods2)
                }
                return
            }
            // 记录第一个按下修饰键的 keyCode 作为热键的 key 标识
            if capturePendingModifiers.isEmpty {
                captureFirstModifierKeyCode = event.keyCode
            }
            capturePendingModifiers = mods
            return
        }

        // 普通 keyDown 会打断正在进行的修饰键手势
        capturePendingModifiers = []
        captureFirstModifierKeyCode = 0

        // Esc 取消录制
        if event.keyCode == UInt16(kVK_Escape) {
            logger.notice("capture cancelled by Esc")
            HotkeyFileLog.shared.log("capture cancelled by Esc")
            endSystemCapture()
            cancelHandler?()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 单键或组合键均可作为快捷键（Esc 已在上面处理为取消）
        guard !event.isARepeat else {
            logger.notice("capture ignored keyDown keyCode=\(event.keyCode, privacy: .public) (auto-repeat)")
            return
        }

        logger.notice("capture completed keyCode=\(event.keyCode, privacy: .public)")
        HotkeyFileLog.shared.log("capture completed keyCode=\(event.keyCode) modifiers=\(modifiers.rawValue)")
        endSystemCapture()
        completion?(event.keyCode, modifiers)
    }

    private func endSystemCapture() {
        if let captureGlobalMonitor {
            NSEvent.removeMonitor(captureGlobalMonitor)
        }
        if let captureLocalMonitor {
            NSEvent.removeMonitor(captureLocalMonitor)
        }
        captureGlobalMonitor = nil
        captureLocalMonitor = nil
        captureCompletion = nil
        captureCancelHandler = nil
        isCaptureMode = false
        Self.isShortcutCaptureActive = false
        HotkeyFileLog.shared.log("capture ended, restoring listeners")

        // 兜底：确保常驻快捷键监听仍在运行
        start()
        // 录制期间注销了 Carbon 热键，这里无条件恢复注册
        registerCarbonHotKey()
    }

    private var pasteboardBaseline = UUID()

    /// 开始录音时目标应用是否有选中文本（驱动 HUD 的"将替换选中的内容"提示）
    private(set) var willReplaceSelection = false

    /// 获取当前焦点应用的焦点 UI 元素。优先走调用方传入的前台应用 PID（主线程读取，
    /// 后台线程读 NSWorkspace.frontmostApplication 不可靠），失败再退回 systemWide。
    /// AX 查询带 0.3s 消息超时，即使应用无响应也不会长时间阻塞。
    nonisolated static func focusedAXElement(frontmostPID: pid_t? = nil) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        if let frontmostPID {
            let appElement = AXUIElementCreateApplication(frontmostPID)
            AXUIElementSetMessagingTimeout(appElement, 0.3)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let element = focused {
                return element as! AXUIElement
            }
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return element as! AXUIElement
    }

    /// 通过辅助功能 API 检测焦点元素是否有非空选区。纯 AX 查询，可在后台线程执行。
    nonisolated static func detectSelectedText(frontmostPID: pid_t? = nil) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // 优先读选中文本本身
        if focusedSelectedText(frontmostPID: frontmostPID) != nil { return true }
        // 部分应用不暴露 SelectedText，退而检查选中范围长度
        guard let axElement = focusedAXElement(frontmostPID: frontmostPID) else { return false }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let axValue = value,
           CFGetTypeID(axValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(axValue as! AXValue, .cfRange, &range) {
                return range.length > 0
            }
        }
        return false
    }

    /// 读取焦点元素的选中文本（无选中文本 / 无辅助功能权限时返回 nil）。非主线程安全。
    nonisolated static func focusedSelectedText(frontmostPID: pid_t? = nil) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let axElement = focusedAXElement(frontmostPID: frontmostPID) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 读取焦点元素（文本框 / 文本区）的全部内容。终端、游戏、PDF 阅读器等
    /// 不暴露 kAXValue，返回 nil——此时翻译功能直接放弃，不发请求。
    nonisolated static func focusedElementText(frontmostPID: pid_t? = nil) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let axElement = focusedAXElement(frontmostPID: frontmostPID) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 句子终止标点（句号/问号/叹号/省略号）：替换场景中句尾标点跟随原选中文本
    private static func isSentenceTerminator(_ c: Character) -> Bool {
        "。！？!?…".contains(c)
    }

    /// 同一物理按键可能被 global + local 两个 monitor 重复投递。按 (类型+键码+修饰+时间戳) 去重，
    /// 避免 toggle 模式下一次按下被处理两次（先 start 再 stop）。PERF-4。
    private var lastHandledEventKey: String?
    private var lastHandledEventTime: TimeInterval = 0

    private func shouldHandleEvent(_ event: NSEvent) -> Bool {
        let key = "\(event.type.rawValue):\(event.keyCode):\(event.modifierFlags.rawValue):\(event.timestamp)"
        let now = ProcessInfo.processInfo.systemUptime
        if key == lastHandledEventKey, now - lastHandledEventTime < 0.05 {
            return false
        }
        lastHandledEventKey = key
        lastHandledEventTime = now
        return true
    }

    func start() {
        guard globalMonitor == nil else { return }
        registerCarbonHotKey()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.noteKeyEventReachability(event)
                guard self.shouldHandleEvent(event) else { return }
                self.handleKeyEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // 重复投递：原样放行，不吞事件，交给（或已由）另一个 monitor 处理
            if !self.shouldHandleEvent(event) { return event }
            if self.handleKeyEvent(event) { return nil }
            return event
        }
    }

    /// 一次性探针：确认全局键盘监听是否真的收到了事件。
    /// NSEvent 的全局键盘 monitor 在**没有辅助功能权限时静默不投递**（不报错、不崩溃），
    /// 表现为"所有依赖 keyDown 的功能都没反应"，极难排查。这里启动后第一次收到
    /// keyDown 就打一条，把"权限缺失"和"代码逻辑错"两种情况区分开。
    private var hasLoggedKeyEventProbe = false

    private func noteKeyEventReachability(_ event: NSEvent) {
        guard !hasLoggedKeyEventProbe, event.type == .keyDown else { return }
        hasLoggedKeyEventProbe = true
        let ax = AXIsProcessTrusted()
        HotkeyFileLog.shared.log("monitor: first keyDown observed, axTrusted=\(ax), translateEnabled=\(SpeechManager.shared.translateEnabled), translateKey=\(Shortcut.keyName(translateKey))")
        if !ax {
            HotkeyFileLog.shared.log("monitor: WARNING — 无辅助功能权限，全局键盘事件不会投递，语音快捷键与连击翻译均失效")
        }
    }

    private func registerCarbonHotKey() {
        unregisterCarbonHotKey()

        // 同时监听按下与释放：长按说话在 Carbon 路径下也需要 keyUp 才能停止录音
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event else { return noErr }
                var keyCode = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &keyCode
                )
                guard result == noErr, keyCode.signature == OSType(0x5653484B) else { return noErr } // VHK

                // id=1 → 单击触发；id=2 → 长按触发
                let kind: TriggerKind = keyCode.id == 2 ? .hold : .click
                let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                Task { @MainActor in
                    if isRelease {
                        await HotkeyInputManager.shared.handleHotKeyRelease(kind: kind)
                    } else {
                        await HotkeyInputManager.shared.handleTrigger(kind: kind)
                    }
                }
                return noErr
            },
            2,
            &eventSpecs,
            nil,
            &hotKeyHandler
        )
        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status, privacy: .public)")
            return
        }

        registerOneCarbonHotKey(id: 1, shortcut: clickShortcut, label: "click")
        registerOneCarbonHotKey(id: 2, shortcut: holdShortcut, label: "hold")
    }

    /// 注册单个 Carbon 热键。纯修饰键热键无法走 Carbon（会拦截修饰键本身），交给 NSEvent 的 flagsChanged 监听。
    private func registerOneCarbonHotKey(id: UInt32, shortcut: Shortcut, label: String) {
        guard !shortcut.isModifierOnly else {
            HotkeyFileLog.shared.log("skip carbon register (modifier-only: \(shortcut.displayText))")
            return
        }

        var carbonModifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers,
            EventHotKeyID(signature: OSType(0x5653484B), id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if registerStatus == noErr {
            hotKeyRefs[id] = ref
            lastRegistrationError = nil
            logger.debug("hotkey registered (\(label)): \(shortcut.displayText, privacy: .public)")
            HotkeyFileLog.shared.log("hotkey registered ok (\(label)): \(shortcut.displayText)")
        } else {
            // 组合键被系统或其他应用占用时会注册失败——必须暴露给用户而不是静默吞掉
            lastRegistrationError = "「\(shortcut.displayText)」注册失败，可能已被系统或其他应用占用，请换一个组合键"
            logger.error("RegisterEventHotKey failed (\(registerStatus, privacy: .public)) for \(shortcut.displayText, privacy: .public)")
            HotkeyFileLog.shared.log("hotkey register FAILED (\(label)) status=\(registerStatus) for \(shortcut.displayText)")
        }
    }

    private func unregisterCarbonHotKey() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    fileprivate func handleTrigger(kind: TriggerKind) async {
        logger.notice("hotkey pressed (captureMode=\(self.isCaptureMode, privacy: .public), kind=\(kind.rawValue))")
        HotkeyFileLog.shared.log("hotkey pressed (captureMode=\(self.isCaptureMode), kind=\(kind.rawValue))")
        guard !isCaptureMode else { return }
        switch kind {
        case .click:
            if isActive { stop() } else { startRecording() }
        case .hold:
            press(.hold)
        }
    }

    /// Carbon 路径的 keyUp：长按触发在 Carbon 路径下也需要 keyUp 才能停止录音
    fileprivate func handleHotKeyRelease(kind: TriggerKind) async {
        logger.notice("hotkey released (active=\(self.isActive, privacy: .public), kind=\(kind.rawValue))")
        HotkeyFileLog.shared.log("hotkey released (active=\(self.isActive), kind=\(kind.rawValue))")
        guard !isCaptureMode else { return }
        if kind == .hold { release(.hold) }
    }

    // MARK: - 触发分派（单击切换 / 长按说话）

    private func press(_ kind: TriggerKind) {
        switch kind {
        case .click:
            if isActive { stop() } else { startRecording() }
        case .hold:
            guard !isShortcutHeld else { return }
            isShortcutHeld = true
            longPressTask?.cancel()
            longPressTask = Task { [weak self] in
                let threshold = self?.holdThreshold ?? Self.defaultHoldThreshold
                try? await Task.sleep(for: .milliseconds(Int(threshold * 1000)))
                guard let self, !Task.isCancelled, self.isShortcutHeld, !self.isActive else { return }
                guard SpeechManager.shared.canStartRecording else {
                    self.onStateChange?(SpeechManager.shared.lastPermissionError)
                    self.isShortcutHeld = false
                    return
                }
                self.startRecording()
                self.isHoldActive = true
            }
        }
    }

    private func release(_ kind: TriggerKind) {
        switch kind {
        case .click:
            break
        case .hold:
            if isActive, isHoldActive { stop() }
            longPressTask?.cancel()
            longPressTask = nil
            isShortcutHeld = false
            isHoldActive = false
        }
    }

    var displayShortcut: String { clickShortcut.displayText }

    /// 纯修饰键手势是否已完整按下（单击 / 长按各自记录状态）
    private var clickModifierArmed = false
    private var holdModifierArmed = false

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !Self.isShortcutCaptureActive else { return false }

        // ── 录音中按 Esc：取消本次语音输入（两种模式均生效）──
        if isActive, event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
            cancelRecording()
            return true
        }

        // ── 纯修饰键热键：监听 flagsChanged，组合完整按下时触发、全部松开时结束 ──
        if event.type == .flagsChanged {
            handleModifierGesture(event, shortcut: clickShortcut, armed: &clickModifierArmed, kind: .click)
            handleModifierGesture(event, shortcut: holdShortcut, armed: &holdModifierArmed, kind: .hold)
            return false // 不吞掉修饰键事件，避免影响正常输入
        }

        guard !event.isARepeat else { return false }

        if clickShortcut.matches(event) {
            if event.type == .keyDown { press(.click) }
            return true
        }
        if holdShortcut.matches(event) {
            if event.type == .keyDown { press(.hold) }
            else if event.type == .keyUp { release(.hold) }
            return true
        }

        // ── 连击翻译：只观察不吞事件（方案 B）──
        // 放在快捷键判定之后：撞键时按键已被 Carbon/NSEvent 路径处理，这里不再参与。
        if event.type == .keyDown {
            observeTapForTranslate(event)
        }
        return false
    }

    // MARK: - 连击翻译：计数与触发

    /// 连击计数状态。选中文本在第 1 次按下时记下——此时用户还没开始敲，
    /// 记下的是"翻译前的干净状态"。但方案 B 不吞按键，第 1 次空格就会覆盖掉选区，
    /// 所以触发时读到的往往已是残缺状态，真正可信的是这份快照。
    /// 内部计数器叫 translateTapStreak，与设置项 translateTapCount 区分开。
    private var translateTapStreak = 0
    private var translateLastTapTime: TimeInterval = 0
    private var translateAnchorText: String?
    private var isTranslating = false

    private func resetTranslateTaps() {
        translateTapStreak = 0
        translateLastTapTime = 0
        translateAnchorText = nil
    }

    /// 处理一次 keyDown：命中触发键则累加计数，任何其他键都会清零。
    /// 清零规则是防误触的关键——触发键改成字母后，"apple" 里的 p 因夹了别的键不会累计。
    private func observeTapForTranslate(_ event: NSEvent) {
        // 任何早退都要留痕：连击翻译"没反应"时，这是唯一能定位到具体哪道门卡住的地方
        if !SpeechManager.shared.translateEnabled {
            HotkeyFileLog.shared.log("translate: ignored (feature disabled)")
            return
        }
        if isActive {
            HotkeyFileLog.shared.log("translate: ignored (recording in progress)")
            return
        }
        if isCaptureMode || Self.isShortcutCaptureActive || Self.isTriggerKeyCaptureActive {
            HotkeyFileLog.shared.log("translate: ignored (shortkey capture in progress)")
            return
        }
        if isTranslating {
            HotkeyFileLog.shared.log("translate: ignored (already translating)")
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let isTriggerKey = event.keyCode == translateKey
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty

        guard isTriggerKey else {
            if translateTapStreak > 0 {
                HotkeyFileLog.shared.log("translate: streak reset by other key \(event.keyCode)")
                resetTranslateTaps()
            }
            return
        }

        // 超时则从 1 重新数起（不是继续累加，避免"1 + 超时 + 1"被算成两次）
        if now - translateLastTapTime > translateInterval {
            translateTapStreak = 0
            translateAnchorText = nil
        }
        translateLastTapTime = now
        translateTapStreak += 1

        if translateTapStreak == 1 {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            translateAnchorText = Self.focusedSelectedText(frontmostPID: pid)
            HotkeyFileLog.shared.log("translate: tap 1/\(translateTapCount) anchorChars=\(translateAnchorText?.count ?? 0)")
        } else {
            HotkeyFileLog.shared.log("translate: tap \(translateTapStreak)/\(translateTapCount)")
        }

        guard translateTapStreak >= translateTapCount else { return }
        let anchorText = translateAnchorText
        let typedCount = translateTapStreak
        resetTranslateTaps()
        Task { [weak self] in
            await self?.performTranslate(anchorText: anchorText, typedCount: typedCount)
        }
    }

    /// 真正的执行体：读原文 → 调 API → 写回。
    ///
    /// 写回为什么是"退格 + 粘贴"而不是"恢复选区 + 粘贴"：方案 B 不吞按键，
    /// **第 1 次空格就已经把原选区覆盖掉了**（macOS 文本视图中打字会替换选区），
    /// 此刻记下来的 range 早已失效，硬写回去反而会错位。
    /// 可靠做法是利用"敲出来的字符就在光标前"这一事实：
    /// - 触发前有选区 → 原文取第 1 次按下时的文本快照；退格清掉 N 个空格后粘贴，光标自然回到原位
    /// - 触发前无选区 → 原文是整个输入框（末尾的 N 个空格会被 trim 掉）；⌘A 全选后粘贴
    /// 两种情况都只依赖光标位置，不需要 AX 写选区（很多 App 根本不支持写 range）。
    private func performTranslate(anchorText: String?, typedCount: Int) async {
        guard !isTranslating else { return }
        guard AXIsProcessTrusted() else {
            onStateChange?(.permissionDenied(message: "需要在辅助功能中授权 SoundIn"))
            return
        }
        isTranslating = true
        defer { isTranslating = false }

        // AX 查询在主线程执行（带 0.3s 超时），后台线程读不可靠
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hadSelection = anchorText?.isEmpty == false
        let source: String
        if hadSelection {
            source = anchorText ?? ""
        } else if let full = Self.focusedElementText(frontmostPID: pid) {
            source = full
        } else {
            HotkeyFileLog.shared.log("translate: no readable text — abort")
            onStateChange?(.failure(message: "未识别到可翻译内容"))
            return
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 没什么可翻的：把刚敲的空格退掉，别留残渣
            HotkeyFileLog.shared.log("translate: empty source — rollback \(typedCount) chars")
            deleteTypedCharacters(typedCount)
            return
        }

        onStateChange?(.translating)
        let target = SpeechManager.shared.translateTarget
        guard let translated = await SpeechManager.shared.translate(trimmed, to: target) else {
            HotkeyFileLog.shared.log("translate: failed — rolling back \(typedCount) typed chars")
            deleteTypedCharacters(typedCount)
            onStateChange?(.failure(message: "翻译失败"))
            return
        }

        if hadSelection {
            // 退格清掉敲出来的空格，光标回到原选区起点，再粘贴译文。
            // CGEvent.post 是异步投递的，目标应用还没消化完退格就粘贴会错位，等一下。
            deleteTypedCharacters(typedCount)
            try? await Task.sleep(for: .milliseconds(120))
        } else {
            sendSelectAllShortcut()
            try? await Task.sleep(for: .milliseconds(60))
        }
        onStateChange?(.idle)
        let inserted = await paste(translated)
        HotkeyFileLog.shared.log("translate: pasted len=\(translated.count) mode=\(hadSelection ? "selection" : "all") ok=\(inserted)")
        if !inserted {
            onStateChange?(.clipboardFallback)
        }
    }

    /// 翻译失败时删掉刚才敲出来的字符。发 N 次退格。
    private func deleteTypedCharacters(_ count: Int) {
        guard count > 0 else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else { return }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func sendSelectAllShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// 纯修饰键热键的按下/松开判定（单击 = 松开时切换；长按 = 按下即开始、松开即停）
    private func handleModifierGesture(_ event: NSEvent, shortcut: Shortcut, armed: inout Bool, kind: TriggerKind) {
        guard shortcut.isModifierOnly else { armed = false; return }
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Shortcut.realModifierKeys)
        if mods.isEmpty {
            if armed {
                if kind == .click {
                    if isActive { stop() } else { startRecording() }
                } else {
                    release(.hold)
                }
            }
            armed = false
        } else if mods == shortcut.modifiers.intersection(.deviceIndependentFlagsMask) {
            if !armed {
                armed = true
                HotkeyFileLog.shared.log("hotkey (modifier-only) armed (\(kind.rawValue))")
                if kind == .hold { press(.hold) }
                // 单击：等松开时再切换（上面的 mods.isEmpty 分支处理）
            }
        } else {
            armed = false
        }
    }

    private static func loadClickShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "voiceInputClickShortcut"),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return defaultShortcut
        }
        return s
    }
    private func saveClickShortcut() {
        if let data = try? JSONEncoder().encode(clickShortcut) {
            UserDefaults.standard.set(data, forKey: "voiceInputClickShortcut")
        }
    }
    private static func loadHoldShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "voiceInputHoldShortcut"),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return defaultShortcut
        }
        return s
    }
    private func saveHoldShortcut() {
        if let data = try? JSONEncoder().encode(holdShortcut) {
            UserDefaults.standard.set(data, forKey: "voiceInputHoldShortcut")
        }
    }

    /// 判定转写结果是否"无实际内容"：空、纯标点、或纯语气词——
    /// 语音转写模型对静音音频的典型幻觉输出（如"嗯。"）。命中时视为没说话，
    /// 跳过粘贴与统计，避免静音松手往文档里塞语气词。
    static func isEffectivelyEmpty(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // 去掉空白与标点后剩余的核心字（如"嗯。"→"嗯"）
        let core = trimmed.filter { !$0.isWhitespace && !$0.isNewline && !$0.isPunctuation }
        if core.isEmpty { return true }
        let normalized = core.lowercased()
        let fillers: Set<String> = [
            "嗯", "啊", "呃", "哦", "诶", "哎", "唔", "嗯嗯", "啊啊",
            "em", "um", "hmm", "hm", "en", "oh"
        ]
        return fillers.contains(normalized)
    }

    private func startRecording() {
        guard !isFinishing else { return }
        // 权限不满足时明确上报，不再静默返回（此前热键按下后"没反应"的根源之一）
        if let reason = SpeechManager.shared.permissionBlockedReason {
            HotkeyFileLog.shared.log("rec: blocked — \(reason)")
            onStateChange?(.permissionDenied(message: reason))
            return
        }

        let newSessionID = UUID()
        sessionID = newSessionID
        pasteboardBaseline = UUID()
        isActive = true
        // 检测目标应用选区：有选中 → HUD 提示"将替换选中的内容"，松手 ⌘V 原生覆盖。
        // AX 查询放主线程 Task 执行（带 0.3s 超时），不阻塞热键响应路径，也不受后台
        // 线程 AX 亲和问题影响。
        Task { @MainActor [weak self] in
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let hasSelection = Self.detectSelectedText(frontmostPID: pid)
            guard let self, self.sessionID == newSessionID else { return }
            self.willReplaceSelection = hasSelection
            VoiceInputHUDManager.shared.willReplaceSelection = hasSelection
        }
        SpeechManager.shared.useSegmentedAPIRecording =
            SpeechManager.shared.recognitionProvider == .api
        // 权限申请是异步的：拒绝结果经此回调上报（同步检查早已结束）
        SpeechManager.shared.permissionOutcomeHandler = { [weak self] phase in
            guard let self, self.sessionID == newSessionID else { return }
            self.isActive = false
            self.sessionID = nil
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.onStateChange?(phase)
        }
        SpeechManager.shared.startRecordingSafe()
        onStateChange?(.recording)

        if SpeechManager.shared.isAwaitingPermission {
            // 权限弹窗进行中：不是启动失败。保持 isActive/sessionID，
            // 授权后回调会重新 startRecordingSafe 继续本次会话；拒绝则由 handler 上报。
            HotkeyFileLog.shared.log("rec: awaiting permission prompt — session kept alive")
        } else if let permissionMessage = SpeechManager.shared.errorMessage {
            isActive = false
            sessionID = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            onStateChange?(.permissionDenied(message: permissionMessage))
        } else if !SpeechManager.shared.isRecording {
            isActive = false
            sessionID = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            onStateChange?(.failure(message: "录音启动失败"))
        }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, !Task.isCancelled, self.sessionID == newSessionID else { return }
            self.stop()
        }
    }

    /// 录音中取消：丢弃录音，不转写、不粘贴、不计入统计
    private func cancelRecording() {
        guard isActive, let currentSessionID = sessionID else { return }
        HotkeyFileLog.shared.log("rec: cancelled by Esc (session=\(currentSessionID.uuidString))")
        isActive = false
        isShortcutHeld = false
        isHoldActive = false
        isFinishing = false
        timeoutTask?.cancel()
        timeoutTask = nil
        longPressTask?.cancel()
        longPressTask = nil
        sessionID = nil
        SpeechManager.shared.cancelSession()
        onStateChange?(.cancelled)
    }

    private func stop() {
        guard isActive, let currentSessionID = sessionID else { return }

        isActive = false
        isShortcutHeld = false
        isHoldActive = false
        isFinishing = true
        timeoutTask?.cancel()
        timeoutTask = nil
        onStateChange?(.transcribing)

        Task { [weak self] in
            defer {
                if self?.sessionID == currentSessionID {
                    self?.isFinishing = false
                    self?.sessionID = nil
                }
            }
            self?.longPressTask?.cancel()
            self?.longPressTask = nil
            self?.isShortcutHeld = false

            let text = await SpeechManager.shared.stopRecordingAndWaitForText()
            SpeechManager.shared.logTranscriptionResult(text)
            SpeechManager.shared.resetSession()
            var trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.isEffectivelyEmpty(trimmedText) else {
                HotkeyFileLog.shared.log("rec: filtered empty-ish result (\(text.count) chars) — skipped paste")
                self?.onStateChange?(.idle)
                return
            }

            // 文字优化（LLM 润色）：失败时 polishTranscription 内部自动回退原始转写
            if SpeechManager.shared.polishEnabled {
                trimmedText = await SpeechManager.shared.polishTranscription(trimmedText)
            }

            // 替换选中文本场景：句尾标点跟随原选中文本。
            // 识别/润色模型常在句尾自动补"。"；替换时若原句以终止标点（。！？…）结尾，
            // 新内容也以同样的标点结尾（保持句子结构）；原句无终止标点则去掉模型自动
            // 加的句号。AX 查询在主线程执行（带 0.3s 超时），后台线程读取不可靠。
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let selectedText = Self.focusedSelectedText(frontmostPID: frontmostPID)
            if let selectedText, !selectedText.isEmpty {
                if let last = selectedText.last, Self.isSentenceTerminator(last) {
                    // 原句以终止标点结尾：新内容去掉末尾标点后补同样的标点
                    var base = trimmedText
                    while let b = base.last, Self.isSentenceTerminator(b) {
                        base = String(base.dropLast())
                    }
                    trimmedText = base + String(last)
                    HotkeyFileLog.shared.log("paste: selectedEnds=\(last) matched punctuation")
                } else {
                    // 原句无终止标点：去掉模型自动加的句号
                    if trimmedText.hasSuffix("。") || trimmedText.hasSuffix(".") {
                        trimmedText = String(trimmedText.dropLast())
                        HotkeyFileLog.shared.log("paste: selected has no terminator — stripped trailing period")
                    }
                }
            } else {
                HotkeyFileLog.shared.log("paste: no AX selection readable — punctuation kept as-is")
            }

            // 可选：去掉句末最后一个终止标点（设置项，默认关闭）。放在所有标点跟随逻辑之后，
            // 确保无论是否替换选中文本，开启后最终输入都不会以标点收尾。
            if self?.stripTrailingPunctuation == true,
               let last = trimmedText.last,
               Self.isSentenceTerminator(last) {
                trimmedText = String(trimmedText.dropLast())
                HotkeyFileLog.shared.log("paste: trailing punctuation stripped (setting on)")
            }

            // 辅助功能权限是模拟 ⌘V 粘贴的前提；缺失时提前给出指引而不是先展示成功
            let axTrusted = AXIsProcessTrusted()
            HotkeyFileLog.shared.log("paste: ready length=\(trimmedText.count) axTrusted=\(axTrusted)")
            guard axTrusted else {
                self?.onStateChange?(.permissionDenied(message: "需要在辅助功能中授权 SoundIn"))
                return
            }

            // 方案 C（静默成功）：不演收缩对勾动画，转写完成立即粘贴；
            // 胶囊随 .idle 同步淡出，"内容出现、气泡消散"即是确认。失败/兜底才显式提示。
            self?.onStateChange?(.idle)

            let inserted = await self?.paste(trimmedText) ?? false
            HotkeyFileLog.shared.log("paste: result inserted=\(inserted)")
            // 听写统计：成功插入或剪贴板兜底均计入（取消的录音不会走到这里）
            DictationStats.shared.record(trimmedText)
            InputHistory.shared.record(trimmedText)
            if !inserted {
                self?.onStateChange?(.clipboardFallback)
            }
        }
    }

    private func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            let contents = item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) { result[type] = data }
            }
            return contents.isEmpty ? nil : contents
        } ?? []

        let currentBaseline = pasteboardBaseline
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard sendPasteShortcut() else { return false }
        // 不再固定 sleep 320ms：等待目标应用消费剪贴板，慢应用也能等到粘贴完成再恢复剪贴板
        await waitForPasteEffect(expectedText: text)

        restorePasteboard(previousItems: previousItems, baseline: currentBaseline)
        return true
    }

    /// 等待目标应用完成粘贴。
    /// 能检测时（AX 可用且应用暴露选中文本）轮询选中文本包含转写内容即提前返回，
    /// 慢应用最多等到 1.5s；无法检测时（无 AX 权限 / 应用不暴露选中文本，如光标处插入）
    /// 320ms 兜底，时序与旧实现一致，不引入额外延迟。
    private func waitForPasteEffect(expectedText: String) async {
        guard AXIsProcessTrusted() else {
            try? await Task.sleep(for: .milliseconds(320))
            return
        }
        let fallbackDeadline = Date().addingTimeInterval(0.32)
        let hardDeadline = Date().addingTimeInterval(1.5)
        var sawSelection = false
        while Date() < hardDeadline {
            try? await Task.sleep(for: .milliseconds(80))
            let selected = Self.focusedSelectedText()
            if let selected, !selected.isEmpty {
                sawSelection = true
                if selected.contains(expectedText) || expectedText.contains(selected) {
                    return // 粘贴内容已进入目标应用
                }
            } else if Date() >= fallbackDeadline, !sawSelection {
                return // 应用不暴露选中文本，按旧时序兜底
            }
        }
    }

    private func restorePasteboard(previousItems: [[NSPasteboard.PasteboardType: Data]], baseline: UUID) {
        guard baseline == pasteboardBaseline else { return }
        NSPasteboard.general.clearContents()
        if previousItems.isEmpty {
            NSPasteboard.general.setString("", forType: .string)
        } else {
            for contents in previousItems {
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: type)
                }
                NSPasteboard.general.writeObjects([item])
            }
        }
    }

    private func sendPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
