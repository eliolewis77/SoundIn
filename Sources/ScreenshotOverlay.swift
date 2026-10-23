import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 自建截图选区遮罩
// 触发 → screencapture -x 静默抓冻结帧 → 全屏遮罩（压暗 + 冻结帧 + 白色十字光标）
// → 拖拽选区（高亮 + 实时尺寸）→ 松手弹就地工具栏（文字识别 / 画笔 / 矩形 / 马赛克 /
// 撤销 / 复制 / 保存到桌面），标注烘焙进复制与保存的输出图（OCR 用无标注干净图）。
// 一期只做鼠标所在屏；直接替换 screencapture -i 系统 UI。
// 生命周期：idle → snapshotting → selecting → toolbar → idle。
// Swift 6：CGImage 非 Sendable，全程 MainActor 创建与消费（跨线程用 SendableCGImage 装箱）；
// Process.terminationHandler 里只把 Sendable（exit code、路径）送进 Task { @MainActor }。
// Esc 走临时 Carbon 热键 id=5、标注撤销走 ⌘Z id=6、选区期取色复制走 C id=7（进工具栏即注销）——
// Secure Event Input 下 NSEvent
// 全局监听收不到 keyDown（见 HotkeyInputManager 录音 Esc id=4 的同类结论），Carbon 不受影响。

/// 标注工具。工具栏按钮与 activeTool 的取值
enum AnnotationTool {
    case pen, rect, mosaic
}

/// 一个已提交/绘制中的标注操作。rect/mosaic 用 rect，pen 用 points。
/// colorIndex 指向 ScreenshotOverlay.annotationPalette——笔迹保留绘制时的颜色，
/// 换色不回溯影响历史笔迹
struct Annotation {
    enum Kind { case pen, rect, mosaic }
    var kind: Kind
    var points: [NSPoint] = []
    var rect: NSRect = .zero
    var colorIndex: Int = 0
}

/// 渲染状态快照：overlay 是唯一事实源，视图 draw 时经 provider 读取（与 selectionProvider 同模式）
struct AnnotationRenderState {
    var committed: [Annotation]
    var drawing: Annotation?
    var pixelated: CGImage?
    var palette: [NSColor]
}

/// 选区悬停期的取色徽标：跟随光标，展示冻结帧在光标处的颜色，C 复制后短暂切「已复制」态
struct ColorBadge {
    var position: NSPoint
    var color: NSColor
    var hex: String
    var copied: Bool = false
}

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
    private var undoHotKeyRef: EventHotKeyRef?
    private var overlayPanel: NSPanel?
    private var overlayView: OverlayContentView?
    private var toolbarPanel: NSPanel?
    // 标注状态（会话内，dismiss 全清）
    private var annotations: [Annotation] = []
    private var activeTool: AnnotationTool?
    private var drawingAnnotation: Annotation?
    private var drawingStart: NSPoint?
    /// 当前笔迹色的色板下标（笔迹类标注用；历史笔迹保留各自颜色）
    private var annotationColorIndex = 0
    /// 整帧缩小版（马赛克源图），首次使用马赛克时惰性生成
    private var pixelatedImage: CGImage?
    private var toolbarModel: ToolbarModel?
    // 取色（选区悬停期）
    private var colorHotKeyRef: EventHotKeyRef?
    private var colorBadge: ColorBadge?
    private var copiedClearTask: Task<Void, Never>?

    // MARK: - 常量

    /// 快照子进程看门狗：screencapture 挂起（休眠/显示重配中）时强杀走失败分支
    static let snapshotTimeout: TimeInterval = 4
    /// 选区宽或高小于此值视为单击（取消），不进工具栏
    static let minSelectionSide: CGFloat = 4
    static let dimAlpha: CGFloat = 0.28
    /// 标注线宽（逻辑点）
    static let annotationLineWidth: CGFloat = 3
    /// 马赛克块边长（逻辑点）：跨分辨率视觉一致
    static let mosaicBlockPoint: CGFloat = 12
    /// 标注色板：默认主题蓝，其余为高频标注色
    static let annotationPalette: [NSColor] = [.controlAccentColor, .systemRed, .systemYellow, .systemGreen]
    /// ⌥ 保存面板记住的上次目录（无沙盒，直接存路径）
    private static let lastSaveDirKey = "screenshot.lastSaveDir"
    /// 取色 1×1 采样上下文：sRGB 读数（HEX 惯例），复用避免每次 mouseMoved 重建
    private static let colorSampleContext = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )

    // MARK: - 生命周期

    func start() {
        guard phase == .idle else {
            HotkeyFileLog.shared.log("overlay: start ignored (phase=\(phase))")
            return
        }
        phase = .snapshotting
        selectionRect = .zero
        dragStart = nil
        annotations = []
        activeTool = nil
        drawingAnnotation = nil
        drawingStart = nil
        pixelatedImage = nil
        annotationColorIndex = 0
        unregisterUndoHotKey()
        unregisterColorHotKey()
        colorBadge = nil
        copiedClearTask?.cancel()
        copiedClearTask = nil
        toolbarModel = nil
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
        unregisterUndoHotKey()
        unregisterColorHotKey()
        copiedClearTask?.cancel()
        copiedClearTask = nil
        toolbarPanel?.orderOut(nil)
        overlayPanel?.orderOut(nil)
        NSCursor.pop()
        // 冻结帧是整屏解码位图（5K 屏 ~56MB），会话结束必须释放，不能等下次覆盖
        snapshotImage = nil
        pixelatedImage = nil
        overlayView?.clearContent()
        annotations = []
        activeTool = nil
        drawingAnnotation = nil
        drawingStart = nil
        annotationColorIndex = 0
        colorBadge = nil
        toolbarModel = nil
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
            annotationState: { [weak self] in
                guard let self, !self.annotations.isEmpty || self.drawingAnnotation != nil else { return nil }
                // 马赛克标注在场才生成/保留像素化帧（惰性）
                let needsMosaic = self.annotations.contains { $0.kind == .mosaic }
                    || (self.drawingAnnotation?.kind == .mosaic)
                if needsMosaic { self.pixelatedFrameIfNeeded() }
                return AnnotationRenderState(
                    committed: self.annotations,
                    drawing: self.drawingAnnotation,
                    pixelated: self.pixelatedImage,
                    palette: Self.annotationPalette
                )
            },
            onMouseDown: { [weak self] in self?.handleMouseDown($0) },
            onMouseDragged: { [weak self] in self?.handleMouseDragged($0) },
            onMouseUp: { [weak self] in self?.handleMouseUp($0) },
            onMouseMoved: { [weak self] in self?.handleMouseMoved($0) },
            onRightClick: { [weak self] in self?.cancel() },
            colorBadge: { [weak self] in self?.colorBadge }
        )
        overlayView = view
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        // 非激活面板 makeKey 不抢应用焦点，但能让点击/拖拽事件稳定送达遮罩
        panel.makeKeyAndOrderFront(nil)
        // 复用的视图 + 未变的 frame 不会触发重绘，图层会残留上一会话的选区帧——强制全量重绘
        view.needsDisplay = true
        view.displayIfNeeded()
        // 光标矩形在窗口前置后不会自动刷新，主动失效一次让十字线立即生效
        panel.invalidateCursorRects(for: view)
        phase = .selecting
        // 取色热键只在选区期接管 C：快照期与工具栏期不注册，缩小吞键窗口
        registerColorHotKey()
        // 遮罩出现即在光标处出徽标，不等第一次 mouseMoved
        let mouseLocal = NSPoint(
            x: NSEvent.mouseLocation.x - panel.frame.origin.x,
            y: NSEvent.mouseLocation.y - panel.frame.origin.y
        )
        if view.bounds.contains(mouseLocal) {
            handleMouseMoved(mouseLocal)
        }
        HotkeyFileLog.shared.log("overlay: selecting (screen \(screen.frame.size), scale=\(pixelScale))")
    }

    // MARK: - 鼠标（由 OverlayContentView 回调，视图局部坐标）

    private func handleMouseDown(_ p: NSPoint) {
        // 工具栏期：激活了标注工具且点击在选区内 → 绘制；
        // 无激活工具时点击选区/遮罩空白 = 放弃当前选区整体退出（微信式）
        if phase == .toolbar {
            if let tool = activeTool {
                // 工具激活期选区外点击忽略：防手一滑丢掉整个会话的标注（无工具时保留微信式取消）
                guard selectionRect.contains(p) else { return }
                beginAnnotation(tool, at: p)
                return
            }
            cancel()
            return
        }
        guard phase == .selecting else { return }
        HotkeyFileLog.shared.log("overlay: mouseDown at (\(Int(p.x)), \(Int(p.y)))")
        dragStart = p
        selectionRect = .zero
        colorBadge = nil
        overlayView?.needsDisplay = true
    }

    /// 悬停取色：只失效新旧徽标并集（全幅重绘在 5K 屏 60Hz 移动下不可接受，同拖拽策略）
    private func handleMouseMoved(_ p: NSPoint) {
        guard phase == .selecting, dragStart == nil, let view = overlayView else { return }
        let old = colorBadge
        guard let sample = sampledColor(at: p) else {
            if old != nil {
                colorBadge = nil
                view.invalidateColorBadge(old: old, new: nil)
            }
            return
        }
        // 1.2s 复制反馈窗内继续移动（如在同一色块上微调）保持「已复制」态，由 copiedClearTask 统一收尾
        colorBadge = ColorBadge(position: p, color: sample.color, hex: sample.hex, copied: old?.copied == true)
        view.invalidateColorBadge(old: old, new: colorBadge)
    }

    /// 光标处冻结帧取色。取原始帧而非压暗+标注后的合成画面：取色的对象是截图瞬间的屏幕内容
    private func sampledColor(at p: NSPoint) -> (color: NSColor, hex: String)? {
        guard let image = snapshotImage, let ctx = Self.colorSampleContext,
              let crop = pixelRect(for: NSRect(x: p.x, y: p.y, width: 1, height: 1))
                  .flatMap({ image.cropping(to: $0) }) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return (
            NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                    blue: CGFloat(bytes[2]) / 255, alpha: 1),
            String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        )
    }

    private func handleMouseDragged(_ p: NSPoint) {
        // 工具栏期的拖拽是标注绘制（无绘制中标注则 no-op）
        if phase == .toolbar {
            updateAnnotation(at: p)
            return
        }
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
        // 工具栏期的松手是标注落库
        if phase == .toolbar {
            finishAnnotation(at: p)
            return
        }
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
        // 工具栏期 C 交还前台应用，不再吞键
        unregisterColorHotKey()
        copiedClearTask?.cancel()
        copiedClearTask = nil
        colorBadge = nil
        let model = ToolbarModel()
        toolbarModel = model
        let panel = ensureToolbarPanel()
        let view = ToolbarView(
            model: model,
            onOCR: { [weak self] in self?.runOCR() },
            onCopy: { [weak self] in self?.copyToPasteboard() },
            onSave: { [weak self] in self?.saveToDesktop() },
            onToggleTool: { [weak self] in self?.toggleTool($0) },
            onUndo: { [weak self] in self?.undoLastAnnotation() },
            onSetColor: { [weak self] in self?.setAnnotationColor($0) }
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

    // MARK: - 标注

    private func toggleTool(_ tool: AnnotationTool) {
        activeTool = (activeTool == tool) ? nil : tool
        drawingAnnotation = nil
        toolbarModel?.activeTool = activeTool
        // 激活笔迹类工具时色板展开/收起会改变工具栏宽度，重新测量摆放
        placeToolbar()
        HotkeyFileLog.shared.log("overlay: tool \(activeTool.map { "\($0)" } ?? "none")")
    }

    /// 选色只影响后续笔迹（历史笔迹保留各自颜色），布局不变无需重摆
    private func setAnnotationColor(_ index: Int) {
        guard Self.annotationPalette.indices.contains(index) else { return }
        annotationColorIndex = index
        toolbarModel?.colorIndex = index
        overlayView?.setNeedsDisplay(selectionRect.insetBy(dx: -6, dy: -6))
    }

    private func beginAnnotation(_ tool: AnnotationTool, at rawPoint: NSPoint) {
        let p = clampedToSelection(rawPoint)
        drawingStart = p
        switch tool {
        case .pen: drawingAnnotation = Annotation(kind: .pen, points: [p], colorIndex: annotationColorIndex)
        case .rect: drawingAnnotation = Annotation(kind: .rect, rect: NSRect(origin: p, size: .zero), colorIndex: annotationColorIndex)
        case .mosaic: drawingAnnotation = Annotation(kind: .mosaic, rect: NSRect(origin: p, size: .zero))
        }
    }

    private func updateAnnotation(at rawPoint: NSPoint) {
        guard var drawing = drawingAnnotation, drawingStart != nil else { return }
        let p = clampedToSelection(rawPoint)
        let old = annotationBounds(drawing)
        switch drawing.kind {
        case .pen:
            // 距上点 <1.5pt 跳过：防长笔画聚出万点数组
            if let last = drawing.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            drawing.points.append(p)
        case .rect, .mosaic:
            guard let start = drawingStart else { return }
            drawing.rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                  width: abs(p.x - start.x), height: abs(p.y - start.y))
        }
        drawingAnnotation = drawing
        invalidateAnnotationChange(oldB: old, newB: annotationBounds(drawing))
    }

    private func finishAnnotation(at rawPoint: NSPoint) {
        guard var drawing = drawingAnnotation else { return }
        let p = clampedToSelection(rawPoint)
        switch drawing.kind {
        case .pen:
            // 单击（无拖拽）也是合法标注：渲染为圆点
            if let last = drawing.points.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 {
                drawing.points.append(p)
            }
        case .rect, .mosaic:
            // drawingStart 由 beginAnnotation 必设；兜底只为免解包，退化矩形会被下方尺寸检查丢弃
            let start = drawingStart ?? p
            drawing.rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                  width: abs(p.x - start.x), height: abs(p.y - start.y))
            // 过小视为误触，丢弃
            guard drawing.rect.width >= 2, drawing.rect.height >= 2 else {
                drawingAnnotation = nil
                return
            }
        }
        annotations.append(drawing)
        drawingAnnotation = nil
        // 懒注册：首次有标注可撤才接管 ⌘Z（Carbon 全局热键吞键不透传，
        // 空窗期吞前台应用的撤销键是最差语义）；撤空即注销
        if annotations.count == 1 { registerUndoHotKey() }
        toolbarModel?.canUndo = true
        overlayView?.setNeedsDisplay(selectionRect.insetBy(dx: -6, dy: -6))
        HotkeyFileLog.shared.log("overlay: annotation committed (\(drawing.kind))")
    }

    private func undoLastAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        if annotations.isEmpty {
            unregisterUndoHotKey()
            toolbarModel?.canUndo = false
        }
        overlayView?.setNeedsDisplay(selectionRect.insetBy(dx: -6, dy: -6))
        HotkeyFileLog.shared.log("overlay: annotation undone, left=\(annotations.count)")
    }

    private func annotationBounds(_ a: Annotation) -> NSRect {
        switch a.kind {
        case .pen:
            guard let first = a.points.first else { return .zero }
            var r = NSRect(origin: first, size: .zero)
            for p in a.points.dropFirst() { r = r.union(NSRect(origin: p, size: .zero)) }
            return r
        case .rect, .mosaic:
            return a.rect
        }
    }

    /// 标注失效区：新旧 bbox 并集外扩后夹回选区（标注被 clip 在选区内，勿扩出去）
    private func invalidateAnnotationChange(oldB: NSRect, newB: NSRect) {
        guard let view = overlayView else { return }
        let dirty = oldB.union(newB).insetBy(dx: -6, dy: -6)
            .intersection(selectionRect.insetBy(dx: -8, dy: -8))
            .intersection(view.bounds)
        view.setNeedsDisplay(dirty)
    }

    private func clampedToSelection(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, selectionRect.minX), selectionRect.maxX),
                y: min(max(p.y, selectionRect.minY), selectionRect.maxY))
    }

    /// 整帧缩小版（马赛克源图），首次需要时惰性生成。
    /// 缩小用 .high（盒式均值），绘制/烘焙时 .none 最近邻放大 → 硬边马赛克块
    private func pixelatedFrameIfNeeded() {
        guard pixelatedImage == nil, let image = snapshotImage else { return }
        let factor = max(2, Int((pixelScale * Self.mosaicBlockPoint).rounded()))
        let w = max(1, image.width / factor)
        let h = max(1, image.height / factor)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        pixelatedImage = ctx.makeImage()
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

    /// 带标注的选区图：裁剪干净图 + 重放标注。无标注零成本走干净图老路。
    /// 坐标变换（已验证）：视图点 v → (scale·v.x − P.minX, scale·v.y + P.maxY − scale·viewH)，
    /// 其中 P 为 integral 后的像素裁剪框——用 sel 原点推导会有 ±1px 漂移
    private func annotatedSelectionImage() -> CGImage? {
        guard !annotations.isEmpty else { return croppedSelectionImage() }
        guard let clean = croppedSelectionImage(),
              let pixelP = pixelRect(for: selectionRect),
              let view = overlayView, let frame = snapshotImage else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixelP.width), height: Int(pixelP.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: frame.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(clean, in: CGRect(x: 0, y: 0, width: pixelP.width, height: pixelP.height))
        ctx.translateBy(x: -pixelP.minX, y: pixelP.maxY - pixelScale * view.bounds.height)
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        let needsMosaic = annotations.contains { $0.kind == .mosaic }
        var pixelated: CGImage?
        if needsMosaic {
            pixelatedFrameIfNeeded()
            pixelated = pixelatedImage
        }
        for a in annotations {
            renderAnnotation(a, in: ctx, pixelated: pixelated,
                             viewBounds: view.bounds.size, palette: Self.annotationPalette)
        }
        return ctx.makeImage()
    }

    private func runOCR() {
        // OCR 用无标注干净图：识别用户画的框没有意义，反而干扰识别
        guard phase == .toolbar, let cgImage = croppedSelectionImage() else { dismiss(); return }
        let anchor = globalSelectionCenter()
        dismiss()
        // 裁剪是 O(1) 引用操作；图片直通 Vision（Sendable 装箱），主线程零编码开销
        ScreenshotOCRPanel.shared.present(image: SendableCGImage(cgImage: cgImage), near: anchor)
    }

    private func copyToPasteboard() {
        // 复制/保存带标注（烘焙失败兜底干净图，不因标注丢功能）
        guard phase == .toolbar, let cgImage = annotatedSelectionImage() ?? croppedSelectionImage() else { dismiss(); return }
        let anchor = globalSelectionCenter()
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let tiff = rep.tiffRepresentation else {
            dismiss()
            ScreenshotOCRPanel.shared.presentFailure("图片编码失败", near: anchor, title: "截图")
            return
        }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setData(tiff, forType: .tiff)
        HotkeyFileLog.shared.log("overlay: copied to pasteboard copied=\(copied)")
        dismiss()
        // 成功不弹提示：遮罩收起本身就是反馈；失败仍走浮窗
        if !copied {
            ScreenshotOCRPanel.shared.presentFailure("复制失败，请重试", near: anchor, title: "截图")
        }
    }

    private func saveToDesktop() {
        guard phase == .toolbar, let cgImage = annotatedSelectionImage() ?? croppedSelectionImage() else { dismiss(); return }
        let image = SendableCGImage(cgImage: cgImage)
        let anchor = globalSelectionCenter()
        // 先收遮罩再做后续动作：PNG 编码大图要 ~1s，不能让工具栏和整个应用冻结等待；
        // Esc/⌘Z 热键随 dismiss 注销，保存面板里按键只作用于面板本身
        dismiss()
        if NSEvent.modifierFlags.contains(.option) {
            presentSavePanel(image: image, anchor: anchor)
        } else {
            writeScreenshotInBackground(image, destination: nil, anchor: anchor)
        }
    }

    /// ⌥ 保存：NSSavePanel 自选位置并记住目录；取消则静默结束不写盘。
    /// 同步 runModal 是 macOS 标准保存交互
    private func presentSavePanel(image: SendableCGImage, anchor: NSPoint) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截屏 " + Self.timestampString()
        panel.directoryURL = UserDefaults.standard.url(forKey: Self.lastSaveDirKey)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: Self.lastSaveDirKey)
        writeScreenshotInBackground(image, destination: url, anchor: anchor)
    }

    /// 编码 + 写盘全部后台：destination 为 nil 走默认路径（桌面 + 时间戳 + 防重名）
    private func writeScreenshotInBackground(_ image: SendableCGImage, destination: URL?, anchor: NSPoint) {
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
            let target: URL
            if let destination {
                target = destination
            } else {
                guard let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
                    await MainActor.run { ScreenshotOCRPanel.shared.presentFailure("找不到桌面目录", near: anchor, title: "截图") }
                    return
                }
                let base = "截屏 " + Self.timestampString()
                var url = dir.appendingPathComponent(base + ".png")
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = dir.appendingPathComponent("\(base)-\(n).png")
                    n += 1
                }
                target = url
            }
            do {
                try (data as Data).write(to: target, options: .atomic)
                HotkeyFileLog.shared.log("overlay: saved \(target.path)")
                await MainActor.run {
                    guard ScreenshotOverlay.shared.phase == .idle else { return }
                    ScreenshotOCRPanel.feedback.presentSuccess(destination == nil ? "已保存到桌面" : "已保存截图",
                                                            savedURL: target, near: anchor)
                }
            } catch {
                await MainActor.run {
                    ScreenshotOCRPanel.shared.presentFailure("保存失败：\(error.localizedDescription)", near: anchor, title: "截图")
                }
            }
        }
    }

    /// en_US_POSIX 防用户历法（佛历等）把日期打飞。nonisolated：后台写盘任务也用
    private nonisolated static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
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

    // MARK: - ⌘Z 撤销（临时 Carbon 热键 id=6，懒注册）

    private func registerUndoHotKey() {
        guard undoHotKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Z), UInt32(cmdKey),
            EventHotKeyID(signature: OSType(0x5653484B), id: 6),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // 失败（⌘Z 被其他进程占用，极罕见）只记日志：工具栏撤销按钮仍可用
        if status == noErr { undoHotKeyRef = ref }
        HotkeyFileLog.shared.log("overlay: cmd-z hotkey register status=\(status)")
    }

    private func unregisterUndoHotKey() {
        if let ref = undoHotKeyRef { UnregisterEventHotKey(ref) }
        undoHotKeyRef = nil
    }

    /// Carbon ⌘Z（id=6）派发入口。绘制中忽略，防「撤上一笔的同时正画新一笔」的状态交错
    func handleUndoHotKey() {
        guard phase == .toolbar, !annotations.isEmpty, drawingAnnotation == nil else { return }
        HotkeyFileLog.shared.log("overlay: undo (hotkey)")
        undoLastAnnotation()
    }

    // MARK: - C 取色复制（临时 Carbon 热键 id=7，仅选区期注册）

    private func registerColorHotKey() {
        guard colorHotKeyRef == nil else { return }
        // 触发键被配成裸 C 时不注册：Carbon 重复注册首个生效，取色会静默失效还劫持触发键
        guard !HotkeyInputManager.shared.isBareTriggerKey(UInt16(kVK_ANSI_C)) else {
            HotkeyFileLog.shared.log("overlay: color-pick hotkey skipped (bare C is a trigger shortcut)")
            return
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_C), 0,
            EventHotKeyID(signature: OSType(0x5653484B), id: 7),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr { colorHotKeyRef = ref }
        HotkeyFileLog.shared.log("overlay: color-pick hotkey register status=\(status)")
    }

    private func unregisterColorHotKey() {
        if let ref = colorHotKeyRef { UnregisterEventHotKey(ref) }
        colorHotKeyRef = nil
    }

    /// Carbon C（id=7）派发入口：复制悬停徽标当前色值，会话不退出（取色常是连续动作）。
    /// 反馈画在徽标自身——结果浮窗是 .floating 层，会被 .screenSaver 遮罩盖住
    func handleColorPickHotKey() {
        // 多屏时热键是全局的：光标已离开遮罩所在屏时徽标是陈旧采样，不能照抄
        guard phase == .selecting, dragStart == nil, let badge = colorBadge, let view = overlayView,
              let panel = overlayPanel, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(badge.hex, forType: .string) else {
            HotkeyFileLog.shared.log("overlay: color copy FAILED \(badge.hex)")
            return
        }
        let old = colorBadge
        colorBadge?.copied = true
        view.invalidateColorBadge(old: old, new: colorBadge)
        copiedClearTask?.cancel()
        copiedClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.colorBadge?.copied == true,
                  let view = self.overlayView else { return }
            let copied = self.colorBadge
            self.colorBadge?.copied = false
            view.invalidateColorBadge(old: copied, new: self.colorBadge)
        }
        HotkeyFileLog.shared.log("overlay: color copied \(badge.hex)")
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

/// 标注渲染：视图实时预览与复制/保存的烘焙共用同一实现（全走 CGContext，
/// 两处上下文同源）。坐标系为遮罩视图局部坐标（左下原点）。仅 MainActor 调用
@MainActor
private func renderAnnotation(_ annotation: Annotation, in ctx: CGContext,
                              pixelated: CGImage?, viewBounds: NSSize, palette: [NSColor]) {
    let width = ScreenshotOverlay.annotationLineWidth
    // 每笔用自己的色号（换色不回溯历史笔迹）
    let strokeColor = palette[annotation.colorIndex % max(palette.count, 1)]
        .usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
    switch annotation.kind {
    case .pen:
        let points = annotation.points
        guard !points.isEmpty else { return }
        if points.count == 1, let p = points.first {
            // 单击成点：零长路径 stroke 不出来，画实心圆
            ctx.setFillColor(strokeColor)
            ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
            return
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
    case .rect:
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(width)
        ctx.stroke(annotation.rect)
    case .mosaic:
        guard let pixelated else { return }
        ctx.saveGState()
        ctx.clip(to: annotation.rect)
        // 最近邻放大 → 硬边马赛克块
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: NSRect(origin: .zero, size: viewBounds))
        ctx.restoreGState()
    }
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
    /// 标注渲染状态（committed + 绘制中 + 马赛克帧 + 颜色），无标注时返回 nil 跳过绘制
    private var annotationStateProvider: (() -> AnnotationRenderState?)?
    private var onMouseDown: ((NSPoint) -> Void)?
    private var onMouseDragged: ((NSPoint) -> Void)?
    private var onMouseUp: ((NSPoint) -> Void)?
    private var onMouseMoved: ((NSPoint) -> Void)?
    private var onRightClick: (() -> Void)?
    private var colorBadgeProvider: (() -> ColorBadge?)?

    func configure(snapshotImage: CGImage, pixelScale: CGFloat, dimAlpha: CGFloat,
                   selectionProvider: @escaping () -> NSRect,
                   pixelRectProvider: @escaping (NSRect) -> CGRect?,
                   annotationState: @escaping () -> AnnotationRenderState?,
                   onMouseDown: @escaping (NSPoint) -> Void,
                   onMouseDragged: @escaping (NSPoint) -> Void,
                   onMouseUp: @escaping (NSPoint) -> Void,
                   onMouseMoved: @escaping (NSPoint) -> Void,
                   onRightClick: @escaping () -> Void,
                   colorBadge: @escaping () -> ColorBadge?) {
        self.snapshotImage = snapshotImage
        self.pixelScale = pixelScale
        self.dimAlpha = dimAlpha
        self.selectionProvider = selectionProvider
        self.pixelRectProvider = pixelRectProvider
        self.annotationStateProvider = annotationState
        self.onMouseDown = onMouseDown
        self.onMouseDragged = onMouseDragged
        self.onMouseUp = onMouseUp
        self.onMouseMoved = onMouseMoved
        self.onRightClick = onRightClick
        self.colorBadgeProvider = colorBadge
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
            if let badge = colorBadgeProvider?() {
                drawColorBadge(badge)
            }
            return
        }
        // ③ 拖拽中/工具栏期：全幅压暗 + 选区内重画冻结帧原样亮显（cropping 是 O(1) 引用操作）
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        bounds.fill()
        if !sel.isEmpty, let px = pixelRectProvider?(sel), let cropped = image.cropping(to: px) {
            ctx.draw(cropped, in: sel)
        }
        // ③½ 标注：clip 在选区内、主题色绘制（边框压在其上，保持选区框清晰）
        if !sel.isEmpty, let state = annotationStateProvider?() {
            ctx.saveGState()
            ctx.clip(to: sel)
            for a in state.committed {
                renderAnnotation(a, in: ctx, pixelated: state.pixelated,
                                 viewBounds: bounds.size, palette: state.palette)
            }
            if let d = state.drawing {
                renderAnnotation(d, in: ctx, pixelated: state.pixelated,
                                 viewBounds: bounds.size, palette: state.palette)
            }
            ctx.restoreGState()
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

    // MARK: 取色徽标

    /// 徽标失效区：新旧 pill 并集外扩后夹回视图。nil 徽标的 .zero 不参与并集
    /// （zero.union 会把原点拖进 dirty 区，会话首帧会多一次大面积重绘）
    func invalidateColorBadge(old: ColorBadge?, new: ColorBadge?) {
        var dirty = colorBadgeRect(for: new)
        let oldRect = colorBadgeRect(for: old)
        if oldRect != .zero { dirty = dirty.union(oldRect) }
        setNeedsDisplay(bounds.intersection(dirty.insetBy(dx: -4, dy: -4)))
    }

    /// 徽标 pill 矩形（视图局部）：光标右上 16pt 避开十字线，贴边翻转；nil → .zero。
    /// 失效区计算与 draw 共用同一几何，防止两份推导漂移
    func colorBadgeRect(for badge: ColorBadge?) -> NSRect {
        guard let badge else { return .zero }
        var x = badge.position.x + 16
        var y = badge.position.y + 16
        if x + Self.colorBadgePillSize.width > bounds.maxX - 4 { x = badge.position.x - 16 - Self.colorBadgePillSize.width }
        if y + Self.colorBadgePillSize.height > bounds.maxY - 4 { y = badge.position.y - 16 - Self.colorBadgePillSize.height }
        return NSRect(origin: NSPoint(x: x, y: y), size: Self.colorBadgePillSize)
    }

    /// pill 尺寸固定：HEX 等宽字体 7 字符 + 两种提示取宽，悬停热路径不逐次量字
    private static let colorBadgePillSize: NSSize = {
        let hexWidth = ("#000000" as NSString).size(withAttributes: colorBadgeHexAttributes).width
        let hintWidth = max(
            ("C 复制" as NSString).size(withAttributes: colorBadgeHintAttributes).width,
            ("已复制" as NSString).size(withAttributes: colorBadgeHintAttributes).width
        )
        let contentWidth = ceil(max(hexWidth, hintWidth))
        let width: CGFloat = 10 + 18 + 7 + contentWidth + 10
        return NSSize(width: width, height: 44)
    }()

    private static let colorBadgeHexAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    private static let colorBadgeHintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor.white.withAlphaComponent(0.65)
    ]

    private static func colorBadgeHint(_ badge: ColorBadge) -> String {
        badge.copied ? "已复制" : "C 复制"
    }

    private func drawColorBadge(_ badge: ColorBadge) {
        let pill = colorBadgeRect(for: badge)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        // 色块双描边（黑打底白芯）同十字光标套路，深浅色都可见
        let swatch = NSRect(x: pill.minX + 10, y: pill.minY + (pill.height - 18) / 2, width: 18, height: 18)
        let swatchPath = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
        badge.color.setFill()
        swatchPath.fill()
        swatchPath.lineWidth = 2
        NSColor.black.withAlphaComponent(0.35).setStroke()
        swatchPath.stroke()
        swatchPath.lineWidth = 1
        NSColor.white.setStroke()
        swatchPath.stroke()
        // 上行 HEX、下行操作提示：快捷键不写在文档里写在界面上
        let hex = badge.hex as NSString
        let hexSize = hex.size(withAttributes: Self.colorBadgeHexAttributes)
        let textX = swatch.maxX + 7
        let textW = pill.maxX - 10 - textX
        hex.draw(in: NSRect(x: textX, y: pill.maxY - 8 - hexSize.height, width: textW, height: hexSize.height),
                 withAttributes: Self.colorBadgeHexAttributes)
        let hint = Self.colorBadgeHint(badge) as NSString
        let hintSize = hint.size(withAttributes: Self.colorBadgeHintAttributes)
        hint.draw(in: NSRect(x: textX, y: pill.minY + 7, width: textW, height: hintSize.height),
                  withAttributes: Self.colorBadgeHintAttributes)
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
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
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self,
            userInfo: ["cursor": true]
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        ScreenshotOverlay.crosshairCursor.set()
    }
}

// MARK: - 选区工具栏

/// 工具栏按钮态。@Observable 原地更新（无闪烁、无 fittingSize 重测竞态）；
/// overlay 自身字段仍是唯一事实源，model 只是视图投影
@MainActor
@Observable
private final class ToolbarModel {
    var activeTool: AnnotationTool?
    var canUndo = false
    var colorIndex = 0
}

private struct ToolbarView: View {
    let model: ToolbarModel
    let onOCR: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onToggleTool: (AnnotationTool) -> Void
    let onUndo: () -> Void
    let onSetColor: (Int) -> Void

    /// 笔迹类工具激活时展开色板（马赛克无颜色概念）
    private var showsColorSwatches: Bool {
        model.activeTool == .pen || model.activeTool == .rect
    }

    var body: some View {
        HStack(spacing: 2) {
            toolButton("画笔", systemImage: "pencil.tip", tool: .pen)
            toolButton("矩形", systemImage: "rectangle", tool: .rect)
            toolButton("马赛克", systemImage: "square.grid.3x3", tool: .mosaic)
            if showsColorSwatches {
                Divider().frame(height: 16)
                ForEach(ScreenshotOverlay.annotationPalette.indices, id: \.self) { index in
                    swatch(index: index)
                }
            }
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.canUndo ? .primary : .tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .help("撤销标注（⌘Z）")
            .accessibilityLabel("撤销标注")
            Divider().frame(height: 16)
            button("文字识别", systemImage: "text.viewfinder", action: onOCR)
            button("复制", systemImage: "doc.on.doc", action: onCopy)
            button("保存", systemImage: "square.and.arrow.down", action: onSave,
                   help: "保存到桌面（按住 ⌥ 点击可选择位置）")
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

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void, help: String? = nil) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }

    /// 色板圆点：选中态白圈 + 深色外圈双环，压暗底和亮底都可见
    private func swatch(index: Int) -> some View {
        let color = ScreenshotOverlay.annotationPalette[index]
        let selected = model.colorIndex == index
        return Button {
            onSetColor(index)
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 12, height: 12)
                .overlay {
                    if selected {
                        Circle().strokeBorder(Color.white, lineWidth: 1.5)
                        Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("标注颜色")
        .accessibilityLabel("标注颜色 \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 标注工具按钮：图标态，激活时 accent 圆角底 + 白图标
    private func toolButton(_ title: String, systemImage: String, tool: AnnotationTool) -> some View {
        let active = model.activeTool == tool
        return Button {
            onToggleTool(tool)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
