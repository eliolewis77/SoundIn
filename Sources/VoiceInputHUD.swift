import AppKit
import SwiftUI

// MARK: - 语音输入 HUD（移植自 reme 的 VoiceInputHUDView / HUDManager）
// 底部居中胶囊：录音时显示声波动画，转写时显示提示，成功时收缩为对勾，失败时显示感叹号。

enum VoiceInputHUDPhase {
    case recording
    case transcribing
    case success
    case cancelled
    case failure(message: String)
}

@MainActor
@Observable
final class VoiceInputHUDManager {
    static let shared = VoiceInputHUDManager()

    var phase: VoiceInputHUDPhase = .recording
    var message: String = "语音输入"
    /// 是否检测到人声（驱动波形动画从静止态切换到活跃态）
    var isVoiceActive = false
    /// 识别中的模拟进度（0~0.9 匀速前进，出结果后立即结束）
    var progress: CGFloat = 0
    /// 本次录音开始时目标应用是否有选中文本（录音阶段显示"将替换选中的内容"提示）
    var willReplaceSelection = false

    private var hudWindow: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private init() {}

    // MARK: - 状态机入口：把 VoiceInputPhase 映射为 HUD 展示
    func apply(voicePhase: VoiceInputPhase) {
        switch voicePhase {
        case .recording:
            show()
        case .transcribing:
            update(phase: .transcribing, message: "识别中")
        case .success:
            update(phase: .success, message: nil)
            hide(after: 1.2)
        case .clipboardFallback:
            update(phase: .failure(message: "已复制，请手动粘贴"), message: nil)
            hide(after: 1.8)
        case .cancelled:
            update(phase: .cancelled, message: "已取消")
            hide(after: 0.8)
        case .permissionDenied(let msg), .failure(let msg):
            update(phase: .failure(message: msg), message: nil)
            hide(after: 2.2)
        case .idle:
            hide(after: 0)
        }
    }

    // MARK: - 展示逻辑
    private func show() {
        cancelHideTask()
        stopProgressSimulation()
        phase = .recording
        message = "语音输入"
        isVoiceActive = false

        let window = ensureWindow()
        positionAtBottomCenter(window)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func update(phase newPhase: VoiceInputHUDPhase, message newMessage: String?) {
        cancelHideTask()

        // 识别中：启动模拟进度（匀速走到 90% 等结果）；其他状态停止并清零
        if isTranscribingPhase(newPhase) {
            startProgressSimulation()
        } else {
            stopProgressSimulation()
        }

        phase = newPhase
        if let newMessage {
            // 失败信息可能较长，截断以适配胶囊宽度
            message = newMessage.count > 14 ? String(newMessage.prefix(14)) + "…" : newMessage
        }
        guard let window = hudWindow, window.isVisible else { return }
        positionAtBottomCenter(window)
    }

    private func hide(after delay: TimeInterval) {
        cancelHideTask()
        guard let window = hudWindow else { return }

        let hideAction = {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
            })
        }

        if delay > 0 {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.cancelHideTask()
                hideAction()
            }
        } else {
            hideAction()
        }
    }

    private func cancelHideTask() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: - 模拟进度（方案三：识别中匀速填充到 90%，出结果立即结束）
    private func isTranscribingPhase(_ phase: VoiceInputHUDPhase) -> Bool {
        if case .transcribing = phase { return true }
        return false
    }

    private func startProgressSimulation() {
        progressTask?.cancel()
        progress = 0
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.isTranscribingPhase(self.phase) else { return }
                // 约 6 秒走到 90%，之后停住等真实结果
                self.progress = min(0.9, self.progress + 0.015)
            }
        }
    }

    private func stopProgressSimulation() {
        progressTask?.cancel()
        progressTask = nil
        progress = 0
    }

    // MARK: - 窗口管理
    /// 窗口固定尺寸（与视图外层 frame 一致）：收缩动画发生在窗口内部，
    /// 窗口本身不做 setFrame 跳变（否则与 SwiftUI 动画不同步，视觉错位）。
    /// 高度 = 胶囊 46 + 上方替换提示条区 32；胶囊始终贴底，位置与旧版一致
    private static let windowSize = NSSize(width: 168, height: 78)
    /// 胶囊本体高度（视图布局用）
    static let capsuleHeight: CGFloat = 46

    private func ensureWindow() -> NSPanel {
        if let hudWindow { return hudWindow }
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.contentView = NSHostingView(rootView: VoiceInputCapsuleView(manager: self))
        hudWindow = window
        return window
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let size = Self.windowSize
        let x = screenFrame.minX + (screenFrame.width - size.width) / 2
        let y = screenFrame.minY + 76
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

// MARK: - 胶囊视图
struct VoiceInputCapsuleView: View {
    let manager: VoiceInputHUDManager
    @State private var successCheckVisible = false
    @State private var isVoiceActive = false

    private var isSuccess: Bool { isSuccessPhase(manager.phase) }
    private var capsuleWidth: CGFloat { isSuccess ? 46 : 168 }
    static let windowWidth: CGFloat = 168
    /// 窗口总高：胶囊 46 + 上方提示区 32（胶囊贴底，与旧版位置一致）
    static let windowHeight: CGFloat = 78

    var body: some View {
        VStack(spacing: 7) {
            if showsReplaceTip {
                replaceTip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            capsuleBody
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: showsReplaceTip)
    }

    /// 录音阶段 + 检测到选中文本时显示替换提示
    private var showsReplaceTip: Bool {
        guard case .recording = manager.phase else { return false }
        return manager.willReplaceSelection
    }

    private var replaceTip: some View {
        Text("将替换选中的内容")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Color(red: 0.59, green: 0.77, blue: 0.35)))
    }

    @ViewBuilder
    private var capsuleBody: some View {
        ZStack {
            // 识别中：进度填充条（reme 样式，从左往右覆盖胶囊）
            if case .transcribing = manager.phase {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.green.opacity(0.38))
                        .frame(
                            width: max(0, proxy.size.width * manager.progress),
                            height: proxy.size.height,
                            alignment: .leading
                        )
                }
                .transition(.opacity)
            }

            if isSuccess {
                if successCheckVisible {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            } else {
                HStack(spacing: 10) {
                    Text(hudTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Divider()
                        .frame(height: 13)
                        .overlay(Color.white.opacity(0.24))

                    statusView
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .transition(.opacity)
            }
        }
        .frame(width: capsuleWidth, height: 46)
        .background(backgroundShape)
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .frame(width: Self.windowWidth, height: 46) // 外层固定 = 窗口尺寸，胶囊居中收缩
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSuccess)
        .animation(.easeOut(duration: 0.12), value: phaseIdentity)
        .animation(.linear(duration: 0.12), value: manager.progress)
        .onChange(of: phaseIdentity) { _, _ in
            successCheckVisible = false
            guard isSuccess else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    successCheckVisible = true
                }
            }
        }
        .onChange(of: manager.audioLevelProxy) { _, level in
            updateVoiceActivity(for: level)
        }
    }

    private var hudTitle: String { manager.message }

    private var backgroundShape: some ShapeStyle {
        if isSuccess {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.green, Color.green.opacity(0.76)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(Color.black.opacity(0.82))
    }

    @ViewBuilder
    private var statusView: some View {
        switch manager.phase {
        case .recording:
            if isVoiceActive {
                TimelineView(.animation) { timeline in
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { index in
                            let level = waveLevel(at: timeline.date, index: index)
                            Capsule(style: .continuous)
                                .fill(.white)
                                .frame(width: 3, height: 5 + level * 11)
                                .opacity(0.62 + level * 0.34)
                        }
                    }
                    .frame(width: 28, height: 16)
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(width: 3, height: 4)
                            .opacity(0.72)
                    }
                }
                .frame(width: 28, height: 16)
            }

        case .transcribing:
            Text("\(Int(manager.progress * 100))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 34, alignment: .trailing)

        case .success:
            EmptyView()

        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.red)
                .frame(width: 25)

        case .failure(let _):
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.orange)
                .frame(width: 25)
        }
    }

    private func waveLevel(at date: Date, index: Int) -> CGFloat {
        let audioLevel = max(0, min(1, manager.audioLevelProxy))
        let time = date.timeIntervalSinceReferenceDate
        let phase = time * 7.2 + Double(index) * 0.9
        let wave = CGFloat((sin(phase) + 1) / 2)
        let weights: [CGFloat] = [0.46, 0.88, 1.0, 0.62]
        return min(1, max(0.08, audioLevel * weights[index] + wave * 0.28))
    }

    private func updateVoiceActivity(for level: CGFloat) {
        if isVoiceActive {
            if level <= 0.045 { isVoiceActive = false }
        } else if level >= 0.10 {
            isVoiceActive = true
        }
    }

    // MARK: - Helpers（避免 enum 关联值影响动画 identity）
    private func isSuccessPhase(_ phase: VoiceInputHUDPhase) -> Bool {
        if case .success = phase { return true }
        return false
    }

    private var phaseIdentity: Int {
        switch manager.phase {
        case .recording: 0
        case .transcribing: 1
        case .success: 2
        case .cancelled: 3
        case .failure: 4
        }
    }
}

// MARK: - SpeechManager 音频电平桥接
extension VoiceInputHUDManager {
    /// HUD 波形使用的实时音频电平（直接读 SpeechManager 的 @Observable 属性）
    var audioLevelProxy: CGFloat {
        SpeechManager.shared.audioLevel
    }
}
