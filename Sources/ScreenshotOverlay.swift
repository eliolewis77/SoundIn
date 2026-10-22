import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI

// MARK: - 自建截图选区遮罩
// 触发 → screencapture -x 静默抓冻结帧 → 全屏遮罩（压暗 + 冻结帧 + 白色十字光标）
// → 拖拽选区（高亮 + 实时尺寸）→ 松手弹就地工具栏（文字识别 / 复制 / 保存到桌面）。
// 一期只做鼠标所在屏；直接替换 screencapture -i 系统 UI。
// 生命周期：idle → snapshotting → selecting → toolbar → idle。
// Swift 6：CGImage 非 Sendable，全程 MainActor 创建与消费；Process.terminationHandler
// 里只把 Sendable（exit code、路径）送进 Task { @MainActor }。
// Esc 走临时 Carbon 热键 id=5——Secure Event Input 下 NSEvent 全局监听收不到 keyDown
// （见 HotkeyInputManager 录音 Esc id=4 的同类结论），Carbon 通道不受影响。

@MainActor
final class ScreenshotOverlay {
    static let shared = ScreenshotOverlay()
    private init() {}

    enum Phase: Equatable {
        case idle, snapshotting, selecting, toolbar
    }

    private(set) var phase: Phase = .idle
    /// HotkeyInputManager.isScreenshotInFlight 读这里——phase 是唯一事实源
    var isSessionActive: Bool { phase != .idle }

    private var targetScreen: NSScreen?
    private var snapshotImage: CGImage?
    /// 冻结帧像素密度：= image.width / screen.frame.width，实测反推（不信任 backingScaleFactor）
    private var pixelScale: CGFloat = 1
    /// 选区，遮罩视图局部坐标（Cocoa 方向，原点左下）
    private var selectionRect = NSRect.zero
    private var dragStart: NSPoint?
    private var snapshotProcess: Process?
    private var watchdogTask: Task<Void, Never>?
    private var escHotKeyRef: EventHotKeyRef?
    private var overlayPanel: NSPanel?
    private var overlayView: OverlayContentView?
    private var toolbarPanel: NSPanel?

    // MARK: - 常量

    /// 快照子进程看门狗：screencapture 挂起（休眠/显示重配中）时强杀走失败分支
    static let snapshotTimeout: TimeInterval = 4
    /// 选区宽或高小于此值视为单击（取消），不进工具栏
    static let minSelectionSide: CGFloat = 4
    static let dimAlpha: CGFloat = 0.28

    // MARK: - 生命周期

    func start() {
        guard phase == .idle else {
            HotkeyFileLog.shared.log("overlay: start ignored (phase=\(phase))")
            return
        }
        phase = .snapshotting
        selectionRect = .zero
        dragStart = nil
        let mouse = NSEvent.mouseLocation
        targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let cursor = Self.crosshairCursor
        cursor.push()
        // Esc 从快照阶段就接管：挂起/显示重配等场景下子进程可能卡满看门狗时长，
        // 遮罩窗口那时还不存在，Carbon 热键是唯一可靠的取消通道
        registerEscHotKey()
        captureSnapshot()
    }

    /// Esc / 右键 / 单击 / 应用退出 的统一收口
    func cancel() {
        guard phase != .idle else { return }
        dismiss()
    }

    /// Carbon Esc 热键（id=5）派发入口
    func handleEscHotKey() {
        guard phase != .idle else { return }
        HotkeyFileLog.shared.log("overlay: esc")
        cancel()
    }

    private func dismiss() {
        // 幂等：退出路径上 terminationHandler 可能再跑一次 snapshotFailed → dismiss，
        // 二次 NSCursor.pop() 会打乱光标栈
        guard phase != .idle else { return }
        snapshotProcess?.terminate()
        snapshotProcess = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        unregisterEscHotKey()
        toolbarPanel?.orderOut(nil)
        overlayPanel?.orderOut(nil)
        NSCursor.pop()
        // 冻结帧是整屏解码位图（5K 屏 ~56MB），会话结束必须释放，不能等下次覆盖
        snapshotImage = nil
        overlayView?.clearContent()
        selectionRect = .zero
        dragStart = nil
        phase = .idle
        HotkeyFileLog.shared.log("overlay: dismissed")
    }

    // MARK: - 冻结帧快照

    private func captureSnapshot() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundin-snapshot-\(UUID().uuidString).png").path
        // -R 用 CG 全局坐标（主屏左上原点、y 向下）；换算：cgY = 主屏高 - 屏 maxY
        guard let screen = targetScreen,
              let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            snapshotFailed("找不到目标显示器")
            return
        }
        let f = screen.frame
        let cgY = Int(mainScreen.frame.height - f.maxY)
        let region = "\(Int(f.minX)),\(cgY),\(Int(f.width)),\(Int(f.height))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x 静默（无声音）；-R 指定区域且保证单文件输出（裸 -x 多屏会拆多个文件）
        process.arguments = ["-x", "-R", region, path]
        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.snapshotProcess = nil
                self?.watchdogTask?.cancel()
                guard let self else { return }
                // 临时文件无论成败都清理（含看门狗 terminate 的非零退出路径）
                defer { try? FileManager.default.removeItem(atPath: path) }
                // -x 没有用户取消路径，非 0 即真失败（挂起被看门狗 terminate 也落在这）
                guard code == 0 else {
                    self.snapshotFailed("截图快照失败（exit=\(code)）")
                    return
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    self.snapshotFailed("快照文件读取失败")
                    return
                }
                self.presentOverlay(image: image)
            }
        }
        do {
            try process.run()
        } catch {
            snapshotFailed("无法启动截图工具：\(error.localizedDescription)")
            return
        }
        snapshotProcess = process
        watchdogTask = Task { [weak process] in
            try? await Task.sleep(for: .seconds(Self.snapshotTimeout))
            guard !Task.isCancelled, let process, process.isRunning else { return }
            HotkeyFileLog.shared.log("overlay: snapshot watchdog fired, terminating")
            process.terminate()
        }
    }

    private func snapshotFailed(_ message: String) {
        // 已被 cancel 清理过（如退出路径）就不再重复弹失败浮窗
        guard phase != .idle else { return }
        HotkeyFileLog.shared.log("overlay: \(message)")
        let anchor = NSEvent.mouseLocation
        dismiss()
        // 走浮窗通道而非 HUD：HUD 受听写总开关门控，且会被本遮罩（.screenSaver）盖住；
        // 标题用「截图」与 OCR 结果浮窗区分
        ScreenshotOCRPanel.shared.presentFailure(message, near: anchor, title: "截图")
    }

    // MARK: - 遮罩

    private func presentOverlay(image: CGImage) {
        guard let screen = targetScreen else {
            snapshotFailed("找不到目标显示器")
            return
        }
        snapshotImage = image
        pixelScale = CGFloat(image.width) / screen.frame.width
        selectionRect = .zero
        dragStart = nil

        let panel = ensureOverlayPanel()
        let view = overlayView ?? OverlayContentView()
        view.configure(
            snapshotImage: image,
            pixelScale: pixelScale,
            dimAlpha: Self.dimAlpha,
            selectionProvider: { [weak self] in self?.selectionRect ?? .zero },
            pixelRectProvider: { [weak self] in self?.pixelRect(for: $0) },
            onMouseDown: { [weak self] in self?.handleMouseDown($0) },
            onMouseDragged: { [weak self] in self?.handleMouseDragged($0) },
            onMouseUp: { [weak self] in self?.handleMouseUp($0) },
            onRightClick: { [weak self] in self?.cancel() }
        )
        overlayView = view
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        // key window 才有稳定的指针控制权；非激活面板 makeKey 不抢应用焦点
        panel.makeKeyAndOrderFront(nil)
        // 复用的视图 + 未变的 frame 不会触发重绘，图层会残留上一会话的选区帧——强制全量重绘
        view.needsDisplay = true
        view.displayIfNeeded()
        // 光标矩形在窗口前置后不会自动刷新，主动失效一次让十字线立即生效
        panel.invalidateCursorRects(for: view)
        phase = .selecting
        HotkeyFileLog.shared.log("overlay: selecting (screen \(screen.frame.size), scale=\(pixelScale))")
    }

    // MARK: - 鼠标（由 OverlayContentView 回调，视图局部坐标）

    private func handleMouseDown(_ p: NSPoint) {
        // 工具栏期点击选区/遮罩空白 = 放弃当前选区整体退出（微信式）
        if phase == .toolbar {
            cancel()
            return
        }
        guard phase == .selecting else { return }
        HotkeyFileLog.shared.log("overlay: mouseDown at (\(Int(p.x)), \(Int(p.y)))")
        dragStart = p
        selectionRect = .zero
        overlayView?.needsDisplay = true
    }

    private func handleMouseDragged(_ p: NSPoint) {
        guard phase == .selecting, let start = dragStart, let view = overlayView else { return }
        let bounds = view.bounds
        let old = selectionRect
        // min/max 归一化：反向拖拽天然正确；与视图求交防拖出屏幕
        selectionRect = bounds.intersection(NSRect(
            x: min(start.x, p.x), y: min(start.y, p.y),
            width: abs(p.x - start.x), height: abs(p.y - start.y)
        ))
        // 压暗层在选区首次出现（空 → 非空）时整体浮现，必须全幅失效一次；
        // 之后压暗已铺满屏，只有选区边缘在动，失效新旧并集即可（外扩余量盖住
        // 边框与尺寸提示）——全幅重绘在 5K 屏单帧 ~56MB，60Hz 拖拽不可接受
        if old.isEmpty {
            view.needsDisplay = true
        } else {
            let dirty = old.union(selectionRect).insetBy(dx: -24, dy: -56)
            view.setNeedsDisplay(view.bounds.intersection(dirty))
        }
    }

    private func handleMouseUp(_ p: NSPoint) {
        guard phase == .selecting else { return }
        handleMouseDragged(p)
        HotkeyFileLog.shared.log("overlay: mouseUp sel=\(selectionRect)")
        guard selectionRect.width >= Self.minSelectionSide,
              selectionRect.height >= Self.minSelectionSide else {
            HotkeyFileLog.shared.log("overlay: click without drag, cancel")
            cancel()
            return
        }
        enterToolbarPhase()
    }

    // MARK: - 工具栏

    private func enterToolbarPhase() {
        phase = .toolbar
        let panel = ensureToolbarPanel()
        let view = ToolbarView(
            onOCR: { [weak self] in self?.runOCR() },
            onCopy: { [weak self] in self?.copyToPasteboard() },
            onSave: { [weak self] in self?.saveToDesktop() }
        )
        panel.contentView = NSHostingView(rootView: AnyView(view))
        panel.orderFrontRegardless()
        placeToolbar()
        HotkeyFileLog.shared.log("overlay: toolbar shown sel=\(selectionRect.size)")
    }

    /// 工具栏自然尺寸。零尺寸初始帧会让 SwiftUI HStack 进入压缩布局、fittingSize 量出
    /// 截断后的宽度——先给宽裕的临时帧再量，才能拿到文字完整展开的自然尺寸
    private func toolbarNaturalSize() -> NSSize {
        guard let panel = toolbarPanel,
              let hosting = panel.contentView as? NSHostingView<AnyView> else {
            return NSSize(width: 160, height: 40)
        }
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 100))
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        return NSSize(width: max(fit.width + 1, 150), height: max(fit.height, 32))
    }

    /// 选区在全局屏幕坐标系里的框（遮罩 panel 的 frame 即所在屏 frame，视图铺满）
    private func globalSelectionRect() -> NSRect {
        guard let panel = overlayPanel else { return .zero }
        return NSRect(
            x: panel.frame.origin.x + selectionRect.origin.x,
            y: panel.frame.origin.y + selectionRect.origin.y,
            width: selectionRect.width,
            height: selectionRect.height
        )
    }

    private func placeToolbar() {
        guard let panel = toolbarPanel, let screen = targetScreen else { return }
        let size = toolbarNaturalSize()
        let vf = screen.visibleFrame
        let sel = globalSelectionRect()
        // 右对齐选区右缘、放选区下方 8pt；下方放不下翻上方；双轴夹进可视区
        var x = sel.maxX - size.width
        var y = sel.minY - 8 - size.height
        if y < vf.minY + 8 { y = sel.maxY + 8 }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
    }

    // MARK: - 工具栏动作

    /// 选区（视图局部，左下原点）→ 冻结帧像素矩形（左上原点）：唯一实现，
    /// 视图拖拽高亮与裁剪/OCR/保存共用，避免两份推导漂移（review 2026-10-22）
    func pixelRect(for rect: NSRect) -> CGRect? {
        guard let image = snapshotImage, let view = overlayView, !rect.isEmpty else { return nil }
        let px = CGRect(
            x: rect.minX * pixelScale,
            y: (view.bounds.height - rect.maxY) * pixelScale,
            width: rect.width * pixelScale,
            height: rect.height * pixelScale
        ).integral
        let clamped = CGRect(x: 0, y: 0, width: image.width, height: image.height).intersection(px)
        return clamped.isEmpty ? nil : clamped
    }

    private func croppedSelectionImage() -> CGImage? {
        guard let r = overlayView.map({ selectionRect.intersection($0.bounds) }), !r.isEmpty,
              let pixelRect = pixelRect(for: r) else { return nil }
        return snapshotImage?.cropping(to: pixelRect)
    }

    private func runOCR() {
        guard phase == .toolbar, let cgImage = croppedSelectionImage() else { dismiss(); return }
        let anchor = globalSelectionCenter()
        dismiss()
        // 裁剪是 O(1) 引用操作；图片直通 Vision（Sendable 装箱），主线程零编码开销
        ScreenshotOCRPanel.shared.present(image: SendableCGImage(cgImage: cgImage), near: anchor)
    }

    private func copyToPasteboard() {
        guard phase == .toolbar, let cgImage = croppedSelectionImage() else { dismiss(); return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let tiff = rep.tiffRepresentation else {
            dismiss()
            ScreenshotOCRPanel.shared.presentFailure("图片编码失败", near: globalSelectionCenter(), title: "截图")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(tiff, forType: .tiff)
        HotkeyFileLog.shared.log("overlay: copied to pasteboard")
        dismiss()
    }

    private func saveToDesktop() {
        guard phase == .toolbar, let cgImage = croppedSelectionImage() else { dismiss(); return }
        let image = SendableCGImage(cgImage: cgImage)
        let anchor = globalSelectionCenter()
        // 先收遮罩再后台编码写盘：PNG 压缩大图要 ~1s，不能让工具栏和整个应用冻结等待
        dismiss()
        Task.detached(priority: .userInitiated) {
            // ImageIO 编码线程安全且快于 NSBitmapImageRep；失败兜底走浮窗（标题「截图」）
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                await MainActor.run { ScreenshotOCRPanel.shared.presentFailure("PNG 编码失败", near: anchor, title: "截图") }
                return
            }
            CGImageDestinationAddImage(dest, image.cgImage, nil)
            guard CGImageDestinationFinalize(dest) else {
                await MainActor.run { ScreenshotOCRPanel.shared.presentFailure("PNG 编码失败", near: anchor, title: "截图") }
                return
            }
            guard let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
                await MainActor.run { ScreenshotOCRPanel.shared.presentFailure("找不到桌面目录", near: anchor, title: "截图") }
                return
            }
            // en_US_POSIX 防用户历法（佛历等）把日期打飞
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let base = "截屏 " + formatter.string(from: Date())
            var url = dir.appendingPathComponent(base + ".png")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(base)-\(n).png")
                n += 1
            }
            do {
                try (data as Data).write(to: url, options: .atomic)
                HotkeyFileLog.shared.log("overlay: saved \(url.path)")
            } catch {
                await MainActor.run {
                    ScreenshotOCRPanel.shared.presentFailure("保存失败：\(error.localizedDescription)", near: anchor, title: "截图")
                }
            }
        }
    }

    private func globalSelectionCenter() -> NSPoint {
        let sel = globalSelectionRect()
        return NSPoint(x: sel.midX, y: sel.minY)
    }

    // MARK: - Esc（临时 Carbon 热键 id=5 + 观察型兜底 monitor）

    private static let escapeKeyCode: UInt16 = 53  // kVK_Escape

    private func registerEscHotKey() {
        guard escHotKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape), 0,
            EventHotKeyID(signature: OSType(0x5653484B), id: 5),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // 注册失败（被其他进程热键占用，极罕见）不设 NSEvent 兜底——Secure Event Input
        // 下全局监听本就收不到 keyDown，假兜底不如不设；右键/单击仍可取消，
        // 快照期最长 4s 由看门狗兜底（与录音 Esc id=4 的处理一致）
        if status == noErr { escHotKeyRef = ref }
        HotkeyFileLog.shared.log("overlay: esc hotkey register status=\(status)")
    }

    private func unregisterEscHotKey() {
        if let ref = escHotKeyRef { UnregisterEventHotKey(ref) }
        escHotKeyRef = nil
    }

    // MARK: - 窗口

    private func ensureOverlayPanel() -> NSPanel {
        if let existing = overlayPanel { return existing }
        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // 盖住菜单栏与 Dock 所在的一切常规层
        panel.level = .screenSaver
        // 全屏 App 的空间上也要能出现
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // NSPanel 默认 true：失活即隐藏——遮罩绝不能随 Cmd+Tab 走光
        panel.hidesOnDeactivate = false
        // key window 才能稳定拿到指针控制权（cursorUpdate/光标矩形），鼠标拖拽也更可靠；
        // nonactivatingPanel 下成为 key 不会激活应用，不打断用户手头的事
        panel.acceptsMouseMovedEvents = true
        overlayPanel = panel
        return panel
    }

    private func ensureToolbarPanel() -> NSPanel {
        if let existing = toolbarPanel { return existing }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // 必须压过遮罩层
        panel.level = .screenSaver + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        toolbarPanel = panel
        return panel
    }

    // MARK: - 白色十字光标

    static let crosshairCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 8.5, y: 0))
            path.line(to: NSPoint(x: 8.5, y: 17))
            path.move(to: NSPoint(x: 0, y: 8.5))
            path.line(to: NSPoint(x: 17, y: 8.5))
            // 黑色宽线打底 + 白色细线为核：暗底亮底都可见
            path.lineWidth = 3
            NSColor.black.setStroke()
            path.stroke()
            path.lineWidth = 1
            NSColor.white.setStroke()
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }()
}

// MARK: - 遮罩窗口（borderless 面板默认不能成为 key——不重写就永远拿不到指针控制权）

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 遮罩内容视图（NSView 自绘：冻结帧 + 压暗 + 选区高亮 + 尺寸提示）

private final class OverlayContentView: NSView {
    private var snapshotImage: CGImage?
    private var pixelScale: CGFloat = 1
    private var dimAlpha: CGFloat = 0.28
    /// 选区不归视图持有——overlay 是唯一事实源，draw 时经 provider 读取
    private var selectionProvider: (() -> NSRect)?
    /// 选区 → 冻结帧像素矩形，同样由 overlay 注入唯一实现
    private var pixelRectProvider: ((NSRect) -> CGRect?)?
    private var onMouseDown: ((NSPoint) -> Void)?
    private var onMouseDragged: ((NSPoint) -> Void)?
    private var onMouseUp: ((NSPoint) -> Void)?
    private var onRightClick: (() -> Void)?

    func configure(snapshotImage: CGImage, pixelScale: CGFloat, dimAlpha: CGFloat,
                   selectionProvider: @escaping () -> NSRect,
                   pixelRectProvider: @escaping (NSRect) -> CGRect?,
                   onMouseDown: @escaping (NSPoint) -> Void,
                   onMouseDragged: @escaping (NSPoint) -> Void,
                   onMouseUp: @escaping (NSPoint) -> Void,
                   onRightClick: @escaping () -> Void) {
        self.snapshotImage = snapshotImage
        self.pixelScale = pixelScale
        self.dimAlpha = dimAlpha
        self.selectionProvider = selectionProvider
        self.pixelRectProvider = pixelRectProvider
        self.onMouseDown = onMouseDown
        self.onMouseDragged = onMouseDragged
        self.onMouseUp = onMouseUp
        self.onRightClick = onRightClick
    }

    /// 会话结束释放冻结帧（整屏解码位图 ~几十 MB，菜单栏应用不能留着）
    func clearContent() {
        snapshotImage = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image = snapshotImage else { return }
        // ① 冻结帧铺满
        ctx.draw(image, in: NSRect(origin: .zero, size: bounds.size))
        let sel = selectionProvider?() ?? .zero
        // ② 未开始拖拽：画面保持原样，仅四周描边线提示截图模式已激活
        if sel.isEmpty {
            let inset = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(rect: inset)
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.stroke()
            return
        }
        // ③ 拖拽中/工具栏期：全幅压暗 + 选区内重画冻结帧原样亮显（cropping 是 O(1) 引用操作）
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        bounds.fill()
        if !sel.isEmpty, let px = pixelRectProvider?(sel), let cropped = image.cropping(to: px) {
            ctx.draw(cropped, in: sel)
        }
        // ④ 选区边框：主题蓝 1.5pt + 外圈暗描边
        if !sel.isEmpty {
            let path = NSBezierPath(rect: sel)
            path.lineWidth = 3
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.stroke()
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            // ⑤ 尺寸提示：选区下方 8pt 的黑底白字胶囊，贴底翻上方
            drawSizeBadge(for: sel)
        }
    }

    /// 像素提示尺寸取整前用视图点坐标就够（对用户展示 W × H 逻辑点）
    private func drawSizeBadge(for sel: NSRect) {
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let pad: CGFloat = 8
        let x = min(max(sel.maxX - textSize.width - pad * 2, bounds.minX + 4), bounds.maxX - textSize.width - pad * 2 - 4)
        // 默认挂选区下方；贴屏幕底部时翻到上方，避免整个画出屏外
        var y = sel.minY - textSize.height - 12
        if y < bounds.minY + 2 { y = min(sel.maxY + 8, bounds.maxY - textSize.height - 6) }
        let pill = NSRect(x: x, y: y, width: textSize.width + pad * 2, height: textSize.height + 6)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: pill.minX + pad, y: pill.minY + 3), withAttributes: attrs)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ScreenshotOverlay.crosshairCursor)
    }

    /// 非激活应用直接 NSCursor.push 会被前台应用的指针管理覆盖；靠 activeAlways 的
    /// tracking area 接收 cursorUpdate（不依赖应用激活态），把指针钉成十字线
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["cursor"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: ["cursor": true]
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        ScreenshotOverlay.crosshairCursor.set()
    }
}

// MARK: - 选区工具栏

private struct ToolbarView: View {
    let onOCR: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("文字识别", systemImage: "text.viewfinder", action: onOCR)
            Divider().frame(height: 16)
            button("复制", systemImage: "doc.on.doc", action: onCopy)
            Divider().frame(height: 16)
            button("保存", systemImage: "square.and.arrow.down", action: onSave)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // fittingSize 量的是"可压缩到的最小尺寸"，Label 会被压扁截断；
        // fixedSize 强制按理想尺寸布局，测量与渲染都保证文字完整
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        // 材质在浅色底上边界模糊，补一圈极淡的描边
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
