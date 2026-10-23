import AppKit
import SwiftUI
import Vision

// MARK: - 截图 OCR
// 选区工具栏「文字识别」对选区图片跑本地 Vision 识别（离线、免费、中英日），
// 结果显示在可复制的结果浮窗里；浮窗的 failure 态也承载保存失败等轻量错误提示。
// 面板非激活（不抢目标应用焦点）、可点击；外壳与显隐机制照抄 TranslatePopup：
// 关闭手段：自动淡出（识别中不计时 / 短结果 15s，交互后保留 / 长文手动关闭）/ 关闭按钮 / Esc / 点击面板外任意处。
// Esc 与点击外部用事件监听实现，只在面板可见期间安装、关闭即拆除，且只观察
// 不吞事件——录音中的 Esc 优先取消录音（Carbon 热键接管的按键不进事件流，
// 面板监听天然收不到），面板不与之抢。
// 识别在 Task.detached 里同步执行 Vision（perform 回调线程 = 调用线程），
// 主线程只做 UI；Vision 不响应 Task 取消，过期结果靠代际计数丢弃。

/// CGImage 非 Sendable；此处不变量是「构造后不可变、仅后台只读消费」——
/// 装箱豁免严格并发检查，免去主线程 PNG 编码 + 后台解码的无谓往返
struct SendableCGImage: @unchecked Sendable {
    let cgImage: CGImage
}

enum ScreenshotOCR {
    /// 识别语言从听写的识别语言设置映射。截图里中英混排是常态，永远带 en-US 兜底；
    /// 用户显式选 English 则尊重、不带中文。
    @MainActor
    static var recognitionLanguages: [String] {
        switch SpeechManager.shared.recognitionLanguage {
        case .followSystem, .zhCN: ["zh-Hans", "en-US"]
        case .enUS: ["en-US"]
        case .jaJP: ["ja-JP", "zh-Hans", "en-US"]
        }
    }

    /// 同步 Vision 识别，重活全部在 detached 任务内：图片进 String 出，
    /// Request/Handler 都在闭包内创建与消费，无非 Sendable 跨隔离。
    static func recognizeText(in image: SendableCGImage, languages: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            try handler.perform([request])
            return request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
        }.value
    }
}

@MainActor
final class ScreenshotOCRPanel {
    static let shared = ScreenshotOCRPanel()
    /// 截图完成提示独立显示，避免后台保存完成时覆盖正在阅读的 OCR 结果。
    static let feedback = ScreenshotOCRPanel()
    private init() {}

    /// 三态：recognizing（loading）/ result（文字）/ failure（空结果、编码失败等兜底）。
    /// fileprivate：同文件的 ScreenshotOCRPanelView 要按它渲染
    fileprivate enum Mode {
        case recognizing            // 三点 loading
        case result(String)         // 可划选文字 + 复制 + 关闭
        case failure(String)
        case notice(String, savedURL: URL?)
    }

    private var mode: Mode = .recognizing
    /// 浮窗标题：OCR 结果是「文字识别」；承载保存失败等其他错误时可改「截图」
    private var panelTitle = "文字识别"
    private var panel: NSPanel?
    /// 显示代际：present / hide 各递增，在途 OCR 结果、淡出动画与过期自动隐藏据此失效。
    /// hide() 无条件递增（在可见性早退之前），所以 gen == generation 已蕴含"面板在屏"，
    /// 不需要第二个失效标志
    private var generation = 0
    private var ocrTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?
    /// 弹面板瞬间捕获的锚点；结果浮窗用同一锚点，识别几秒后鼠标移走位置也不漂
    private var anchorPoint: NSPoint = .zero
    private var visibleFrame: NSRect = .zero
    private var hasInteracted = false
    private var contentScrolls = false

    // MARK: - 常量

    static let resultWidth: CGFloat = ResultPanelStyle.width
    static let maxHeight: CGFloat = ResultPanelStyle.maxHeight
    /// 滚动变体里正文的固定高度
    static let maxBodyHeight: CGFloat = ResultPanelStyle.bodyHeight
    /// 与翻译弹窗一致，留够读完与划选的时间
    static let resultAutoHideSeconds: TimeInterval = 15
    static let failureAutoHideSeconds: TimeInterval = 8

    // MARK: - 入口

    /// 截图工具栏「文字识别」入口：对给定图片立即开始识别，浮窗先进入 loading 态
    func present(image: SendableCGImage, near anchor: NSPoint) {
        panelTitle = "文字识别"
        show(.recognizing, near: anchor, autoHide: nil)
        HotkeyFileLog.shared.log("ocr: recognition started")
        let langs = ScreenshotOCR.recognitionLanguages
        let gen = generation
        ocrTask = Task { [weak self] in
            do {
                let text = try await ScreenshotOCR.recognizeText(in: image, languages: langs)
                guard let self, gen == self.generation else { return }
                if text.isEmpty {
                    HotkeyFileLog.shared.log("ocr: done, empty result")
                    self.transition(to: .failure("未识别到文字"), autoHide: Self.failureAutoHideSeconds)
                } else {
                    HotkeyFileLog.shared.log("ocr: done, chars=\(text.count)")
                    self.transition(to: .result(text), autoHide: Self.resultAutoHideSeconds)
                }
            } catch {
                guard let self, gen == self.generation else { return }
                HotkeyFileLog.shared.log("ocr: failed — \(error.localizedDescription)")
                self.transition(to: .failure("识别失败：\(error.localizedDescription)"), autoHide: Self.failureAutoHideSeconds)
            }
        }
    }

    /// 轻量错误浮窗（保存失败等），不进识别流程。title 用于面板头部（如「截图」承载快照失败）
    func presentFailure(_ message: String, near anchor: NSPoint, title: String = "文字识别") {
        panelTitle = title
        show(.failure(message), near: anchor, autoHide: Self.failureAutoHideSeconds)
        HotkeyFileLog.shared.log("ocr: failure shown — \(message)")
    }

    func presentSuccess(_ message: String, savedURL: URL? = nil, near anchor: NSPoint) {
        panelTitle = "截图"
        show(.notice(message, savedURL: savedURL), near: anchor, autoHide: 4)
    }

    /// 各入口共用的面板装配：重置失效状态 → 按 mode 重建内容 → 校准摆放 → 淡入 → 计时/监听
    private func show(_ mode: Mode, near anchor: NSPoint, autoHide: TimeInterval?) {
        generation += 1
        ocrTask?.cancel()
        cancelAutoHide()
        self.mode = mode
        hasInteracted = false
        self.anchorPoint = anchor
        let panel = ensurePanel()
        swapRoot(scroll: false)
        syncPanelSize()
        fadeIn(panel)
        if let autoHide { scheduleAutoHide(seconds: autoHide) }
        installDismissMonitors()
    }

    /// 识别完成后的状态切换：原地重建内容并重摆，不重播淡入
    private func transition(to mode: Mode, autoHide: TimeInterval) {
        self.mode = mode
        swapRoot(scroll: false)
        syncPanelSize()
        scheduleAutoHide(seconds: autoHide)
    }

    func hide() {
        // 无条件递增：让在途 OCR 结果、淡出完成回调、自动隐藏全部失效——
        // gen == generation 一个条件即可判定"结果仍然新鲜"，无需第二失效标志
        generation += 1
        cancelAutoHide()
        ocrTask?.cancel()
        removeDismissMonitors()
        guard let panel, panel.isVisible else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // 淡出期间又触发了新面板：别把新的 orderOut 掉
            guard gen == self.generation else { return }
            panel.orderOut(nil)
        })
    }

    /// 立即隐藏（无淡出）：截图冻结帧不能拍到淡出中的残影
    func hideImmediately() {
        generation += 1
        cancelAutoHide()
        ocrTask?.cancel()
        removeDismissMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - 自动隐藏

    private func scheduleAutoHide(seconds: TimeInterval) {
        cancelAutoHide()
        guard !hasInteracted else { return }
        var delay = seconds
        if case .result(let text) = mode {
            guard let resultDelay = ResultPanelStyle.autoHideDelay(for: text, scrolls: contentScrolls) else { return }
            delay = resultDelay
        }
        let gen = generation
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.hide()
        }
    }

    private func keepOpen() {
        hasInteracted = true
        cancelAutoHide()
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - Esc / 点击外部关闭（照抄 TranslatePopup，只观察不吞）

    private static let escapeKeyCode: UInt16 = 53  // kVK_Escape

    private func installDismissMonitors() {
        guard dismissGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        dismissGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            let captured = event
            Task { @MainActor in
                self.handleDismissEvent(captured)
            }
        }
        dismissLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            let captured = event
            Task { @MainActor in
                self.handleDismissEvent(captured)
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let dismissGlobalMonitor { NSEvent.removeMonitor(dismissGlobalMonitor) }
        if let dismissLocalMonitor { NSEvent.removeMonitor(dismissLocalMonitor) }
        dismissGlobalMonitor = nil
        dismissLocalMonitor = nil
    }

    private func handleDismissEvent(_ event: NSEvent) {
        guard panel?.isVisible == true else { return }
        if let panel, panel.frame.contains(NSEvent.mouseLocation) || event.window === panel {
            keepOpen()
        }
        switch event.type {
        case .keyDown:
            if event.keyCode == Self.escapeKeyCode, !event.isARepeat {
                hide()
            }
        case .leftMouseDown, .rightMouseDown:
            guard let panel else { return }
            // 用 mouseLocation（Cocoa 全局坐标）而非 locationInWindow：全局监听的事件坐标是另一套坐标系
            if !panel.frame.contains(NSEvent.mouseLocation) {
                hide()
            }
        default:
            break
        }
    }

    // MARK: - 摆放与尺寸

    /// 锚点（鼠标位）右下让出光标摆放；下方放不下翻上方、右侧放不下翻左方，
    /// 双轴夹进所在屏可视区 8pt 边距。result 态以同一锚点重摆，视觉连续。
    private func placeAt(anchor: NSPoint, size: NSSize) {
        let panel = ensurePanel()
        let screen = NSScreen.screens.first {
            NSMouseInRect(anchor, $0.frame, false)
        } ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? .zero

        let width = size.width
        var x = anchor.x + 14
        if x + width > visibleFrame.maxX - 8 {
            x = anchor.x - 14 - width   // 右侧放不下，翻到光标左侧
        }
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)

        var y = anchor.y - 14 - size.height   // 光标下方（Cocoa 原点在左下）
        if y < visibleFrame.minY + 8 {
            y = anchor.y + 14                   // 下方放不下，翻到光标上方
        }
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)

        panel.setFrame(NSRect(x: x, y: y, width: width, height: size.height), display: false)
    }

    /// 按当前内容实测高度校准；超过上限换滚动变体再量，最后以同一锚点重摆（自动完成翻转与夹取）
    private func syncPanelSize() {
        guard let panel else { return }
        var hosting = panel.contentView as? NSHostingView<AnyView>
        var fit = hosting?.fittingSize.height ?? 44
        contentScrolls = fit > Self.maxHeight
        if contentScrolls {
            swapRoot(scroll: true)
            hosting = panel.contentView as? NSHostingView<AnyView>
            fit = hosting?.fittingSize.height ?? Self.maxHeight
        }
        let target = min(fit, Self.maxHeight)
        placeAt(anchor: anchorPoint, size: NSSize(width: Self.resultWidth, height: target))
        panel.setFrame(panel.frame, display: true)
    }

    // MARK: - 面板与内容

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        // 要接收鼠标（识别按钮、复制、关闭），不点击穿透
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    /// 用当前 mode 重建内容视图。状态切换（识别中 → 结果/失败）与滚动变体都走这里：
    /// 内容很小，重建比依赖 Observable 原地 diff 更直接。
    private func swapRoot(scroll: Bool) {
        let panel = ensurePanel()
        let view = ScreenshotOCRPanelView(
            mode: mode,
            title: panelTitle,
            scroll: scroll,
            onCopy: { [weak self] in
                guard let self, case .result(let text) = self.mode else { return }
                self.keepOpen()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onClose: { [weak self] in self?.hide() },
            onInteraction: { [weak self] in self?.keepOpen() }
        )
        panel.contentView = NSHostingView(rootView: AnyView(view.frame(width: Self.resultWidth)))
    }

    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

// MARK: - 面板视图

private struct ScreenshotOCRPanelView: View {
    let mode: ScreenshotOCRPanel.Mode
    /// 面板头部标题：OCR 结果「文字识别」；承载快照/保存失败时可显示「截图」
    let title: String
    /// 滚动变体：正文固定高、内部滚动（超长识别结果）
    let scroll: Bool
    let onCopy: () -> Void
    let onClose: () -> Void

    let onInteraction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ResultPanelStyle.spacing) {
            header
            Divider()
            bodyContent
        }
        .onHover { if $0 { onInteraction() } }
        .padding(ResultPanelStyle.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ResultPanelStyle.cornerRadius, style: .continuous))
        // 材质在浅色底上边界模糊，补一圈极淡的描边
        .overlay(
            RoundedRectangle(cornerRadius: ResultPanelStyle.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var header: some View {
        let canCopy: Bool
        if case .result = mode { canCopy = true } else { canCopy = false }
        return ResultPanelHeader(title: title, systemImage: "text.viewfinder",
                                 onCopy: canCopy ? onCopy : nil, onClose: onClose)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if scroll {
            ScrollView(.vertical) {
                stateContent.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: ScreenshotOCRPanel.maxBodyHeight)
        } else {
            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch mode {
        case .recognizing:
            HStack(spacing: 8) {
                PopupLoadingDots()
                Text("识别中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .result(let text):
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .notice(let message, let savedURL):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                if let savedURL {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                    }
                    .buttonStyle(.link)
                }
            }
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// 三点 loading，节奏与输入框旁的 loading 指示（InputFocusLoader）同款：
/// 依次上浮、变亮，相位错开，视觉上是一条从左到右扫过的波。
/// （TranslatePopup 的同名类型是 private，为保持文件解耦在此复制一份）
private struct PopupLoadingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let bounce = 0.5 + 0.5 * sin(t * 2 * .pi / 1.05 - Double(index) * 0.55)
                    Circle()
                        .fill(Color.secondary.opacity(0.35 + 0.65 * bounce))
                        .frame(width: 6, height: 6)
                        .offset(y: -2 * bounce)
                }
            }
        }
    }
}
