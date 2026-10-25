import AppKit

/// 钉图独立持有裁剪后的图片；关闭窗口即释放，不保留整屏快照。
@MainActor
final class PinnedScreenshotManager {
    static let shared = PinnedScreenshotManager()
    private var windows: [UUID: PinnedScreenshotController] = [:]
    private init() {}

    @discardableResult
    func pin(_ image: CGImage, at selectionFrame: NSRect) -> UUID? {
        // CGImage.cropping 会共享整屏像素；重新绘制选区，避免每张钉图占住整屏快照。
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let detachedImage = bitmap.makeImage() else { return nil }
        let id = UUID()
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSPoint(x: selectionFrame.midX, y: selectionFrame.midY), $0.frame, false)
        } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? selectionFrame
        let controller = PinnedScreenshotController(image: detachedImage, selectionFrame: selectionFrame,
                                                    visibleFrame: visibleFrame) { [weak self] in
            self?.windows.removeValue(forKey: id)
        }
        windows[id] = controller
        controller.window?.orderFrontRegardless()
        return id
    }
}

/// 大图缩到屏幕内，窗口尺寸始终与截图比例一致，不添加空白边缘。
enum PinnedScreenshotPlacement {
    static func contentSize(for selection: NSSize, in visibleFrame: NSRect) -> NSSize {
        let availableWidth = max(1, visibleFrame.width - 32)
        let availableHeight = max(1, visibleFrame.height - 32)
        let scale = min(1, availableWidth / max(1, selection.width),
                        availableHeight / max(1, selection.height))
        return NSSize(width: max(1, selection.width) * scale,
                      height: max(1, selection.height) * scale)
    }

    static func clamp(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = max(visibleFrame.minX + 16, min(frame.minX, visibleFrame.maxX - frame.width - 16))
        frame.origin.y = max(visibleFrame.minY + 16, min(frame.minY, visibleFrame.maxY - frame.height - 16))
        return frame
    }
}

@MainActor
private final class PinnedScreenshotController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(image: CGImage, selectionFrame: NSRect, visibleFrame: NSRect, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let size = PinnedScreenshotPlacement.contentSize(for: selectionFrame.size, in: visibleFrame)
        let panel = PinnedScreenshotPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "钉图"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isRestorable = false
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = selectionFrame.size
        panel.contentMinSize = NSSize(width: min(24, size.width), height: min(24, size.height))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = PinnedScreenshotImageView(image: NSImage(cgImage: image, size: selectionFrame.size))
        let desired = panel.frameRect(forContentRect: NSRect(origin: selectionFrame.origin, size: size))
        panel.setFrame(PinnedScreenshotPlacement.clamp(desired, to: visibleFrame), display: false)
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        onClose()
    }
}

private final class PinnedScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// 无标题栏钉图：细边线区分背景，双击关闭，单击拖动，滚轮缩放。
private final class PinnedScreenshotImageView: NSImageView {
    init(image: NSImage) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        imageFrameStyle = .none
        isEditable = false
        toolTip = "双击关闭，拖动移动，滚轮缩放；右键更多操作"
        setAccessibilityLabel("钉住的截图")
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制截图", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        for (title, action) in [("放大", #selector(zoomIn)), ("缩小", #selector(zoomOut)), ("原始大小", #selector(resetSize))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭钉图", action: #selector(closePin), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        self.menu = menu
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 内外各一个物理像素，亮底和暗底都能辨认；只绘制在浮窗上，不写进截图。
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let outer = NSBezierPath(rect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2))
        outer.lineWidth = pixel
        NSColor.black.withAlphaComponent(0.6).setStroke()
        outer.stroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: pixel * 1.5, dy: pixel * 1.5))
        inner.lineWidth = pixel
        NSColor.white.withAlphaComponent(0.8).setStroke()
        inner.stroke()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.close()
            return
        }
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0, let window, let image else { return }
        let delta = max(-20, min(20, event.scrollingDeltaY))
        let factor = exp(delta * (event.hasPreciseScrollingDeltas ? 0.005 : 0.08))
        resizeImage(to: window.frame.width / image.size.width * factor,
                    around: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
            window?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    private func resizeImage(to requestedScale: CGFloat, around anchor: NSPoint? = nil) {
        guard let window, let image, let screen = window.screen ?? NSScreen.main else { return }
        let original = image.size
        guard original.width > 0, original.height > 0 else { return }
        let visible = screen.visibleFrame
        let maxScale = min((visible.width - 32) / original.width, (visible.height - 32) / original.height)
        let minScale = min(maxScale, min(1, 24 / max(original.width, original.height)))
        let scale = max(minScale, min(maxScale, requestedScale))
        let old = window.frame
        let anchor = anchor ?? NSPoint(x: old.midX, y: old.midY)
        let fraction = NSPoint(x: max(0, min(1, (anchor.x - old.minX) / old.width)),
                               y: max(0, min(1, (anchor.y - old.minY) / old.height)))
        let size = NSSize(width: original.width * scale, height: original.height * scale)
        let proposed = NSRect(x: anchor.x - fraction.x * size.width,
                              y: anchor.y - fraction.y * size.height, width: size.width, height: size.height)
        window.setFrame(PinnedScreenshotPlacement.clamp(proposed, to: visible), display: true)
    }

    @objc private func zoomIn() {
        guard let window, let image else { return }
        resizeImage(to: window.frame.width / image.size.width * 1.2)
    }

    @objc private func zoomOut() {
        guard let window, let image else { return }
        resizeImage(to: window.frame.width / image.size.width / 1.2)
    }

    @objc private func resetSize() { resizeImage(to: 1) }

    @objc private func copyImage() {
        guard let data = image?.tiffRepresentation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .tiff)
    }

    @objc private func closePin() {
        window?.close()
    }
}
