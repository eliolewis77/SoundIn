import AppKit
import SwiftUI

// MARK: - 划词翻译弹窗
// 不可编辑上下文（静态网页 / 文档 / PDF）里选中文字 + 连击触发键：原地写回不可行
//（退格可能误触浏览器后退、粘贴也无处可去），译文显示在选区附近的浮窗里。
// 面板非激活（不抢目标应用焦点）、可点击（复制 / 关闭），弹出瞬间页面仍可滚动阅读。
// 关闭手段：15s 自动淡出 / 关闭按钮 / Esc / 点击弹窗外任意处 / 下次触发替换。
// Esc 与点击外部用事件监听实现，监听**只在弹窗可见期间安装、关闭即拆除**——
// 不给常驻键盘热路径加开销；且只观察不吞事件（与方案 B 一致），Esc 和点击
// 照常送达目标应用，弹窗只是跟着关。
// 长译文：正文超过高度上限时换滚动变体（用 fittingSize 实测后整面板切换），
// 原文固定最多 3 行作参照；翻译失败在弹窗内显示红色提示，不弹系统通知。

@MainActor
@Observable
private final class TranslatePopupModel {
    enum State {
        case loading
        case success(String)
        case failure(String)
    }
    var state: State = .loading
    var original = ""
}

@MainActor
final class TranslatePopup {
    static let shared = TranslatePopup()
    private init() {}

    private var panel: NSPanel?
    private let model = TranslatePopupModel()
    /// 显示代际：show / hide 各递增一次，在途淡出动画与过期自动隐藏任务据此失效（模式同 InputFocusLoader）
    private var generation = 0
    private var autoHideTask: Task<Void, Never>?
    /// Esc / 点击外部的关闭监听，**只在弹窗可见期间安装**、关闭即拆除（不占常驻热路径）
    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?
    /// 是否已被用户/自动关闭。关闭后迟到的翻译结果不得把弹窗重新弹出来。
    private var isDismissed = false
    /// 弹窗相对选区的方位：下方摆放 → 高度变化时钉住顶边（贴着选区下缘向下生长）；
    /// 上方摆放 → 钉住底边向上生长。placeNear 决定，syncPanelSize 使用。
    private var pinTop = true
    /// 弹窗所在屏的可视区（placeNear 记下），高度校准后的出屏兜底用
    private var visibleFrame: NSRect = .zero

    // MARK: - 常量

    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    static let minHeight: CGFloat = 72
    /// 加载态的初始预估高度（真实高度 show 后立刻用 fittingSize 校准）
    static let initialHeight: CGFloat = 110
    /// 滚动变体里正文的固定高度
    static let maxBodyHeight: CGFloat = 360
    /// 自动淡出延时：留够读完一条短句的时间，长译文一般会手动关或被下次触发替换
    static let autoHideSeconds: TimeInterval = 15
    /// 原文只作参照显示（≤3 行），超长截断，避免无谓的布局测量开销
    static let maxOriginalChars = 600

    // MARK: - 状态入口

    /// 发起翻译时调用：立即在选区旁弹窗进入加载态（原文先显示），译文到达后原地更新。
    /// anchor 为选区的屏幕框（Cocoa 坐标）；nil 时退到屏幕中下方兜底。
    func show(original: String, anchor: NSRect?) {
        generation += 1
        cancelAutoHide()
        isDismissed = false
        model.state = .loading
        model.original = String(original.prefix(Self.maxOriginalChars))

        let panel = ensurePanel()
        swapRoot(scroll: false)
        placeNear(anchor: anchor, contentHeight: Self.initialHeight)
        syncPanelSize()
        fadeIn(panel)
        scheduleAutoHide()
        installDismissMonitors()
        HotkeyFileLog.shared.log("popup: shown originalChars=\(original.count) anchor=\(anchor.map { "\($0.size)" } ?? "nil")")
    }

    func showResult(_ text: String) {
        // 用户已用 Esc / 点击外部 / 关闭按钮关掉：迟到的结果不要把弹窗重新弹出来
        guard !isDismissed else { return }
        model.state = .success(text)
        let panel = ensurePanel()
        swapRoot(scroll: false)
        syncPanelSize()
        fadeInIfHidden(panel)
        scheduleAutoHide()
    }

    func showFailure(_ message: String) {
        guard !isDismissed else { return }
        model.state = .failure(message)
        let panel = ensurePanel()
        swapRoot(scroll: false)
        syncPanelSize()
        fadeInIfHidden(panel)
        scheduleAutoHide()
    }

    /// 淡出并隐藏。未显示时也置 isDismissed（拦住迟到结果），面板操作是空操作。
    func hide() {
        cancelAutoHide()
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
            // 淡出期间又触发了新弹窗：别把新的 orderOut 掉
            guard gen == self.generation else { return }
            panel.orderOut(nil)
        })
    }

    // MARK: - 自动隐藏

    private func scheduleAutoHide() {
        cancelAutoHide()
        let gen = generation
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoHideSeconds))
            guard !Task.isCancelled, let self, gen == self.generation else { return }
            self.hide()
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - Esc / 点击外部关闭

    private static let escapeKeyCode: UInt16 = 53  // kVK_Escape

    private func installDismissMonitors() {
        guard dismissGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
        // 全局监听只能观察不能拦截（NSEvent 的限制），正好符合"不吞事件"的设计：
        // Esc 和点击照常送达目标应用，弹窗只是跟着关闭
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
            // 用 mouseLocation（Cocoa 全局坐标）而非 locationInWindow：
            // 全局监听拿到的事件坐标是另一套坐标系，混用会误判
            if !panel.frame.contains(NSEvent.mouseLocation) {
                hide()
            }
        default:
            break
        }
    }

    // MARK: - 摆放与尺寸

    /// 决定弹窗放选区下方还是上方，并按当前内容高度摆好初始位置。
    /// 翻转判断用 maxHeight 预判而不是当前加载态高度：下方放得下最终高度才放下方，
    /// 避免译文到达、面板长高后下半截掉出屏幕。
    private func placeNear(anchor: NSRect?, contentHeight: CGFloat) {
        let panel = ensurePanel()
        // 锚点中心落在哪块屏就用哪块屏；选区框拿不到时用主屏
        let screen = anchor.map { anchor in
            NSScreen.screens.first {
                NSMouseInRect(NSPoint(x: anchor.midX, y: anchor.midY), $0.frame, false)
            }
        } ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? .zero

        guard let anchor else {
            // 兜底位：屏幕中下方居中（与选区关系不明，不做翻转）
            pinTop = true
            panel.setFrame(
                NSRect(
                    x: visibleFrame.midX - Self.width / 2,
                    y: visibleFrame.minY + visibleFrame.height * 0.18,
                    width: Self.width,
                    height: contentHeight
                ),
                display: false
            )
            return
        }
        pinTop = anchor.minY - 8 - Self.maxHeight >= visibleFrame.minY
        // 水平居中于选区，再夹进屏幕可视区——选区贴屏幕左右边缘时弹窗不出屏
        let x = min(
            max(anchor.midX - Self.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - Self.width - 8
        )
        let y = pinTop ? anchor.minY - 8 - contentHeight : anchor.maxY + 8
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: contentHeight), display: false)
    }

    /// 按当前内容实测高度校准面板。超过上限先换滚动变体再量。
    /// 下方摆放钉顶边、上方摆放钉底边，保证长译文向远离选区的方向生长；
    /// 最后做一次出屏兜底（极端情况下宁可盖住选区也不掉出可视区）。
    private func syncPanelSize() {
        guard let panel else { return }
        var hosting = panel.contentView as? NSHostingView<AnyView>
        var fit = hosting?.fittingSize.height ?? Self.minHeight
        if fit > Self.maxHeight {
            swapRoot(scroll: true)
            hosting = panel.contentView as? NSHostingView<AnyView>
            fit = hosting?.fittingSize.height ?? Self.maxHeight
        }
        let target = min(max(Self.minHeight, fit), Self.maxHeight)
        var frame = panel.frame
        if pinTop {
            // Cocoa 坐标原点在左下：钉顶边 = 固定 maxY，origin 随高度下移
            frame.origin.y = frame.maxY - target
        }
        frame.size.height = target
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - target
        }
        panel.setFrame(frame, display: true)
    }

    /// 用当前 model 重建内容视图。状态切换（加载 → 结果/失败）与滚动变体切换都走这里：
    /// 重建比依赖 Observable 原地 diff 更直接，弹窗内容很小，开销可忽略。
    private func swapRoot(scroll: Bool) {
        let panel = ensurePanel()
        let view = TranslatePopupView(
            model: model,
            scroll: scroll,
            onClose: { [weak self] in self?.hide() },
            onCopy: { [weak self] in
                guard let self, case .success(let text) = self.model.state else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
        panel.contentView = NSHostingView(rootView: AnyView(view))
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

    /// 状态更新路径用：面板还在屏上就只调尺寸不重播淡入
    private func fadeInIfHidden(_ panel: NSPanel) {
        guard panel.isVisible else {
            fadeIn(panel)
            return
        }
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
        // 材质背景 + 系统窗口阴影，浮在任意底色的页面上都有边界感
        panel.hasShadow = true
        panel.level = .floating
        // 与 InputFocusLoader / HUD 不同：弹窗要接收鼠标（复制、关闭），不点击穿透
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }
}

// MARK: - 弹窗视图

private struct TranslatePopupView: View {
    let model: TranslatePopupModel
    /// 滚动变体：正文固定高、内部滚动（超长译文）
    let scroll: Bool
    let onClose: () -> Void
    let onCopy: () -> Void

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !model.original.isEmpty {
                Text(model.original)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Divider()
            bodyContent
        }
        .padding(14)
        .frame(width: TranslatePopup.width, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 材质在浅色页面（白底文档）上边界模糊，补一圈极淡的描边
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("翻译", systemImage: "character.book.closed.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            if case .success = model.state {
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
            .frame(height: TranslatePopup.maxBodyHeight)
        } else {
            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .loading:
            HStack(spacing: 8) {
                PopupLoadingDots()
                Text("翻译中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .success(let text):
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

/// 弹窗内的三点 loading，节奏与输入框旁的 loading 指示（InputFocusLoader）同款：
/// 依次上浮、变亮，相位错开，视觉上是一条从左到右扫过的波。
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
