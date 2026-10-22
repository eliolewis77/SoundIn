import AppKit
import SwiftUI
import Vision

// MARK: - 截图 OCR
// 框选截图完成后在鼠标附近弹出操作面板，点「文字识别」对剪贴板里的截图跑本地
// Vision 识别（离线、免费、中英日），结果显示在可复制的结果浮窗里。
// 面板非激活（不抢目标应用焦点）、可点击；外壳与显隐机制照抄 TranslatePopup：
// 关闭手段：自动淡出（action 8s / 结果 15s）/ 关闭按钮 / Esc / 点击面板外任意处。
// Esc 与点击外部用事件监听实现，只在面板可见期间安装、关闭即拆除，且只观察
// 不吞事件——录音中的 Esc 优先取消录音（Carbon 热键接管的按键不进事件流，
// 面板监听天然收不到），面板不与之抢。
// 识别在 Task.detached 里同步执行 Vision（perform 回调线程 = 调用线程），
// 主线程只做剪贴板读取与 UI；Vision 不响应 Task 取消，过期结果靠代际计数丢弃。

enum ScreenshotOCR {
    /// 读剪贴板里的图片数据（主线程调用，NSPasteboard 非线程安全）。
    /// screencapture -c 写的是 TIFF，其他来源可能是 PNG，两种都接；读不到返回 nil。
    /// 返回原始编码数据不做解码——重活（解码 + 识别）都在后台任务里。
    static func readClipboardImageData() -> Data? {
        NSPasteboard.general.data(forType: .tiff)
            ?? NSPasteboard.general.data(forType: .png)
    }

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

    /// 同步 Vision 识别，重活全部在 detached 任务内：Data 进 String 出，
    /// NSImage/CGImage/Request/Handler 都在闭包内创建与消费，无非 Sendable 跨隔离。
    static func recognizeText(in imageData: Data, languages: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: imageData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "图片解码失败"])
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
    private init() {}

    /// 四态：action（识别按钮）/ recognizing（loading）/ result（文字）/ failure（三种兜底）。
    /// fileprivate：同文件的 ScreenshotOCRPanelView 要按它渲染
    fileprivate enum Mode {
        case action                 // 「识别图中文字」按钮 + 关闭
        case recognizing            // 三点 loading
        case result(String)         // 可划选文字 + 复制 + 关闭
        case failure(String)        // 剪贴板无图 / 空结果 / Vision 报错
    }

    private var mode: Mode = .action
    private var panel: NSPanel?
    /// 显示代际：present / hide 各递增，在途 OCR 结果、淡出动画与过期自动隐藏据此失效
    private var generation = 0
    private var ocrTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?
    /// 已被用户/自动关闭。关闭后迟到的 OCR 结果不得把面板重新弹出来。
    private var isDismissed = false
    /// 弹面板瞬间捕获的鼠标位；结果浮窗用同一锚点，识别几秒后鼠标移走位置也不漂
    private var anchorPoint: NSPoint = .zero
    private var visibleFrame: NSRect = .zero

    // MARK: - 常量

    static let actionWidth: CGFloat = 170
    static let resultWidth: CGFloat = 360
    static let maxHeight: CGFloat = 420
    /// 滚动变体里正文的固定高度
    static let maxBodyHeight: CGFloat = 340
    static let actionAutoHideSeconds: TimeInterval = 8
    /// 与翻译弹窗一致，留够读完与划选的时间
    static let resultAutoHideSeconds: TimeInterval = 15
    static let failureAutoHideSeconds: TimeInterval = 5

    // MARK: - 入口

    /// 截图成功后调用：在鼠标附近弹操作面板。只记锚点不读剪贴板——
    /// screencapture 退进程与写剪贴板的时序有差异，真正读板延迟到点击识别时。
    func presentActionPanel(near mouse: NSPoint) {
        generation += 1
        ocrTask?.cancel()
        cancelAutoHide()
        isDismissed = false
        mode = .action
        anchorPoint = mouse

        let panel = ensurePanel()
        swapRoot(scroll: false)
        placeAt(anchor: mouse, size: panel.frame.size)
        syncPanelSize()
        fadeIn(panel)
        scheduleAutoHide(seconds: Self.actionAutoHideSeconds)
        installDismissMonitors()
        HotkeyFileLog.shared.log("ocr: action panel shown at \(mouse)")
    }

    func hide() {
        cancelAutoHide()
        ocrTask?.cancel()
        isDismissed = true
        removeDismissMonitors()
        guard let panel, panel.isVisible else { return }
        generation += 1
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

    // MARK: - 识别流程

    private func startRecognition() {
        cancelAutoHide()
        generation += 1
        let gen = generation
        guard let data = ScreenshotOCR.readClipboardImageData() else {
            HotkeyFileLog.shared.log("ocr: clipboard has no image")
            showFailure("剪贴板中没有图片", seconds: 3, generation: gen)
            return
        }
        HotkeyFileLog.shared.log("ocr: recognition started, imageBytes=\(data.count)")
        let langs = ScreenshotOCR.recognitionLanguages
        mode = .recognizing
        swapRoot(scroll: false)
        syncPanelSize()
        ocrTask = Task { [weak self] in
            do {
                let text = try await ScreenshotOCR.recognizeText(in: data, languages: langs)
                guard let self, gen == self.generation, !self.isDismissed else { return }
                if text.isEmpty {
                    HotkeyFileLog.shared.log("ocr: done, empty result")
                    self.showFailure("未识别到文字", seconds: Self.failureAutoHideSeconds, generation: gen)
                } else {
                    HotkeyFileLog.shared.log("ocr: done, chars=\(text.count)")
                    self.mode = .result(text)
                    self.swapRoot(scroll: false)
                    self.syncPanelSize()
                    self.scheduleAutoHide(seconds: Self.resultAutoHideSeconds)
                }
            } catch {
                guard let self, gen == self.generation, !self.isDismissed else { return }
                HotkeyFileLog.shared.log("ocr: failed — \(error.localizedDescription)")
                self.showFailure("识别失败：\(error.localizedDescription)", seconds: Self.failureAutoHideSeconds, generation: gen)
            }
        }
    }

    /// failure 是三处兜底的公共出口；带 generation 校验，过期调用直接丢弃
    private func showFailure(_ message: String, seconds: TimeInterval, generation gen: Int) {
        guard gen == generation, !isDismissed else { return }
        mode = .failure(message)
        swapRoot(scroll: false)
        syncPanelSize()
        scheduleAutoHide(seconds: seconds)
    }

    // MARK: - 自动隐藏

    private func scheduleAutoHide(seconds: TimeInterval) {
        cancelAutoHide()
        let gen = generation
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.hide()
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - Esc / 点击外部关闭（照抄 TranslatePopup，只观察不吞）

    private static let escapeKeyCode: UInt16 = 53  // kVK_Escape

    private func installDismissMonitors() {
        guard dismissGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
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
        let width = currentWidth
        var hosting = panel.contentView as? NSHostingView<AnyView>
        var fit = hosting?.fittingSize.height ?? 44
        if fit > Self.maxHeight {
            swapRoot(scroll: true)
            hosting = panel.contentView as? NSHostingView<AnyView>
            fit = hosting?.fittingSize.height ?? Self.maxHeight
        }
        let target = min(fit, Self.maxHeight)
        placeAt(anchor: anchorPoint, size: NSSize(width: width, height: target))
        panel.setFrame(panel.frame, display: true)
    }

    private var currentWidth: CGFloat {
        switch mode {
        case .action: Self.actionWidth
        default: Self.resultWidth
        }
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

    /// 用当前 mode 重建内容视图。状态切换（action → 识别中 → 结果/失败）与滚动变体都走这里：
    /// 内容很小，重建比依赖 Observable 原地 diff 更直接。
    private func swapRoot(scroll: Bool) {
        let panel = ensurePanel()
        let width = currentWidth
        let view = ScreenshotOCRPanelView(
            mode: mode,
            scroll: scroll,
            onRecognize: { [weak self] in self?.startRecognition() },
            onCopy: { [weak self] in
                guard let self, case .result(let text) = self.mode else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            onClose: { [weak self] in self?.hide() }
        )
        panel.contentView = NSHostingView(rootView: AnyView(view.frame(width: width)))
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
    /// 滚动变体：正文固定高、内部滚动（超长识别结果）
    let scroll: Bool
    let onRecognize: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Divider()
            bodyContent
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 材质在浅色底上边界模糊，补一圈极淡的描边
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            if case .action = mode {
                // action 态标题本身就是识别入口，header 只放标题文字
                Label("截图 OCR", systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Label("文字识别", systemImage: "text.viewfinder")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .result(let text) = mode {
                Button {
                    onCopy()
                    justCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        justCopied = false
                    }
                } label: {
                    Label(justCopied ? "已复制" : "复制", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
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
        case .action:
            Button {
                onRecognize()
            } label: {
                Label("识别图中文字", systemImage: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
