import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.codespace.voicescribe", category: "hotkey")

/// 文件诊断日志：~/Library/Logs/VoiceScribe-debug.log（不受系统日志沙箱限制）
final class HotkeyFileLog: @unchecked Sendable {
    static let shared = HotkeyFileLog()
    private let queue = DispatchQueue(label: "com.codespace.voicescribe.filelog")

    private init() {
        let dir = NSString(string: "~/Library/Logs").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    func log(_ message: String) {
        let line = "\(Self.stamp()) \(message)\n"
        let path = NSString(string: "~/Library/Logs/VoiceScribe-debug.log").expandingTildeInPath
        queue.async {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
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

        private static func keyName(_ code: UInt16) -> String {
            let names: [UInt16: String] = [
                49: "Space", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
                101: "F9", 109: "F10", 103: "F11", 111: "F12",
                18: "1", 19: "2", 20: "3", 21: "4", 23: "5"
            ]
            return names[code] ?? "Key \(code)"
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isShortcutHeld = false
    private var isActive = false
    private var isFinishing = false
    private var sessionID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var longPressTask: Task<Void, Never>?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var isCaptureMode = false
    static let defaultShortcut = Shortcut(
        keyCode: 111,
        modifiersRawValue: NSEvent.ModifierFlags([.function, .command, .option])
            .intersection(.deviceIndependentFlagsMask).rawValue
    )

    var shortcut: Shortcut = loadShortcut() {
        didSet {
            saveShortcut()
            registerCarbonHotKey()
        }
    }

    enum TriggerMode: String, Codable, CaseIterable {
        case toggle
        case hold

        var displayName: String {
            switch self {
            case .toggle: "单击切换"
            case .hold: "长按说话"
            }
        }
    }

    static let defaultHoldThreshold: TimeInterval = 0.7

    var triggerMode: TriggerMode = loadTriggerMode() {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: "voiceInputTriggerMode")
        }
    }

    var holdThreshold: TimeInterval = (UserDefaults.standard.object(forKey: "voiceInputHoldThreshold") as? Double) ?? defaultHoldThreshold {
        didSet {
            UserDefaults.standard.set(holdThreshold, forKey: "voiceInputHoldThreshold")
        }
    }

    var onStateChange: ((VoiceInputPhase) -> Void)?

    static var isShortcutCaptureActive = false

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

    /// 通过辅助功能 API 检测焦点元素是否有非空选区
    static func detectSelectedText() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        let axElement = element as! AXUIElement

        // 优先读选中文本本身
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, !text.isEmpty {
            return true
        }
        // 部分应用不暴露 SelectedText，退而检查选中范围长度
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

    func start() {
        guard globalMonitor == nil else { return }
        registerCarbonHotKey()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.handleKeyEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyEvent(event) { return nil }
            return event
        }
    }

    private func registerCarbonHotKey() {
        unregisterCarbonHotKey()

        // Carbon 无法注册"纯修饰键热键"（会把修饰键本身拦截掉、破坏正常输入），
        // 纯修饰键热键完全依赖 NSEvent 的 flagsChanged 监听
        if shortcut.isModifierOnly {
            lastRegistrationError = nil
            HotkeyFileLog.shared.log("skip carbon register (modifier-only: \(self.shortcut.displayText))")
            logger.notice("skip carbon register (modifier-only)")
            return
        }

        // 同时监听按下与释放：长按说话模式在 Carbon 路径下也需要 keyUp 才能停止录音
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

                let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                Task { @MainActor in
                    if isRelease {
                        await HotkeyInputManager.shared.handleHotKeyRelease()
                    } else {
                        await HotkeyInputManager.shared.handleTrigger()
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

        var carbonModifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers,
            EventHotKeyID(signature: OSType(0x5653484B), id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if registerStatus == noErr {
            hotKeyRef = ref
            lastRegistrationError = nil
            logger.debug("hotkey registered: \(self.shortcut.displayText, privacy: .public)")
            HotkeyFileLog.shared.log("hotkey registered ok: \(self.shortcut.displayText)")
        } else {
            // 组合键被系统或其他应用占用时会注册失败——必须暴露给用户而不是静默吞掉
            lastRegistrationError = "「\(shortcut.displayText)」注册失败，可能已被系统或其他应用占用，请换一个组合键"
            hotKeyRef = nil
            logger.error("RegisterEventHotKey failed (\(registerStatus, privacy: .public)) for \(self.shortcut.displayText, privacy: .public)")
            HotkeyFileLog.shared.log("hotkey register FAILED status=\(registerStatus) for \(self.shortcut.displayText)")
        }
    }

    private func unregisterCarbonHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyRef = nil
        hotKeyHandler = nil
    }

    fileprivate func handleTrigger() async {
        logger.notice("hotkey pressed (captureMode=\(self.isCaptureMode, privacy: .public))")
        HotkeyFileLog.shared.log("hotkey pressed (captureMode=\(self.isCaptureMode))")
        guard !isCaptureMode else { return }
        if isActive { stop() } else { startRecording() }
    }

    /// Carbon 路径的 keyUp：长按说话模式下松开快捷键要停止录音
    fileprivate func handleHotKeyRelease() async {
        logger.notice("hotkey released (active=\(self.isActive, privacy: .public))")
        HotkeyFileLog.shared.log("hotkey released (active=\(self.isActive))")
        guard !isCaptureMode, triggerMode == .hold, isActive else { return }
        stop()
    }

    var displayShortcut: String { shortcut.displayText }

    /// 纯修饰键手势是否已完整按下（用于纯修饰键热键的触发判定）
    private var modifierGestureArmed = false

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard !Self.isShortcutCaptureActive else { return false }

        // ── 录音中按 Esc：取消本次语音输入（长按 / 单击模式均生效）──
        if isActive, event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
            cancelRecording()
            return true
        }

        // ── 纯修饰键热键：监听 flagsChanged，组合完整按下时触发、全部松开时结束 ──
        if shortcut.isModifierOnly {
            if event.type != .flagsChanged {
                // 按了任何普通按键都打断修饰键手势（避免 ⌘C 之类误触发）
                modifierGestureArmed = false
                return false
            }
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection(Shortcut.realModifierKeys)
            if mods.isEmpty {
                // 全部松开：单击模式=切换开关；长按模式=停止录音
                if modifierGestureArmed, isActive {
                    stop()
                }
                modifierGestureArmed = false
            } else if mods == shortcut.modifiers.intersection(.deviceIndependentFlagsMask) {
                if !modifierGestureArmed {
                    modifierGestureArmed = true
                    HotkeyFileLog.shared.log("hotkey (modifier-only) armed")
                    switch triggerMode {
                    case .toggle:
                        break // 等松开时再切换
                    case .hold:
                        startRecording()
                    }
                }
            } else {
                modifierGestureArmed = false
            }
            return false // 不吞掉修饰键事件，避免影响正常输入
        }

        guard shortcut.matches(event), !event.isARepeat else { return false }

        switch triggerMode {
        case .toggle:
            guard event.type == .keyDown else { return true }
            if isActive {
                stop()
            } else {
                startRecording()
            }

        case .hold:
            if event.type == .keyDown {
                guard !isShortcutHeld else { break }
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
                }
            } else if event.type == .keyUp {
                if isActive {
                    stop()
                } else {
                    longPressTask?.cancel()
                    longPressTask = nil
                    isShortcutHeld = false
                }
            }
        }
        return true
    }

    private static func loadTriggerMode() -> TriggerMode {
        TriggerMode(rawValue: UserDefaults.standard.string(forKey: "voiceInputTriggerMode") ?? "") ?? .toggle
    }

    private static func loadShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "voiceInputShortcut"),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return defaultShortcut
        }
        return shortcut
    }

    private func saveShortcut() {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "voiceInputShortcut")
        }
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
        // 检测目标应用选区：有选中 → HUD 提示"将替换选中的内容"，松手 ⌘V 原生覆盖
        willReplaceSelection = Self.detectSelectedText()
        VoiceInputHUDManager.shared.willReplaceSelection = willReplaceSelection
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
            guard !trimmedText.isEmpty else {
                self?.onStateChange?(.idle)
                return
            }

            // 文字优化（LLM 润色）：失败时 polishTranscription 内部自动回退原始转写
            if SpeechManager.shared.polishEnabled {
                trimmedText = await SpeechManager.shared.polishTranscription(trimmedText)
            }

            // 辅助功能权限是模拟 ⌘V 粘贴的前提；缺失时提前给出指引而不是先展示成功
            let axTrusted = AXIsProcessTrusted()
            HotkeyFileLog.shared.log("paste: ready length=\(trimmedText.count) axTrusted=\(axTrusted)")
            guard axTrusted else {
                self?.onStateChange?(.permissionDenied(message: "需要在辅助功能中授权 VoiceScribe"))
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
        try? await Task.sleep(for: .milliseconds(320))

        restorePasteboard(previousItems: previousItems, baseline: currentBaseline)
        return true
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
