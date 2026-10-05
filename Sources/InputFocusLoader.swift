import AppKit
import SwiftUI
import ApplicationServices

// MARK: - 连击翻译的输入框 loading 指示
// 翻译请求进行期间，在目标应用的焦点输入框下方浮一个小胶囊，里面三个白点波浪跳动。
// 动机：底部胶囊 HUD 只在录音会话残留时才可见，直接选中文本敲三下空格触发的翻译
// 从触发到译文落地（常 1~3 秒）之间没有任何可见反馈；这个指示器把「正在翻译」落在
// 用户视线正盯着的位置——输入框本身。
//
// 实现：AX 读焦点元素的 kAXPosition/kAXSize，用无边框透明 NSPanel 盖上去。
// 面板点击穿透、不激活、canJoinAllSpaces（全屏空间经 fullScreenAuxiliary 也能显示），
// 动画用 TimelineView 固定 30fps 驱动（模式与录音声波 PERF-8 一致，120Hz 屏不重绘拉满）。
// 输入框贴近视图区底部时自动翻到输入框上方，避免被 Dock 挡住。

@MainActor
final class InputFocusLoader {
    static let shared = InputFocusLoader()
    private init() {}

    private var panel: NSPanel?
    /// 显示代际：show / hide 各递增一次，在途淡出动画的完成回调据此失效（模式同 VoiceInputHUDManager）
    private var generation = 0

    /// 指示器与输入框边缘的间距
    static let gap: CGFloat = 8

    // MARK: - 对外接口

    /// 在焦点元素附近显示 loading。element 传 nil（终端等不暴露 AX 的应用）时静默跳过，翻译照常。
    /// 元素由调用方解析传入：performTranslate 读原文时已查过一次焦点元素，
    /// 这里再查是重复的 AX 往返（Electron 冷路径一次可阻塞主线程 ~1s）。
    func show(element: AXUIElement?) {
        guard let element else {
            HotkeyFileLog.shared.log("loader: no focused element — skip")
            return
        }
        guard let (anchorFrame, anchorMode) = Self.focusAnchorFrame(element: element) else {
            HotkeyFileLog.shared.log("loader: focused element has no frame — skip")
            return
        }

        generation += 1
        let panel = ensurePanel()

        // 默认放锚点正下方；贴近所在屏可视区底部时翻到上方。
        // 锚点中心落在哪块屏就用哪块屏；都匹配不上时退回主屏（与 HUD 的 positionAtBottomCenter 一致）
        let pillSize = Self.pillSize
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSPoint(x: anchorFrame.midX, y: anchorFrame.midY), $0.frame, false)
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let belowY = anchorFrame.minY - Self.gap - pillSize.height
        let placeAbove = belowY < visible.minY
        // 水平居中于锚点，再夹进屏幕可视区——光标贴屏幕左右边缘时胶囊不出屏
        let x = min(
            max(anchorFrame.midX - pillSize.width / 2, visible.minX + Self.gap),
            visible.maxX - pillSize.width - Self.gap
        )
        let pillFrame = NSRect(
            x: x,
            y: placeAbove ? anchorFrame.maxY + Self.gap : belowY,
            width: pillSize.width,
            height: pillSize.height
        )

        panel.setFrame(pillFrame, display: false)
        panel.contentView = NSHostingView(rootView: FocusLoaderView())

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        HotkeyFileLog.shared.log("loader: shown anchor=\(anchorFrame.size) mode=\(anchorMode) above=\(placeAbove)")
    }

    /// 淡出并隐藏。未被显示过时是空操作，可以无条件挂在 defer 上。
    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let gen = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // 淡出期间又 show 了新指示器：别把新的 orderOut 掉
            guard gen == self.generation else { return }
            panel.orderOut(nil)
        })
    }

    // MARK: - AX 锚点框查询

    /// 胶囊尺寸：三颗 6pt 圆点（间距 5）+ 左右 17 / 上下 10 内边距
    static let pillSize = NSSize(width: 62, height: 26)

    /// 焦点处的锚点框（Cocoa 坐标，左下原点）。
    /// 优先取**光标（插入点）的精确框**：用户刚敲完三下空格，视线就在光标位置；
    /// 而焦点元素的整体框在很多应用里比可见输入框宽（浏览器 contenteditable、
    /// Electron 组件树、带内边距的文本域），按它居中会偏——用户实测确认过。
    /// 光标框取不到（应用不支持 kAXBoundsForRange）时回退元素整体框。
    /// 元素由调用方解析传入（复用 HotkeyInputManager.focusedAXElement 的两级查询）。
    /// 只在主线程调用（show 所在调用链是 @MainActor）。
    private static func focusAnchorFrame(element: AXUIElement) -> (frame: NSRect, mode: String)? {
        // focusedAXElement 的 0.3s messaging timeout 只设在 app / systemWide 元素引用上，
        // 对返回的焦点元素不生效。不补设的话，目标应用挂起时下面的每个 AX 查询
        // 都会在主线程阻塞默认 ~6s。
        AXUIElementSetMessagingTimeout(element, 0.3)
        if let caret = caretFrame(in: element) {
            return (caret, "caret")
        }
        if let frame = elementFrame(element) {
            return (frame, "element")
        }
        return nil
    }

    /// 光标（选中范围，此刻长度为 0）在屏幕上的精确框。应用不支持时返回 nil。
    private static func caretFrame(in element: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
              let boundsValue = boundsRef, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var axPoint = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(boundsValue as! AXValue, .cgPoint, &axPoint)
        AXValueGetValue(boundsValue as! AXValue, .cgSize, &axSize)
        // 合理性检查：光标行高（个别实现对空范围返回退化/整元素框，宁可回退）
        guard axSize.height >= 3, axSize.height <= 100, axSize.width <= 1200 else { return nil }
        return axRectToCocoa(point: axPoint, size: axSize)
    }

    /// 焦点元素的整体框（原实现，作为光标框的回退）。
    private static func elementFrame(_ element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var axPoint = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &axPoint)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &axSize)
        // 退化框（隐藏控件 / 浏览器整页占位）不值得放指示器
        guard axSize.width >= 20, axSize.height >= 14 else { return nil }
        return axRectToCocoa(point: axPoint, size: axSize)
    }

    /// AX 全局坐标（主屏左上角原点，y 向下）转 Cocoa（主屏左下角原点，y 向上）
    private static func axRectToCocoa(point: CGPoint, size: CGSize) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(
            x: point.x,
            y: primaryHeight - point.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - 覆盖面板

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
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }
}

// MARK: - 三点 loading 视图

/// 半透明黑胶囊 + 三颗白点波浪跳动（iMessage「对方正在输入」的经典节奏）：
/// 依次上浮、变亮，相位错开，视觉上是一条从左到右的波。
private struct FocusLoaderView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    // 每颗点相位错开 0.55rad，波峰从左往右扫过一个周期约 1.05s
                    let bounce = 0.5 + 0.5 * sin(t * 2 * .pi / 1.05 - Double(index) * 0.55)
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.65 * bounce))
                        .frame(width: 6, height: 6)
                        .offset(y: -2.5 * bounce)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
        }
        .frame(width: Self.pillWidth, height: Self.pillHeight)
    }

    static let pillWidth: CGFloat = InputFocusLoader.pillSize.width
    static let pillHeight: CGFloat = InputFocusLoader.pillSize.height
}
