import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 自建截图选区遮罩
// 触发 → screencapture -x 静默抓冻结帧 → 全屏遮罩（压暗 + 冻结帧 + 白色十字光标）
// → 拖拽选区（高亮 + 实时尺寸）→ 松手弹就地工具栏（画笔 / 矩形 / 马赛克 / 撤销 /
// 关闭 / 文字识别 / 钉住 / 保存到桌面 / 复制），标注烘焙进复制与保存的输出图（OCR 用无标注干净图）。
// 一期只做鼠标所在屏；直接替换 screencapture -i 系统 UI。
// 生命周期：idle → snapshotting → selecting → toolbar → idle。
// 工具栏期可拖 8 手柄（4 边 + 4 角）缩放选区、选区内拖动整体平移（已画标注跟随），
// 选区外空白点击仍整次取消；激活标注工具期间禁用调整，拖拽仍为绘制。
// Swift 6：CGImage 非 Sendable，全程 MainActor 创建与消费（跨线程用 SendableCGImage 装箱）；
// Process.terminationHandler 里只把 Sendable（exit code、路径）送进 Task { @MainActor }。
// Esc 走临时 Carbon 热键 id=5、标注撤销走 ⌘Z id=6、选区期取色复制走 C id=7（进工具栏即注销）——
// Secure Event Input 下 NSEvent
// 全局监听收不到 keyDown（见 HotkeyInputManager 录音 Esc id=4 的同类结论），Carbon 不受影响。

/// 标注工具。工具栏按钮与 activeTool 的取值
enum AnnotationTool {
    case pen, rect, mosaic, text
}

/// 一个已提交/绘制中的标注操作。rect/mosaic 用 rect，pen 用 points，text 用 text+point。
/// colorIndex 指向 ScreenshotOverlay.annotationPalette——笔迹保留绘制时的颜色，
/// 换色不回溯影响历史笔迹
struct Annotation {
    enum Kind { case pen, rect, mosaic, text }
    var kind: Kind
    var points: [NSPoint] = []
    var rect: NSRect = .zero
    var colorIndex: Int = 0
    var text: String = ""
    /// 文本标注锚点（文本框左上角，视图局部坐标；文本向下方延展，视觉占 [point.y - 高, point.y]）
    var point: NSPoint = .zero
    /// 文本字号（逻辑点），每条文本保留创建时的字号
    var fontSize: CGFloat = ScreenshotOverlay.defaultTextFontSize
    /// 每条文本保留排版宽度，窄选区也按相同宽度预览、命中与导出。
    var textWidth: CGFloat = ScreenshotOverlay.textMaxWidth
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
final class ScreenshotOverlay: NSObject, NSTextViewDelegate {
    static let shared = ScreenshotOverlay()
    override private init() {}

    enum Phase: Equatable {
        case idle, snapshotting, selecting, toolbar
    }

    /// 工具栏期选区命中区：hover 光标切换与 mouseDown 手势分流共用
    private enum SelectionZone: Equatable {
        case outside, inside, border(SelectionEdges)
    }

    /// 工具栏期选区调整手势（仅无激活标注工具时存在）
    private enum SelectionGesture {
        /// 选区内拖动：整体平移
        case move(originalRect: NSRect, startPoint: NSPoint)
        /// 拖边/角：按边集缩放
        case resize(edges: SelectionEdges, originalRect: NSRect)
    }

    /// 选区四边集合（角 = 相邻两边组合）
    private struct SelectionEdges: OptionSet {
        let rawValue: UInt8
        static let minX = SelectionEdges(rawValue: 1 << 0)
        static let maxX = SelectionEdges(rawValue: 1 << 1)
        static let minY = SelectionEdges(rawValue: 1 << 2)
        static let maxY = SelectionEdges(rawValue: 1 << 3)
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
    /// 工具栏期选区调整手势（无激活工具时）：边/角拖 = 缩放，选区内拖 = 平移
    private var selectionGesture: SelectionGesture?
    /// 工具栏期光标悬停命中区，驱动缩放/移动/箭头光标切换
    private var toolbarHoverZone: SelectionZone = .outside
    /// 工具栏自然尺寸缓存：调整选区时逐事件重摆工具栏，量测只在色板收展后重做
    private var cachedToolbarSize: NSSize?
    private var snapshotProcess: Process?
    private var watchdogTask: Task<Void, Never>?
    private var escHotKeyRef: EventHotKeyRef?
    private var undoHotKeyRef: EventHotKeyRef?
    private var overlayPanel: OverlayPanel?
    private var overlayView: OverlayContentView?
    private var ownsCursorStackEntry = false
    private var previousApplication: NSRunningApplication?
    private var toolbarPanel: NSPanel?
    // 标注状态（会话内，dismiss 全清）
    private var annotations: [Annotation] = []
    private var activeTool: AnnotationTool?
    private var drawingAnnotation: Annotation?
    private var drawingStart: NSPoint?
    /// 当前笔迹色的色板下标（笔迹类标注用；历史笔迹保留各自颜色）
    private var annotationColorIndex = ScreenshotOverlay.defaultAnnotationColorIndex
    /// 整帧缩小版（马赛克源图），首次使用马赛克时惰性生成
    private var pixelatedImage: CGImage?
    private var toolbarModel: ToolbarModel?
    /// 文本标注编辑框（隐藏的键盘/IME 接管视图，文字由遮罩画布直接渲染）
    private var textEditor: TextEditorView?
    /// 编辑中的文本草稿：随输入实时渲染在画布上（与提交后同一排版路径）
    private var textDraft: Annotation?
    /// 草稿色号（新文本跟随色板，重编辑沿用原色）
    private var textDraftColorIndex = ScreenshotOverlay.defaultAnnotationColorIndex
    /// 输入框锚点（文本框左上角），提交时落库
    private var textLayoutWidth: CGFloat = ScreenshotOverlay.textMaxWidth
    private var textAnchor: NSPoint = .zero
    /// 当前编辑的已有文本标注下标（双击重编辑）；nil = 新文本
    private var editingTextIndex: Int?
    /// 新文本使用的字号（工具栏可选）
    private var annotationFontSize: CGFloat = ScreenshotOverlay.defaultTextFontSize
    /// 上一帧光标矩形（失效区计算用）
    private var lastCaretRect: NSRect?
    /// 文本标注拖拽（工具栏期：无工具或文本工具时按住文本可单独移位）
    private var textDrag: (index: Int, original: NSPoint, start: NSPoint)?
    /// 悬停命中的文本标注下标（驱动抓手光标；仅无工具/文本工具时更新）
    private var textHoverIndex: Int?
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
    /// 标注色板：下标 0 是红色（默认选中），其余为主题蓝/黄/绿
    nonisolated static let annotationPalette: [NSColor] = [.systemRed, .controlAccentColor, .systemYellow, .systemGreen]
    /// 默认笔迹色 = 色板下标 0（红色）
    static let defaultAnnotationColorIndex = 0
    /// 文本字号档位（微信式固定档），defaultTextFontSize 为新文本默认档
    nonisolated static let textFontSizes: [CGFloat] = [14, 18, 24, 32]
    nonisolated static let defaultTextFontSize: CGFloat = 18
    /// 文本排版宽度上限（编辑预览、光标定位、提交渲染共用，保证所见即所得）
    nonisolated static let textMaxWidth: CGFloat = 236

    /// 文本标注属性：编辑预览与提交渲染共用一份
    nonisolated static func textAttributes(colorIndex: Int, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: annotationPalette[colorIndex % max(annotationPalette.count, 1)]
        ]
    }

    /// 文本排版块尺寸。只做量测的入口，管线在函数内自持
    nonisolated static func textBlockSize(text: String, colorIndex: Int, fontSize: CGFloat,
                                     width: CGFloat = textMaxWidth) -> NSSize {
        makeOwningLayout(text: text, colorIndex: colorIndex, fontSize: fontSize, width: width).blockSize
    }

    /// 自持排版管线：容器宽 = textMaxWidth、行片填充 0，与隐藏输入框的布局约束完全一致。
    /// 容器内坐标 y 向下（TextKit 惯例），blockSize 即排版块尺寸。
    /// NSTextStorage 必须随返回值保活：TextKit1 的 NSLayoutManager 不强引用 storage
    /// （防循环保留），storage 释放即清字形缓存——此前返回值漏掉 storage，
    /// drawGlyphs 在调用侧静默画空（「文本标注不可见」根因，2026-11-02 实测定位）
    nonisolated static func makeOwningLayout(text: String, colorIndex: Int, fontSize: CGFloat,
                                        width: CGFloat = textMaxWidth)
        -> (storage: NSTextStorage, layoutManager: NSLayoutManager, container: NSTextContainer, blockSize: NSSize) {
        let storage = NSTextStorage(string: text, attributes: textAttributes(colorIndex: colorIndex, fontSize: fontSize))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return (storage, layoutManager, container, NSSize(width: ceil(used.maxX), height: ceil(used.maxY)))
    }
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
        selectionGesture = nil
        toolbarHoverZone = .outside
        annotations = []
        activeTool = nil
        drawingAnnotation = nil
        drawingStart = nil
        pixelatedImage = nil
        annotationColorIndex = Self.defaultAnnotationColorIndex
        annotationFontSize = Self.defaultTextFontSize
        editingTextIndex = nil
        textDrag = nil
        textHoverIndex = nil
        textDraft = nil
        lastCaretRect = nil
        unregisterUndoHotKey()
        unregisterColorHotKey()
        colorBadge = nil
        copiedClearTask?.cancel()
        copiedClearTask = nil
        toolbarModel = nil
        let mouse = NSEvent.mouseLocation
        targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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
        endTextEditing(commit: false)
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
        if ownsCursorStackEntry {
            NSCursor.pop()
            ownsCursorStackEntry = false
        }
        // 冻结帧是整屏解码位图（5K 屏 ~56MB），会话结束必须释放，不能等下次覆盖
        snapshotImage = nil
        pixelatedImage = nil
        overlayView?.clearContent()
        // 遮罩不跨截图会话复用，避免隐藏窗口残留的跟踪区域/光标矩形状态。
        overlayPanel?.contentView = nil
        overlayPanel?.close()
        overlayPanel = nil
        overlayView = nil
        if let previousApplication,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           !previousApplication.isTerminated {
            previousApplication.activate(options: [.activateIgnoringOtherApps])
        }
        previousApplication = nil
        annotations = []
        activeTool = nil
        drawingAnnotation = nil
        drawingStart = nil
        annotationColorIndex = Self.defaultAnnotationColorIndex
        colorBadge = nil
        textDrag = nil
        textHoverIndex = nil
        textDraft = nil
        lastCaretRect = nil
        toolbarModel = nil
        selectionRect = .zero
        dragStart = nil
        selectionGesture = nil
        toolbarHoverZone = .outside
        cachedToolbarSize = nil
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
        let view = OverlayContentView()
        view.configure(
            snapshotImage: image,
            pixelScale: pixelScale,
            dimAlpha: Self.dimAlpha,
            selectionProvider: { [weak self] in self?.selectionRect ?? .zero },
            pixelRectProvider: { [weak self] in self?.pixelRect(for: $0) },
            annotationState: { [weak self] in
                guard let self,
                      !self.annotations.isEmpty || self.drawingAnnotation != nil || self.textDraft != nil else { return nil }
                // 双击重编辑期间隐藏原文：避免与画布草稿叠成两份
                var committed = self.annotations.enumerated().compactMap { offset, element -> Annotation? in
                    offset == self.editingTextIndex ? nil : element
                }
                // 编辑中的草稿与已提交标注同路径渲染（所见即所得）
                if let draft = self.textDraft { committed.append(draft) }
                // 马赛克标注在场才生成/保留像素化帧（惰性）
                let needsMosaic = committed.contains { $0.kind == .mosaic }
                    || (self.drawingAnnotation?.kind == .mosaic)
                if needsMosaic { self.pixelatedFrameIfNeeded() }
                return AnnotationRenderState(
                    committed: committed,
                    drawing: self.drawingAnnotation,
                    pixelated: self.pixelatedImage,
                    palette: Self.annotationPalette
                )
            },
            onMouseDown: { [weak self] in self?.handleMouseDown($0, clickCount: $1) },
            onMouseDragged: { [weak self] in self?.handleMouseDragged($0) },
            onMouseUp: { [weak self] in self?.handleMouseUp($0) },
            onMouseMoved: { [weak self] in self?.handleMouseMoved($0) },
            onRightClick: { [weak self] in self?.cancel() },
            colorBadge: { [weak self] in self?.colorBadge },
            textEditing: { [weak self] in self?.currentTextEditingOverlay() },
            selectionHandles: { [weak self] in
                guard let self else { return false }
                return self.phase == .toolbar && self.activeTool == nil
            },
            cursor: { [weak self] in
                guard let self else { return .arrow }
                if self.phase == .selecting { return Self.crosshairCursor }
                // 工具栏期：文本拖拽/悬停 > 文本工具 I 形；无工具时调整手势与悬停区
                // 决定光标（缩放/开合手掌/箭头）
                guard self.phase == .toolbar else { return .arrow }
                if self.textDrag != nil { return .closedHand }
                if let tool = self.activeTool {
                    if self.textHoverIndex != nil { return .openHand }
                    return tool == .text && self.toolbarHoverZone == .inside ? NSCursor.iBeam : .arrow
                }
                if self.textHoverIndex != nil { return .openHand }
                if let gesture = self.selectionGesture {
                    switch gesture {
                    case .move: return .closedHand
                    case .resize(let edges, _): return Self.resizeCursor(for: edges)
                    }
                }
                switch self.toolbarHoverZone {
                case .inside: return .openHand
                case .border(let edges): return Self.resizeCursor(for: edges)
                case .outside: return .arrow
                }
            }
        )
        overlayView = view
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        // 非激活面板即使成为 key，应用自己的光标也可能被前台应用覆盖。
        // 冻结画面已抓取完才临时激活；退出后恢复原应用，不改变快照内容。
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        NSApp.activate(ignoringOtherApps: true)
        Self.crosshairCursor.push()
        ownsCursorStackEntry = true
        // 激活后的遮罩接收鼠标/光标事件，结束后由 dismiss 恢复原应用。
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // 首次呈现时同步绘制，避免窗口先显示空白内容。
        view.needsDisplay = true
        view.displayIfNeeded()
        // 光标矩形在窗口前置后不会自动刷新，主动失效一次让十字线立即生效
        view.updateTrackingAreas()
        panel.resetCursorRects()
        // 窗口出现时鼠标可能已在视图内，没有进入事件；立即应用一次。
        Self.crosshairCursor.set()
        phase = .selecting
        // makeKey/orderFront 后 AppKit 还会在本轮事件结束时重置指针；在下一轮补设，
        // 仅允许当前会话执行，防取消后或旧窗口的延迟回调把十字光标留在桌面。
        DispatchQueue.main.async { [weak self, weak panel, weak view] in
            guard let self, let panel, let view,
                  self.phase == .selecting, self.overlayPanel === panel,
                  self.overlayView === view, panel.isVisible,
                  panel.frame.contains(NSEvent.mouseLocation) else { return }
            panel.resetCursorRects()
            Self.crosshairCursor.set()
            HotkeyFileLog.shared.log("overlay: cursor ready key=\(panel.isKeyWindow) rects=\(panel.areCursorRectsEnabled)")
        }
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

    private func handleMouseDown(_ p: NSPoint, clickCount: Int) {
        // 工具栏期：激活了标注工具且点击在选区内 → 绘制；
        // 无工具时选区外空白 = 放弃当前选区整体退出（微信式）；
        // 选区内/边/角起调整手势（纯点击无位移 = 无操作，防手滑丢掉整场标注）
        if phase == .toolbar {
            // 先提交输入，再让同一次点击继续命中文本或创建下一段文字。
            if textEditor != nil {
                endTextEditing(commit: true)
            }
            if let tool = activeTool {
                // 工具激活期选区外点击忽略：防手一滑丢掉整个会话的标注
                guard selectionRect.contains(p) else { return }
                if tool == .text {
                    if clickCount >= 2, let index = textAnnotationIndex(at: p) {
                        beginTextEditing(existing: index)
                    } else if let index = textAnnotationIndex(at: p) {
                        // 按住已提交文本 = 拖拽移位
                        textDrag = (index, annotations[index].point, p)
                    } else {
                        beginTextEditing(anchor: p, initialText: "",
                                         fontSize: annotationFontSize,
                                         colorIndex: annotationColorIndex, editingIndex: nil)
                    }
                    return
                }
                beginAnnotation(tool, at: p)
                return
            }
            switch selectionZone(at: p) {
            case .border(let edges):
                selectionGesture = .resize(edges: edges, originalRect: selectionRect)
                HotkeyFileLog.shared.log("overlay: resize arm edges=\(edges.rawValue)")
            case .inside:
                if clickCount >= 2, let index = textAnnotationIndex(at: p) {
                    // 双击已提交文本：重编辑
                    beginTextEditing(existing: index)
                } else if let index = textAnnotationIndex(at: p) {
                    // 文本标注优先于整体移动：按住文本单独移位
                    textDrag = (index, annotations[index].point, p)
                } else {
                    selectionGesture = .move(originalRect: selectionRect, startPoint: p)
                    HotkeyFileLog.shared.log("overlay: move arm")
                }
            case .outside:
                cancel()
            }
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
        guard let view = overlayView else { return }
        // 工具栏期：更新悬停命中区驱动光标（文本工具也需要最新命中区切换 I 形/箭头）
        if phase == .toolbar {
            guard selectionGesture == nil, textDrag == nil else { return }
            toolbarHoverZone = selectionZone(at: p)
            textHoverIndex = (activeTool == nil || activeTool == .text) ? textAnnotationIndex(at: p) : nil
            return
        }
        guard phase == .selecting, dragStart == nil else { return }
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
        // 工具栏期：文本拖拽 > 标注绘制 > 选区调整（缩放/移动）
        if phase == .toolbar {
            if textDrag != nil {
                applyTextDrag(at: p)
                return
            }
            if activeTool != nil {
                updateAnnotation(at: p)
            } else {
                applySelectionGesture(at: p)
            }
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
        // 之后压暗已铺满屏，只有选区边缘在动，失效新旧并集即可——
        // 全幅重绘在 5K 屏单帧 ~56MB，60Hz 拖拽不可接受
        if old.isEmpty {
            view.needsDisplay = true
        } else {
            invalidateSelectionChange(old: old, new: selectionRect)
        }
    }

    private func handleMouseUp(_ p: NSPoint) {
        // 工具栏期：文本拖拽收尾；激活工具 = 标注落库；无工具 = 调整手势收尾（纯点击本就无位移 = 无操作）
        if phase == .toolbar {
            if textDrag != nil {
                applyTextDrag(at: p)
                textDrag = nil
                handleMouseMoved(p)
                HotkeyFileLog.shared.log("overlay: text drag done")
                return
            }
            if activeTool != nil {
                finishAnnotation(at: p)
            } else {
                finishSelectionGesture(at: p)
            }
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
        // 松手点就是工具栏期的首个悬停位置（在选区边缘，直接呈现缩放光标）
        toolbarHoverZone = selectionZone(at: p)
        enterToolbarPhase()
    }

    // MARK: - 工具栏期选区调整（缩放 / 移动）

    /// 光标处的选区命中区：角（8pt 方区，与手柄可视尺寸一致）优先，边（4pt 带）次之，
    /// 其余按 containment；对边同中的极小选区退化为内部移动，避免手势歧义
    private func selectionZone(at p: NSPoint) -> SelectionZone {
        let sel = selectionRect
        guard !sel.isEmpty else { return .outside }
        let cornerBand: CGFloat = 8
        let edgeBand: CGFloat = 4
        var edges: SelectionEdges = []
        if abs(p.x - sel.minX) <= cornerBand, abs(p.y - sel.minY) <= cornerBand { edges.insert(.minX); edges.insert(.minY) }
        if abs(p.x - sel.maxX) <= cornerBand, abs(p.y - sel.minY) <= cornerBand { edges.insert(.maxX); edges.insert(.minY) }
        if abs(p.x - sel.minX) <= cornerBand, abs(p.y - sel.maxY) <= cornerBand { edges.insert(.minX); edges.insert(.maxY) }
        if abs(p.x - sel.maxX) <= cornerBand, abs(p.y - sel.maxY) <= cornerBand { edges.insert(.maxX); edges.insert(.maxY) }
        if abs(p.x - sel.minX) <= edgeBand, p.y >= sel.minY, p.y <= sel.maxY { edges.insert(.minX) }
        if abs(p.x - sel.maxX) <= edgeBand, p.y >= sel.minY, p.y <= sel.maxY { edges.insert(.maxX) }
        if abs(p.y - sel.minY) <= edgeBand, p.x >= sel.minX, p.x <= sel.maxX { edges.insert(.minY) }
        if abs(p.y - sel.maxY) <= edgeBand, p.x >= sel.minX, p.x <= sel.maxX { edges.insert(.maxY) }
        if edges.contains(.minX) && edges.contains(.maxX) { return .inside }
        if edges.contains(.minY) && edges.contains(.maxY) { return .inside }
        if edges.isEmpty {
            return sel.contains(p) ? .inside : .outside
        }
        return .border(edges)
    }

    private func applySelectionGesture(at p: NSPoint) {
        guard let view = overlayView else { return }
        let old = selectionRect
        switch selectionGesture {
        case .move(let original, let start):
            var origin = NSPoint(x: original.minX + p.x - start.x, y: original.minY + p.y - start.y)
            origin.x = min(max(origin.x, view.bounds.minX), view.bounds.maxX - original.width)
            origin.y = min(max(origin.y, view.bounds.minY), view.bounds.maxY - original.height)
            let new = NSRect(origin: origin, size: original.size)
            guard new != old else { return }
            // 已画标注跟随平移（按实际生效位移算，含贴边截断；移动手势仅在无工具时存在，无绘制中标注）
            translateAnnotations(dx: new.minX - old.minX, dy: new.minY - old.minY)
            selectionRect = new
            invalidateSelectionChange(old: old, new: new)
            placeToolbar()
        case .resize(let edges, let original):
            // 被拖边夹在屏幕边界与对边（减最小边长）之间：不翻转、不小于最小选区
            var minX = original.minX, maxX = original.maxX
            var minY = original.minY, maxY = original.maxY
            let minSide = Self.minSelectionSide
            if edges.contains(.minX) { minX = min(max(p.x, view.bounds.minX), original.maxX - minSide) }
            if edges.contains(.maxX) { maxX = max(min(p.x, view.bounds.maxX), original.minX + minSide) }
            if edges.contains(.minY) { minY = min(max(p.y, view.bounds.minY), original.maxY - minSide) }
            if edges.contains(.maxY) { maxY = max(min(p.y, view.bounds.maxY), original.minY + minSide) }
            let new = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard new != old else { return }
            selectionRect = new
            invalidateSelectionChange(old: old, new: new)
            placeToolbar()
        case .none:
            break
        }
    }

    private func finishSelectionGesture(at p: NSPoint) {
        guard selectionGesture != nil else { return }
        selectionGesture = nil
        // 拖拽期间 hover 区不更新，按松手点重算，避免陈旧光标
        toolbarHoverZone = selectionZone(at: p)
        HotkeyFileLog.shared.log("overlay: adjust done sel=\(selectionRect)")
    }

    /// 移动选区时同步平移已提交标注（移动手势仅在无激活工具时存在）
    private func translateAnnotations(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        for index in annotations.indices {
            switch annotations[index].kind {
            case .pen:
                annotations[index].points = annotations[index].points.map {
                    NSPoint(x: $0.x + dx, y: $0.y + dy)
                }
            case .rect, .mosaic:
                annotations[index].rect = annotations[index].rect.offsetBy(dx: dx, dy: dy)
            case .text:
                annotations[index].point = NSPoint(x: annotations[index].point.x + dx,
                                                   y: annotations[index].point.y + dy)
            }
        }
    }

    /// 选区几何变化的最小失效区：新旧并集外扩（盖住边框、手柄与尺寸徽标）；
    /// 全幅重绘在 5K 屏单帧 ~56MB，拖拽 60Hz 下不可接受
    private func invalidateSelectionChange(old: NSRect, new: NSRect) {
        guard let view = overlayView else { return }
        let dirty = old.union(new).insetBy(dx: -24, dy: -56)
        view.setNeedsDisplay(view.bounds.intersection(dirty))
    }

    // MARK: - 工具栏

    private func enterToolbarPhase() {
        phase = .toolbar
        // 松手即恢复箭头，同时失效旧的十字光标矩形，避免移动后又被覆盖。
        if let overlayView {
            overlayPanel?.invalidateCursorRects(for: overlayView)
        }
        NSCursor.arrow.set()
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
            onPin: { [weak self] in self?.pinSelection() },
            onCancel: { [weak self] in self?.cancel() },
            onToggleTool: { [weak self] in self?.toggleTool($0) },
            onUndo: { [weak self] in self?.undoLastAnnotation() },
            onSetColor: { [weak self] in self?.setAnnotationColor($0) },
            onSetFontSize: { [weak self] in self?.setAnnotationFontSize($0) }
        )
        panel.contentView = NSHostingView(rootView: AnyView(view))
        panel.orderFrontRegardless()
        placeToolbar()
        HotkeyFileLog.shared.log("overlay: toolbar shown sel=\(selectionRect.size)")
    }

    /// 工具栏自然尺寸。零尺寸初始帧会让 SwiftUI HStack 进入压缩布局、fittingSize 量出
    /// 截断后的宽度——先给宽裕的临时帧再量，才能拿到文字完整展开的自然尺寸
    private func toolbarNaturalSize() -> NSSize {
        if let cached = cachedToolbarSize { return cached }
        guard let panel = toolbarPanel,
              let hosting = panel.contentView as? NSHostingView<AnyView> else {
            return NSSize(width: 160, height: 40)
        }
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 100))
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let size = NSSize(width: max(fit.width + 1, 150), height: max(fit.height, 32))
        cachedToolbarSize = size
        return size
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
        endTextEditing(commit: true)
        activeTool = (activeTool == tool) ? nil : tool
        drawingAnnotation = nil
        toolbarModel?.activeTool = activeTool
        // 激活笔迹类工具时色板展开/收起会改变工具栏宽度：失效尺寸缓存后重新测量摆放
        cachedToolbarSize = nil
        placeToolbar()
        HotkeyFileLog.shared.log("overlay: tool \(activeTool.map { "\($0)" } ?? "none")")
    }

    /// 选色只影响后续笔迹（历史笔迹保留各自颜色），布局不变无需重摆。
    /// 编辑中的新文本草稿实时换色；双击重编辑沿用原色号不受影响
    private func setAnnotationColor(_ index: Int) {
        guard Self.annotationPalette.indices.contains(index) else { return }
        annotationColorIndex = index
        toolbarModel?.colorIndex = index
        if textEditor != nil, editingTextIndex == nil {
            textDraftColorIndex = index
            refreshTextDraft()
        }
        overlayView?.setNeedsDisplay(selectionRect.insetBy(dx: -6, dy: -6))
    }

    /// 换字号只影响后续文本，布局不变无需重摆。编辑中的草稿与隐藏编辑器实时跟随：
    /// 两者字号不一致时画布文字按新字号排版、光标/换行仍按旧字号的布局算，会错位
    /// （重编辑也跟随——提交时本来就采用新字号，且编辑框 frame 由 refreshTextDraft 同步）
    private func setAnnotationFontSize(_ size: CGFloat) {
        guard ScreenshotOverlay.textFontSizes.contains(size) else { return }
        annotationFontSize = size
        toolbarModel?.fontSize = size
        if let editor = textEditor {
            editor.font = NSFont.systemFont(ofSize: size, weight: .regular)
            refreshTextDraft()
        }
    }

    // MARK: 文本标注

    /// 微信式文本编辑：文字直接渲染在画布上（与提交后同一排版路径，所见即所得），
    /// 光标自绘、编辑区用虚线边框标记；隐藏的 TextEditorView 只负责键盘/IME/撤销。
    /// Enter 换行、点击空白完成、Esc 丢弃、双击已提交文本可重编辑
    private func beginTextEditing(anchor rawAnchor: NSPoint, initialText: String,
                                  fontSize: CGFloat, colorIndex: Int, editingIndex: Int?,
                                  layoutWidth: CGFloat? = nil) {
        guard let view = overlayView else { return }
        endTextEditing(commit: true)
        textDrag = nil
        selectionGesture = nil
        drawingAnnotation = nil
        annotationFontSize = fontSize
        textLayoutWidth = max(1, min(layoutWidth ?? Self.textMaxWidth, selectionRect.width))
        textDraftColorIndex = colorIndex
        toolbarModel?.fontSize = fontSize
        // 鼠标 I 形光标的热点在中心；文本锚点却在块顶。新建时补上半行高度，
        // 使插入光标中心对准点击位置。重编辑直接沿用原锚点，避免每次编辑上移。
        let lineHeight = fontSize + 4
        let anchor = editingIndex == nil
            ? NSPoint(x: rawAnchor.x, y: rawAnchor.y + lineHeight / 2)
            : rawAnchor
        // 宽度取 0，避免窄选区将尚未输入的光标挤到左边；输入后再按实际块尺寸夹取。
        let p = clampedTextAnchor(anchor, size: NSSize(width: 0, height: lineHeight))
        textAnchor = p
        editingTextIndex = editingIndex
        let editor = TextEditorView(frame: NSRect(x: p.x, y: p.y - (fontSize + 4),
                                                  width: textLayoutWidth + 4, height: fontSize + 4))
        // 布局约束与画布排版（makeTextLayout）完全一致：容器宽/行片填充/零内边距
        editor.textContainerInset = .zero
        editor.textContainer?.containerSize = NSSize(width: textLayoutWidth,
                                                     height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.drawsBackground = false
        editor.wantsLayer = true
        editor.layer?.masksToBounds = true
        // 编辑框完全不可见：文字/光标由遮罩画布渲染，这里只做键盘与 IME 接管。
        // 字号必须与画布排版一致，光标定位/换行才对得上
        editor.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        editor.textColor = .clear
        editor.insertionPointColor = .clear
        editor.selectedTextAttributes = [:]
        editor.string = initialText
        editor.setSelectedRange(NSRange(location: (initialText as NSString).length, length: 0))
        editor.delegate = self
        editor.onCancel = { [weak self] in self?.endTextEditing(commit: false) }
        view.addSubview(editor)
        textEditor = editor
        if let idx = editingIndex, annotations.indices.contains(idx) {
            // 隐藏原文需主动失效其区域：旧像素不会自己消失
            overlayView?.setNeedsDisplay(annotationBounds(annotations[idx]).insetBy(dx: -8, dy: -8))
        }
        refreshTextDraft()
        // 文本编辑器接管键盘期间必须卸掉 Carbon Esc/⌘Z：热键抢在 IME 组合与文本撤销之前吃键
        unregisterEscHotKey()
        unregisterUndoHotKey()
        view.window?.makeFirstResponder(editor)
        HotkeyFileLog.shared.log("overlay: text editor spawn at (\(Int(p.x)), \(Int(p.y))) editing=\(editingIndex.map(String.init) ?? "new")")
    }

    /// 输入/光标变化 → 重画画布草稿与光标
    func textDidChange(_ notification: Notification) {
        refreshTextDraft()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshTextDraft()
    }

    /// 依据隐藏输入框的当前内容/选区刷新画布草稿与光标（失效旧新并集）。
    /// 锚点随当前块尺寸实时回夹：草稿增长越界时整体滑移保持可见（提交夹取成为无操作，
    /// 所见即所得不跳变）；高度兜底取 fontSize+4，空文本→首字符的块高跳变不牵动锚点
    private func refreshTextDraft() {
        guard let editor = textEditor else { return }
        let oldBounds = textDraft.map { annotationBounds($0).insetBy(dx: -8, dy: -8) }
        let oldCaret = lastCaretRect
        let draftSize = ScreenshotOverlay.textBlockSize(text: editor.string, colorIndex: textDraftColorIndex,
                                                        fontSize: annotationFontSize, width: textLayoutWidth)
        textAnchor = clampedTextAnchor(
            textAnchor,
            size: NSSize(width: draftSize.width, height: max(draftSize.height, annotationFontSize + 4)))
        let draft = Annotation(kind: .text, colorIndex: textDraftColorIndex,
                               text: editor.string, point: textAnchor,
                               fontSize: annotationFontSize, textWidth: textLayoutWidth)
        textDraft = draft
        // 编辑框顶边跟随回夹后的锚点：IME 候选窗定位走编辑框自身布局，不跟会漂移
        editor.frame = NSRect(x: textAnchor.x, y: textAnchor.y - (annotationFontSize + 4),
                              width: textLayoutWidth + 4, height: annotationFontSize + 4)
        lastCaretRect = currentTextCaretRect()?.rect
        var dirty = annotationBounds(draft).insetBy(dx: -8, dy: -8)
        if let oldBounds { dirty = dirty.union(oldBounds) }
        if let oldCaret { dirty = dirty.union(oldCaret.insetBy(dx: -8, dy: -8)) }
        if let caret = lastCaretRect { dirty = dirty.union(caret.insetBy(dx: -8, dy: -8)) }
        overlayView?.setNeedsDisplay(dirty)
    }

    /// 插入光标在遮罩视图坐标里的矩形（锚点 = 文本块左上角；容器内 y 向下）。
    /// 用自持 TextKit1 管线重排而不是编辑器的 layoutManager：Tahoe 上 NSTextView 是
    /// TextKit2 兼容 shim，字形 API 返回容器宽占位矩形（实测光标漂到全宽 236 处）；
    /// 纯文本单字体下两者几何一致（同容器宽/行片填充/字号），自持管线字形可靠
    private func currentTextCaretRect() -> (rect: NSRect, color: NSColor)? {
        guard let editor = textEditor else { return nil }
        let color = Self.annotationPalette[textDraftColorIndex % Self.annotationPalette.count]
        let nsText = editor.string as NSString
        let charIndex = min(editor.selectedRange().location, nsText.length)
        let lineHeight = annotationFontSize + 4
        let caret: NSRect
        if nsText.length == 0 {
            caret = NSRect(x: 0, y: 0, width: 1.5, height: lineHeight)
        } else {
            let layout = Self.makeOwningLayout(text: editor.string, colorIndex: textDraftColorIndex,
                                               fontSize: annotationFontSize, width: textLayoutWidth)
            defer { withExtendedLifetime(layout.storage) {} }
            let lm = layout.layoutManager
            if charIndex >= nsText.length, nsText.hasSuffix("\n") {
                // 行尾换行后的空新行：贴容器左缘，位于已排版块底部（usedRect 不含末尾空行）
                caret = NSRect(x: 0, y: layout.blockSize.height, width: 1.5, height: lineHeight)
            } else {
                let char = min(charIndex, nsText.length - 1)
                let glyph = min(lm.glyphIndexForCharacter(at: char), max(0, lm.numberOfGlyphs - 1))
                var lineRange = NSRange()
                let lineFragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                if charIndex >= nsText.length {
                    // 行尾插入：贴在本行右缘
                    let usedLine = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                    caret = NSRect(x: usedLine.maxX, y: lineFragment.minY,
                                   width: 1.5, height: lineFragment.height)
                } else {
                    let location = lm.location(forGlyphAt: glyph)
                    caret = NSRect(x: lineFragment.minX + location.x, y: lineFragment.minY,
                                   width: 1.5, height: lineFragment.height)
                }
            }
        }
        // 容器坐标（y 向下，原点块左上）→ 遮罩视图坐标（y 向上，原点 = textAnchor）
        return (NSRect(x: textAnchor.x + caret.minX, y: textAnchor.y - caret.maxY,
                       width: max(1.5, caret.width), height: caret.height), color)
    }

    /// 编辑中的画布覆盖物：光标矩形/颜色 + 虚线边框（遮罩视图坐标）
    private func currentTextEditingOverlay() -> (caret: NSRect, caretColor: NSColor, draftBorder: NSRect)? {
        guard textEditor != nil, let draft = textDraft, let view = overlayView else { return nil }
        guard let caret = currentTextCaretRect() else { return nil }
        // 空文本的排版块为零高；框住文字与插入光标的并集，空行、末尾换行也不越框。
        let border = annotationBounds(draft).union(caret.rect)
            .insetBy(dx: -5, dy: -4).intersection(view.bounds)
        guard !border.isEmpty else { return nil }
        return (caret.rect, caret.color, border)
    }

    /// 结束文本输入。commit=false 丢弃（Esc/会话关闭）；空的新文本视为误触不落库，
    /// 重编辑被清空 = 删除该标注；重编辑路径原地替换（保留色号），新文本用当前色号/字号落库
    private func endTextEditing(commit: Bool) {
        guard let editor = textEditor else { return }
        textEditor = nil
        editor.delegate = nil
        let text = editor.string
        let usedFontSize = annotationFontSize
        let anchorAtEdit = textAnchor
        let indexBeingEdited = editingTextIndex
        editingTextIndex = nil
        // 擦除草稿与光标
        if let draft = textDraft {
            overlayView?.setNeedsDisplay(annotationBounds(draft).insetBy(dx: -8, dy: -8))
        }
        if let caret = lastCaretRect {
            overlayView?.setNeedsDisplay(caret.insetBy(dx: -8, dy: -8))
        }
        textDraft = nil
        lastCaretRect = nil
        editor.removeFromSuperview()
        overlayPanel?.makeFirstResponder(overlayView)
        // 恢复键盘接管：Esc 常驻；⌘Z 保持懒注册语义（有可撤标注才接管）
        registerEscHotKey()
        if !annotations.isEmpty { registerUndoHotKey() }
        guard commit else {
            // 丢弃（含重编辑取消）：被隐藏的原文要画回来
            if let index = indexBeingEdited, annotations.indices.contains(index) {
                overlayView?.setNeedsDisplay(annotationBounds(annotations[index]).insetBy(dx: -8, dy: -8))
            }
            return
        }
        if text.isEmpty {
            // 空的新文本仍是误触不落库；重编辑被清空 = 删除该标注（删后下标位移，悬停命中一并作废）
            if let index = indexBeingEdited, annotations.indices.contains(index) {
                let old = annotationBounds(annotations[index])
                annotations.remove(at: index)
                textHoverIndex = nil
                if annotations.isEmpty {
                    unregisterUndoHotKey()
                    toolbarModel?.canUndo = false
                }
                overlayView?.setNeedsDisplay(old.insetBy(dx: -8, dy: -8))
                HotkeyFileLog.shared.log("overlay: text #\(index) removed (cleared)")
            }
            return
        }
        if let index = indexBeingEdited, annotations.indices.contains(index) {
            let old = annotationBounds(annotations[index])
            let newSize = ScreenshotOverlay.textBlockSize(text: text, colorIndex: annotations[index].colorIndex,
                                                          fontSize: usedFontSize, width: textLayoutWidth)
            annotations[index].text = text
            annotations[index].fontSize = usedFontSize
            annotations[index].textWidth = textLayoutWidth
            annotations[index].point = clampedTextAnchor(anchorAtEdit, size: newSize)
            invalidateAnnotationChange(oldB: old, newB: annotationBounds(annotations[index]))
            HotkeyFileLog.shared.log("overlay: text re-edited #\(index) (\(text.count) chars)")
        } else {
            // 按最终文本尺寸夹回选区（渲染会裁剪在选区内，编辑预览不会——不夹则贴边时首行被裁）
            let newSize = ScreenshotOverlay.textBlockSize(text: text, colorIndex: annotationColorIndex,
                                                          fontSize: usedFontSize, width: textLayoutWidth)
            let anchor = clampedTextAnchor(anchorAtEdit, size: newSize)
            let annotation = Annotation(kind: .text, colorIndex: annotationColorIndex,
                                        text: text, point: anchor, fontSize: usedFontSize, textWidth: textLayoutWidth)
            annotations.append(annotation)
            if annotations.count == 1 { registerUndoHotKey() }
            toolbarModel?.canUndo = true
            overlayView?.setNeedsDisplay(annotationBounds(annotation).insetBy(dx: -8, dy: -8))
            HotkeyFileLog.shared.log("overlay: text committed (\(text.count) chars)")
        }
    }

    /// 双击重编辑：编辑框回到原文位置，预填内容并沿用原字号/色号
    private func beginTextEditing(existing index: Int) {
        guard annotations.indices.contains(index) else { return }
        let annotation = annotations[index]
        beginTextEditing(anchor: annotation.point, initialText: annotation.text,
                         fontSize: annotation.fontSize, colorIndex: annotation.colorIndex,
                         editingIndex: index, layoutWidth: annotation.textWidth)
    }

    /// 文本框（锚点 = 左上角，向下延展）尽量夹进选区：保证首行不被选区上缘裁掉；
    /// 文本大于选区时退化为贴左/贴上
    private func clampedTextAnchor(_ p: NSPoint, size: NSSize) -> NSPoint {
        let sel = selectionRect
        let x = min(max(p.x, sel.minX), max(sel.minX, sel.maxX - size.width))
        let y = min(max(p.y, sel.minY + size.height), max(sel.minY + size.height, sel.maxY))
        return NSPoint(x: x, y: y)
    }

    /// 最上层命中的文本标注下标（4pt 抓取余量）；未命中返回 nil
    private func textAnnotationIndex(at p: NSPoint) -> Int? {
        for (index, a) in annotations.enumerated().reversed() where a.kind == .text {
            if annotationBounds(a).insetBy(dx: -4, dy: -4).contains(p) { return index }
        }
        return nil
    }

    /// 文本标注拖拽中：按位移增量移动（original + delta），文本框尽量留在选区内
    private func applyTextDrag(at p: NSPoint) {
        guard let drag = textDrag, annotations.indices.contains(drag.index) else { return }
        let old = annotationBounds(annotations[drag.index])
        let dx = p.x - drag.start.x, dy = p.y - drag.start.y
        annotations[drag.index].point = clampedTextAnchor(
            NSPoint(x: drag.original.x + dx, y: drag.original.y + dy), size: old.size)
        invalidateAnnotationChange(oldB: old, newB: annotationBounds(annotations[drag.index]))
    }

    private func beginAnnotation(_ tool: AnnotationTool, at rawPoint: NSPoint) {
        let p = clampedToSelection(rawPoint)
        drawingStart = p
        switch tool {
        case .pen: drawingAnnotation = Annotation(kind: .pen, points: [p], colorIndex: annotationColorIndex)
        case .rect: drawingAnnotation = Annotation(kind: .rect, rect: NSRect(origin: p, size: .zero), colorIndex: annotationColorIndex)
        case .mosaic: drawingAnnotation = Annotation(kind: .mosaic, rect: NSRect(origin: p, size: .zero))
        case .text: break  // 文本不走拖拽绘制，mouseDown 里单独走输入框路径
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
        case .text:
            return
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
        case .text:
            return
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
        case .text:
            let size = ScreenshotOverlay.textBlockSize(text: a.text, colorIndex: a.colorIndex, fontSize: a.fontSize, width: a.textWidth)
            // 锚点是文本块左上角，块体向下延展（Cocoa y 轴向上）
            return NSRect(x: a.point.x, y: a.point.y - size.height,
                          width: size.width, height: size.height)
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
        // 复制/保存带标注（烘焙失败兜底干净图，不因标注丢功能）；正在输入的文本先落库
        endTextEditing(commit: true)
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

    private func pinSelection() {
        guard phase == .toolbar else { return }
        endTextEditing(commit: true)
        let frame = globalSelectionRect()
        guard let image = annotatedSelectionImage() ?? croppedSelectionImage() else {
            dismiss()
            ScreenshotOCRPanel.feedback.presentFailure("无法创建钉图，请重新截图", near: frame.origin, title: "截图")
            return
        }
        dismiss()
        guard PinnedScreenshotManager.shared.pin(image, at: frame) != nil else {
            ScreenshotOCRPanel.feedback.presentFailure("无法创建钉图，请重试", near: frame.origin, title: "截图")
            return
        }
        HotkeyFileLog.shared.log("overlay: pinned screenshot")
    }

    private func saveToDesktop() {
        endTextEditing(commit: true)
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

    /// Carbon ⌘Z（id=6）派发入口。绘制中或选区调整中忽略：撤销失效区按当前选区算，
    /// 手势拖动中的标注旧位置可能已在失效区外，会留鬼影
    func handleUndoHotKey() {
        guard phase == .toolbar, !annotations.isEmpty, drawingAnnotation == nil,
              selectionGesture == nil else { return }
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

    private func ensureOverlayPanel() -> OverlayPanel {
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
        panel.isReleasedWhenClosed = false
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
        let image = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 10, y: 2))
            path.line(to: NSPoint(x: 10, y: 18))
            path.move(to: NSPoint(x: 2, y: 10))
            path.line(to: NSPoint(x: 18, y: 10))
            // 白色主体 + 半点黑边，避免原来 1pt 白核被粗黑线盖过视觉重心。
            path.lineWidth = 3
            NSColor.black.setStroke()
            path.stroke()
            path.lineWidth = 2
            NSColor.white.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    /// 斜向缩放光标：系统只提供横竖向，对角双箭头自绘（黑边白芯同十字线套路）
    static let diagonalSlashCursor = makeDiagonalResizeCursor(arrowUpRight: true)
    static let diagonalBackslashCursor = makeDiagonalResizeCursor(arrowUpRight: false)

    /// 边集 → 缩放光标。斜向轴：minX+minY / maxX+maxY 角走「/」，另两角走「\」
    private static func resizeCursor(for edges: SelectionEdges) -> NSCursor {
        let horizontal = edges.contains(.minX) || edges.contains(.maxX)
        let vertical = edges.contains(.minY) || edges.contains(.maxY)
        switch (horizontal, vertical) {
        case (true, false):
            return .resizeLeftRight
        case (false, true):
            return .resizeUpDown
        case (true, true):
            let slash = (edges.contains(.minX) && edges.contains(.minY))
                || (edges.contains(.maxX) && edges.contains(.maxY))
            return slash ? diagonalSlashCursor : diagonalBackslashCursor
        default:
            return .arrow
        }
    }

    private static func makeDiagonalResizeCursor(arrowUpRight: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if arrowUpRight {
                // 「/」轴：↗↙ 双向箭头（Cocoa y 轴向上）
                path.move(to: NSPoint(x: 5.5, y: 5.5))
                path.line(to: NSPoint(x: 15.5, y: 15.5))
                path.move(to: NSPoint(x: 10.5, y: 15.5))
                path.line(to: NSPoint(x: 15.5, y: 15.5))
                path.line(to: NSPoint(x: 15.5, y: 10.5))
                path.move(to: NSPoint(x: 10.5, y: 5.5))
                path.line(to: NSPoint(x: 5.5, y: 5.5))
                path.line(to: NSPoint(x: 5.5, y: 10.5))
            } else {
                // 「\」轴：↘↖ 双向箭头
                path.move(to: NSPoint(x: 5.5, y: 15.5))
                path.line(to: NSPoint(x: 15.5, y: 5.5))
                path.move(to: NSPoint(x: 10.5, y: 5.5))
                path.line(to: NSPoint(x: 15.5, y: 5.5))
                path.line(to: NSPoint(x: 15.5, y: 10.5))
                path.move(to: NSPoint(x: 10.5, y: 15.5))
                path.line(to: NSPoint(x: 5.5, y: 15.5))
                path.line(to: NSPoint(x: 5.5, y: 10.5))
            }
            path.lineWidth = 4
            NSColor.black.setStroke()
            path.stroke()
            path.lineWidth = 2
            NSColor.white.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return NSCursor(image: image, hotSpot: NSPoint(x: 10.5, y: 10.5))
    }
}

// MARK: - 遮罩窗口（borderless 面板默认不能成为 key——不重写就永远拿不到指针控制权）

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 文本标注编辑框：完全不可见的多行 NSTextView（Enter 换行），只负责键盘/IME/撤销；Esc 丢弃。
/// 不可见所以不参与命中测试——命中区域（宽 240pt、高一行）会吞掉画布点击，让
/// 「点空白完成」失效且隐形光标乱跳；键盘事件只依赖 first responder，不受 hitTest 影响
private final class TextEditorView: NSTextView {
    var onCancel: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // kVK_Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
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
    case .text:
        // TextKit 在左上原点、y 向下的局部坐标中绘制。显式绑定目标 CGContext，
        // 让画布预览与复制/保存的离屏位图使用同一个绘制入口。
        let layout = ScreenshotOverlay.makeOwningLayout(text: annotation.text,
                                                        colorIndex: annotation.colorIndex,
                                                        fontSize: annotation.fontSize, width: annotation.textWidth)
        ctx.saveGState()
        ctx.translateBy(x: annotation.point.x, y: annotation.point.y)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        // NSLayoutManager 不强持有 storage，优化构建也必须保活到绘制结束。
        withExtendedLifetime(layout.storage) {
            layout.layoutManager.drawGlyphs(
                forGlyphRange: NSRange(location: 0, length: layout.layoutManager.numberOfGlyphs), at: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

// MARK: - 遮罩内容视图（NSView 自绘：冻结帧 + 压暗 + 选区高亮 + 尺寸提示）

private final class OverlayContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
    private var snapshotImage: CGImage?
    private var pixelScale: CGFloat = 1
    private var dimAlpha: CGFloat = 0.28
    /// 选区不归视图持有——overlay 是唯一事实源，draw 时经 provider 读取
    private var selectionProvider: (() -> NSRect)?
    /// 选区 → 冻结帧像素矩形，同样由 overlay 注入唯一实现
    private var pixelRectProvider: ((NSRect) -> CGRect?)?
    /// 标注渲染状态（committed + 绘制中 + 马赛克帧 + 颜色），无标注时返回 nil 跳过绘制
    private var annotationStateProvider: (() -> AnnotationRenderState?)?
    private var onMouseDown: ((NSPoint, Int) -> Void)?
    private var onMouseDragged: ((NSPoint) -> Void)?
    private var onMouseUp: ((NSPoint) -> Void)?
    private var onMouseMoved: ((NSPoint) -> Void)?
    private var onRightClick: (() -> Void)?
    private var colorBadgeProvider: (() -> ColorBadge?)?
    /// 文本编辑中的画布覆盖物（光标 + 虚线框），nil = 未在编辑
    private var textEditingProvider: (() -> (caret: NSRect, caretColor: NSColor, draftBorder: NSRect)?)?
    /// 工具栏期（无激活工具）才画 8 个调整手柄
    private var selectionHandlesProvider: (() -> Bool)?
    private var cursorProvider: (() -> NSCursor)?
    private var currentCursor: NSCursor { cursorProvider?() ?? .arrow }

    func configure(snapshotImage: CGImage, pixelScale: CGFloat, dimAlpha: CGFloat,
                   selectionProvider: @escaping () -> NSRect,
                   pixelRectProvider: @escaping (NSRect) -> CGRect?,
                   annotationState: @escaping () -> AnnotationRenderState?,
                   onMouseDown: @escaping (NSPoint, Int) -> Void,
                   onMouseDragged: @escaping (NSPoint) -> Void,
                   onMouseUp: @escaping (NSPoint) -> Void,
                   onMouseMoved: @escaping (NSPoint) -> Void,
                   onRightClick: @escaping () -> Void,
                   colorBadge: @escaping () -> ColorBadge?,
                   textEditing: @escaping () -> (caret: NSRect, caretColor: NSColor, draftBorder: NSRect)?,
                   selectionHandles: @escaping () -> Bool,
                   cursor: @escaping () -> NSCursor) {
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
        self.textEditingProvider = textEditing
        self.selectionHandlesProvider = selectionHandles
        self.cursorProvider = cursor
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
        // ③⅔ 文本编辑中：光标与虚线编辑框（草稿文字已并入标注渲染）
        if let editing = textEditingProvider?() {
            ctx.saveGState()
            ctx.clip(to: sel)
            ctx.setFillColor(editing.caretColor.cgColor)
            ctx.fill(editing.caret)
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.setLineWidth(1)
            ctx.stroke(editing.draftBorder)
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
            // ④½ 工具栏期（无激活工具）画 8 个调整手柄，提示边/角可拖拽
            if selectionHandlesProvider?() == true {
                drawSelectionHandles(for: sel)
            }
            // ⑤ 尺寸提示：选区下方 8pt 的黑底白字胶囊，贴底翻上方
            drawSizeBadge(for: sel)
        }
    }

    /// 选区调整手柄：4 角 + 4 边中点，白底黑描边（深浅底都可见），与命中区视觉呼应
    private func drawSelectionHandles(for sel: NSRect) {
        let side: CGFloat = 8
        let midX = sel.midX, midY = sel.midY
        let points = [
            NSPoint(x: sel.minX, y: sel.minY), NSPoint(x: sel.maxX, y: sel.minY),
            NSPoint(x: sel.minX, y: sel.maxY), NSPoint(x: sel.maxX, y: sel.maxY),
            NSPoint(x: midX, y: sel.minY), NSPoint(x: midX, y: sel.maxY),
            NSPoint(x: sel.minX, y: midY), NSPoint(x: sel.maxX, y: midY)
        ]
        for point in points {
            let rect = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.95).setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
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
        currentCursor.set()
        onMouseDown?(convert(event.locationInWindow, from: nil), event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        currentCursor.set()
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        currentCursor.set()
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        currentCursor.set()
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    /// activeAlways 与 cursorUpdate 不能组合：AppKit 在该组合下不派发 cursorUpdate。
    /// 始终跟踪移动/进入，光标更新单独随 key window 跟踪。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["cursor"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
            owner: self,
            userInfo: ["cursor": true]
        ))
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: ["cursor": true]
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        currentCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        currentCursor.set()
    }
}

// MARK: - 选区工具栏

/// 图标按钮悬停淡底：纯视觉反馈，不改布局尺寸
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                }
            }
            .onHover { hovering = $0 }
    }
}

/// 工具栏按钮态。@Observable 原地更新（无闪烁、无 fittingSize 重测竞态）；
/// overlay 自身字段仍是唯一事实源，model 只是视图投影
@MainActor
@Observable
private final class ToolbarModel {
    var activeTool: AnnotationTool?
    var canUndo = false
    var colorIndex = ScreenshotOverlay.defaultAnnotationColorIndex
    var fontSize = ScreenshotOverlay.defaultTextFontSize
}

private struct ToolbarView: View {
    let model: ToolbarModel
    let onOCR: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onCancel: () -> Void
    let onToggleTool: (AnnotationTool) -> Void
    let onUndo: () -> Void
    let onSetColor: (Int) -> Void
    let onSetFontSize: (CGFloat) -> Void

    /// 笔迹类工具激活时展开色板（马赛克无颜色概念；文本用当前色着色）
    private var showsColorSwatches: Bool {
        model.activeTool == .pen || model.activeTool == .rect || model.activeTool == .text
    }

    var body: some View {
        HStack(spacing: 2) {
            toolButton("画笔", "pencil.tip", .pen)
            toolButton("矩形", "rectangle", .rect)
            toolButton("马赛克", "square.grid.3x3", .mosaic)
            toolButton("文本", "character.textbox", .text, character: "T")
            if showsColorSwatches {
                Divider().frame(height: 16)
                ForEach(ScreenshotOverlay.annotationPalette.indices, id: \.self) { index in
                    swatch(index: index)
                }
            }
            if model.activeTool == .text {
                Divider().frame(height: 16)
                ForEach(ScreenshotOverlay.textFontSizes, id: \.self) { size in
                    fontSizeButton(size)
                }
            }
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.canUndo ? .primary : .tertiary)
                    .frame(width: 26, height: 26)
                    .modifier(HoverHighlight())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .help("撤销标注（⌘Z）")
            .accessibilityLabel("撤销标注")
            Divider().frame(height: 16)
            button("关闭", systemImage: "xmark", action: onCancel, help: "关闭（Esc）")
            button("文字识别", systemImage: "text.viewfinder", action: onOCR)
            button("钉住", systemImage: "pin", action: onPin,
                   help: "将截图钉在屏幕上，可拖动或缩放")
            button("保存", systemImage: "arrow.down.doc", action: onSave,
                   help: "保存到桌面（按住 ⌥ 点击可选择位置）")
            button("复制", systemImage: "doc.on.doc", action: onCopy)
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

    private func toolButton(_ title: String, _ systemImage: String, _ tool: AnnotationTool, character: String? = nil) -> some View {
        ToolIconButton(title: title, systemImage: systemImage, character: character, active: model.activeTool == tool) {
            onToggleTool(tool)
        }
    }

    /// 动作按钮：纯图标（文字只在 help 与辅助功能里），悬停为 26×26 圆角正方形
    private func button(_ title: String, systemImage: String, action: @escaping () -> Void, help: String? = nil) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .modifier(HoverHighlight())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityLabel(title)
    }

    /// 色板圆点：选中态放大 + 白圈/深圈双环描边，压暗底和亮底都可见
    private func swatch(index: Int) -> some View {
        let color = ScreenshotOverlay.annotationPalette[index]
        let selected = model.colorIndex == index
        return Button {
            onSetColor(index)
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: selected ? 16 : 12, height: selected ? 16 : 12)
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

    /// 字号档位按钮：选中态 accent 底 + 白字，与工具按钮同语言
    private func fontSizeButton(_ size: CGFloat) -> some View {
        let selected = model.fontSize == size
        return Button {
            onSetFontSize(size)
        } label: {
            Text("\(Int(size))")
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
                .modifier(HoverHighlight())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("字号 \(Int(size))")
        .accessibilityLabel("字号 \(Int(size))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 标注工具按钮：图标态，激活时 accent 圆角底 + 白图标，悬停淡底。
    /// character 非 nil 时以该字符替代 SF Symbol（文本工具用 T 字，与主流截图工具一致）
    private struct ToolIconButton: View {
        let title: String
        let systemImage: String
        var character: String? = nil
        let active: Bool
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                Group {
                    if let character {
                        Text(character)
                            .font(.system(size: 15, weight: .medium))
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(active ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(active ? .isSelected : [])
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - 文本标注渲染自测（SOUNDIN_TEXT_SELFTEST=1 随启动执行一次）
// 背景：drawGlyphs 在裸 CGContext（烘焙路径）实测静默不画且破坏上下文状态；
// 编辑期画布路径是否正常需真实证据。此钩子用合成冻结帧驱动完整流程，每步同时抓
// CGWindowListCreateImage（窗口真实合成帧 ≈ 用户所见）与 cacheDisplay（视图重渲染）。
extension ScreenshotOverlay {
    func runTextSelfTest() {
        let dir = URL(fileURLWithPath: "/tmp/soundin-selftest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ── 字形诊断：验证"应用进程内 makeTextLayout 零字形"假设，并逐个试绕法
        do {
            let text = "你好abc"
            let attrs = Self.textAttributes(colorIndex: 0, fontSize: 18)
            let storage = NSTextStorage(string: text, attributes: attrs)
            let lm = NSLayoutManager()
            storage.addLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: Self.textMaxWidth, height: CGFloat.greatestFiniteMagnitude))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            HotkeyFileLog.shared.log("diag1: glyphs=\(lm.numberOfGlyphs) used=\(used.width)x\(used.height) utf16=\((text as NSString).length)")
            let layout1 = Self.makeOwningLayout(text: text, colorIndex: 0, fontSize: 18)
            HotkeyFileLog.shared.log("diag2 makeOwningLayout: glyphs=\(layout1.layoutManager.numberOfGlyphs) blockSize=\(layout1.blockSize)")

            // 绕法 B：glyphRange(forCharacterRange:) 显式字形范围
            let storage3 = NSTextStorage(string: text, attributes: attrs)
            let lm3 = NSLayoutManager()
            storage3.addLayoutManager(lm3)
            let tc3 = NSTextContainer(size: NSSize(width: Self.textMaxWidth, height: CGFloat.greatestFiniteMagnitude))
            tc3.lineFragmentPadding = 0
            lm3.addTextContainer(tc3)
            let charRange = NSRange(location: 0, length: (text as NSString).length)
            let glyphRange = lm3.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            HotkeyFileLog.shared.log("diag3 glyphRange: glyphs=\(glyphRange.length) numberOfGlyphs=\(lm3.numberOfGlyphs)")

            // 各管线把文字画进裸位图数暗像素（systemRed vs black、glyphRange 显式 vs numberOfGlyphs）
            func pixelCount(lm: NSLayoutManager, range: NSRange, red: Bool, label: String) {
                let W = 300, H = 100
                guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      let data = ctx.data else { return }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                lm.drawGlyphs(forGlyphRange: range, at: NSPoint(x: 20, y: 30))
                NSGraphicsContext.restoreGraphicsState()
                let bytes = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
                var dark = 0
                for i in stride(from: 0, to: W * H * 4, by: 8) {
                    if Int(bytes[i]) < 160 && Int(bytes[i+1]) < 160 && Int(bytes[i+2]) < 160 { dark += 1 }
                }
                HotkeyFileLog.shared.log("diag5 \(label): darkPx=\(dark)")
            }
            // diag1 的管线（可能零字形）
            pixelCount(lm: lm, range: NSRange(location: 0, length: lm.numberOfGlyphs), red: false, label: "diag1管线+numberOfGlyphs范围")
            // lm3（glyphRange 生成）
            pixelCount(lm: lm3, range: NSRange(location: 0, length: lm3.numberOfGlyphs), red: false, label: "lm3+glyphs范围")
            // 黑色对照
            let storageB = NSTextStorage(string: "hello", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            let lmB = NSLayoutManager()
            storageB.addLayoutManager(lmB)
            let tcB = NSTextContainer(size: NSSize(width: 236, height: CGFloat.greatestFiniteMagnitude))
            tcB.lineFragmentPadding = 0
            lmB.addTextContainer(tcB)
            lmB.ensureLayout(for: tcB)
            HotkeyFileLog.shared.log("diag6 black管线: glyphs=\(lmB.numberOfGlyphs)")
            pixelCount(lm: lmB, range: NSRange(location: 0, length: lmB.numberOfGlyphs), red: false, label: "black管线")
        }

        // 合成冻结帧：浅灰底 + 顶部色带（scale 1 → pixelScale = 1）
        guard let screen = NSScreen.main,
              let ctx = CGContext(
                data: nil, width: Int(screen.frame.width), height: Int(screen.frame.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let synthetic = ctx.makeImage() else {
            HotkeyFileLog.shared.log("selftest: synthetic frame failed")
            exit(1)
        }
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: synthetic.width, height: synthetic.height))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: synthetic.height - 60, width: synthetic.width, height: 60))
        guard let synthetic = ctx.makeImage() else { exit(1) }

        targetScreen = screen
        presentOverlay(image: synthetic)
        selectionRect = NSRect(x: 150, y: 200, width: 500, height: 400)
        enterToolbarPhase()
        toggleTool(.text)
        stepCapture("01-toolbar", dir: dir)

        let click = NSPoint(x: 400, y: 420)
        beginTextEditing(anchor: click, initialText: "", fontSize: 18, colorIndex: 0, editingIndex: nil)
        HotkeyFileLog.shared.log("selftest: click=(400,420) anchor=(\(textAnchor.x),\(textAnchor.y))")
        stepCapture("02-caret-empty", dir: dir)

        textEditor?.insertText("你好abc")
        HotkeyFileLog.shared.log("selftest: draft anchor=(\(textAnchor.x),\(textAnchor.y)) caret=\(String(describing: lastCaretRect)) draftBounds=\(String(describing: textDraft.map { annotationBounds($0) }))")
        stepCapture("03-draft", dir: dir)

        endTextEditing(commit: true)
        stepCapture("04-committed", dir: dir)

        if let baked = annotatedSelectionImage(), let rep = NSBitmapImageRep(cgImage: baked).representation(using: .png, properties: [:]) {
            try? rep.write(to: dir.appendingPathComponent("05-baked.png"))
        }

        // 窄选区：点击右缘 (260,260)，锚点应留在点击处（宽度 0 夹取语义）
        selectionRect = NSRect(x: 150, y: 200, width: 150, height: 120)
        beginTextEditing(anchor: NSPoint(x: 260, y: 260), initialText: "", fontSize: 18, colorIndex: 0, editingIndex: nil)
        textEditor?.insertText("窄区文字")
        HotkeyFileLog.shared.log("selftest narrow: click=(260,260) anchor=(\(textAnchor.x),\(textAnchor.y))")
        stepCapture("06-narrow-draft", dir: dir)
        endTextEditing(commit: true)
        stepCapture("07-narrow-committed", dir: dir)

        // 交互回归：同一次点击提交并新建/拖动，松手应用最后位移，双击重编辑可取消。
        annotations.removeAll()
        selectionRect = NSRect(x: 150, y: 200, width: 500, height: 400)
        let first = NSPoint(x: 230, y: 480)
        let second = NSPoint(x: 440, y: 340)
        for size in Self.textFontSizes {
            beginTextEditing(anchor: first, initialText: "", fontSize: size, colorIndex: 0, editingIndex: nil)
            precondition(abs((lastCaretRect?.midY ?? .infinity) - first.y) < 0.01)
            let emptyOverlay = currentTextEditingOverlay()!
            precondition(emptyOverlay.draftBorder.contains(emptyOverlay.caret.insetBy(dx: -1, dy: -1)))
            textEditor?.insertText("中文abc")
            precondition(abs((lastCaretRect?.midY ?? .infinity) - first.y) <= 1.5)
            textEditor?.insertText("\n")
            let newlineOverlay = currentTextEditingOverlay()!
            precondition(newlineOverlay.draftBorder.contains(newlineOverlay.caret.insetBy(dx: -1, dy: -1)))
            endTextEditing(commit: false)
        }
        annotationFontSize = Self.defaultTextFontSize
        handleMouseDown(first, clickCount: 1)
        precondition(abs((lastCaretRect?.midY ?? .infinity) - first.y) < 0.01)
        textEditor?.insertText("第一段中文\nSecond line")
        let firstAnchor = textAnchor
        precondition(textDraft?.text.isEmpty == false)
        precondition((lastCaretRect?.minX ?? .infinity) < first.x + Self.textMaxWidth)
        handleMouseDown(second, clickCount: 1)
        precondition(annotations.count == 1 && textEditor != nil)
        textEditor?.insertText("第二段文字")
        let secondAnchor = textAnchor
        let hit = NSPoint(x: firstAnchor.x + 12, y: firstAnchor.y - 12)
        handleMouseDown(hit, clickCount: 1)
        precondition(annotations.count == 2 && textDrag?.index == 0)
        handleMouseDragged(NSPoint(x: hit.x + 30, y: hit.y - 20))
        handleMouseUp(NSPoint(x: hit.x + 55, y: hit.y - 35))
        precondition(annotations[0].point == NSPoint(x: firstAnchor.x + 55, y: firstAnchor.y - 35))
        precondition(annotations[1].point == secondAnchor && textDrag == nil)
        let moved = annotations[0].point
        handleMouseDown(NSPoint(x: moved.x + 12, y: moved.y - 12), clickCount: 2)
        precondition(editingTextIndex == 0 && textEditor?.string == annotations[0].text)
        precondition(textAnchor == moved)
        endTextEditing(commit: false)
        precondition(annotations.count == 2 && annotations[0].point == moved)
        stepCapture("08-interaction-regression", dir: dir)
        if let image = annotatedSelectionImage() {
            writePNG(NSBitmapImageRep(cgImage: image), "09-interaction-baked", dir: dir)
        }
        try? "PASS: caret centered on click at all font sizes, no re-edit drift, consecutive text creation, multiline caret, commit-and-drag, final mouse-up position, independent texts, re-edit cancellation\n"
            .write(to: dir.appendingPathComponent("interaction-result.txt"), atomically: true, encoding: .utf8)

        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    private func stepCapture(_ name: String, dir: URL) {
        guard let panel = overlayPanel, let view = overlayView else { return }
        view.needsDisplay = true
        view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        // ① 窗口真实合成帧（≈用户所见）：CGWindowListCreateImage 在新 SDK 已移除，走 screencapture CLI
        let windowShot = dir.appendingPathComponent("\(name)-window.png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-o", "-l\(panel.windowNumber)", windowShot.path]
        try? proc.run()
        proc.waitUntilExit()
        // ② 视图重渲染帧（绕过窗口合成，直接走 draw() → 位图）
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            writePNG(rep, "\(name)-redraw", dir: dir)
        }
    }

    private func writePNG(_ rep: NSBitmapImageRep, _ name: String, dir: URL) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
