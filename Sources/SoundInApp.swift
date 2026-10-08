import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import Speech
import Combine
import UniformTypeIdentifiers

enum VoiceInputPhase {
    case idle
    case recording
    case transcribing
    /// 连击翻译请求进行中（HUD 显示进度，不显示声波）
    case translating
    case success
    case clipboardFallback
    case cancelled
    case permissionDenied(message: String)
    case failure(message: String)
}

extension Notification.Name {
    static let voicePhaseChanged = Notification.Name("voicePhaseChanged")
    /// 菜单栏点开「设置…」时发出：macOS 上 Window 场景关窗保留状态，
    /// 重开后上次会话的瞬态 UI（连接测试结果等）需要主动清理
    static let settingsWindowOpening = Notification.Name("settingsWindowOpening")
}

@main
struct SoundInApp: App {
    @State private var speechManager = SpeechManager.shared
    @State private var phase: VoiceInputPhase = SoundInApp.currentPhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            VStack {
                Text(statusText).foregroundStyle(.secondary)
                Button("设置…") {
                    // 常规原生窗口：可缩放、三个窗口按钮均可用
                    openWindow(id: "settings")
                    // 重开面板时清掉上次残留的瞬态状态（连接测试结果）
                    NotificationCenter.default.post(name: .settingsWindowOpening, object: nil)
                    // 菜单还处于跟踪状态时立即 activate 会被系统吞掉（代理应用尤其如此），
                    // 设置窗口会开在前台应用后面被挡住。延迟到菜单收起、窗口创建完成
                    // 之后再激活应用并把设置窗口显式调到前台。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        if let window = NSApp.windows.first(where: { $0.title.contains("设置") }) {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
                Divider()
                Button("退出") {
                    AppDelegate.userRequestedQuit = true
                    NSApp.terminate(nil)
                }
            }
            .padding(8)
            // 菜单栏此前从未订阅 voicePhaseChanged，图标与状态文字永远停留在初始值
            .onReceive(NotificationCenter.default.publisher(for: .voicePhaseChanged)) { _ in
                phase = SoundInApp.currentPhase
            }
        } label: {
            // 空闲时显示品牌标识（三根声波条 + 细光标），其余状态保留 SF Symbol 以传达实时信息
            if case .idle = phase {
                Image(nsImage: Self.brandMenuBarIcon)
            } else {
                Image(systemName: statusIcon)
            }
        }
        .menuBarExtraStyle(.menu)

        Window("SoundIn 设置", id: "settings") {
            settingsView
                .frame(minWidth: 620, minHeight: 430)
        }
        .defaultSize(width: 680, height: 480)
        .windowResizability(.contentMinSize)
    }

    private var settingsView: SettingsView {
        SettingsView()
    }

    private var statusText: String {
        switch phase {
            case .idle: "就绪 · \(HotkeyInputManager.shared.displayShortcut)"
            case .recording: "正在录音…"
            case .transcribing: "正在转写…"
            case .translating: "正在翻译…"
            case .success: "已输入到光标"
        case .clipboardFallback: "已复制，请手动粘贴"
        case .cancelled: "已取消"
        case .permissionDenied(let message), .failure(let message): message
        }
    }

    static var currentPhase: VoiceInputPhase = .idle {
        didSet { NotificationCenter.default.post(name: .voicePhaseChanged, object: nil) }
    }

    /// SoundIn 品牌状态栏图标：与 App 图标同构「三根声波条 + 输入块 + 光标」
    /// 所有竖条统一粗细、统一为实心黑（颜色一致、不再渐弱透明），按 gen_icon.py 几何比例缩放（1024 → 16pt，k=0.03125），isTemplate 自适应深浅色
    static let brandMenuBarIcon: NSImage = {
        let canvas: CGFloat = 16
        // gen_icon.py 尺寸 × k
        let k: CGFloat = 0.03125
        // 统一粗细：声波条 / 输入块 / 光标 宽度一致，仅高度不同
        let thickness = 48 * k   // 1.5
        let gap = 48 * k        // 1.5
        // 各元素高度（pt）：三根声波 5 / 9 / 13，输入块 12，光标 10（最右，比输入块低一点）
        let barHeights: [CGFloat] = [160 * k, 288 * k, 416 * k]
        let blockH = 384 * k    // 12（第二右：输入块）
        let cursorH = 320 * k   // 10（最右：光标，比输入块低一点）
        let elementCount = barHeights.count + 2
        let totalW = thickness * CGFloat(elementCount) + gap * CGFloat(elementCount - 1)
        let startX = (canvas - totalW) / 2   // 整体水平居中
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            var x = startX
            // 左侧三根声波（与输入块/光标同为实心黑，颜色统一）
            for h in barHeights {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: (canvas - h) / 2, width: thickness, height: h),
                             xRadius: thickness / 2, yRadius: thickness / 2).fill()
                x += thickness + gap
            }
            // 输入块（第二右，高 12）+ 光标（最右，高 10，比输入块低一点）
            for h in [blockH, cursorH] {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: (canvas - h) / 2, width: thickness, height: h),
                             xRadius: thickness / 2, yRadius: thickness / 2).fill()
                x += thickness + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    private var statusIcon: String {
        switch phase {
            case .idle: "waveform"
            case .recording: "mic.fill"
            case .transcribing: "ellipsis.bubble"
            case .translating: "character.book.closed.fill"
            case .success: "checkmark.circle.fill"
        case .clipboardFallback: "doc.on.doc.fill"
        case .cancelled: "xmark.circle.fill"
        case .permissionDenied, .failure: "exclamationmark.triangle.fill"
        }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 菜单「退出」置位后才放行 terminate。Cmd+Q 在启动后 10 秒内会被下面的
    /// 假退出拦截一并挡掉（极小代价，换启动稳定性）。
    static var userRequestedQuit = false

    private let launchTime = Date()

    /// macOS 26.6 更新后，MenuBarExtra 状态项在启动瞬间可能收到系统的
    /// NSStatusItemChangeVisibilityAction，AppKit 据此主动 terminate（exit 0、
    /// 无崩溃日志），表现为「启动即退」。启动头几秒没有用户交互，这种 terminate
    /// 一律拒绝：状态项暂时不可见时核心功能（快捷键听写/连击翻译）照常可用，
    /// 菜单栏恢复后图标自然回来。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.userRequestedQuit { return .terminateNow }
        let elapsed = Date().timeIntervalSince(launchTime)
        guard elapsed < 10 else { return .terminateNow }
        HotkeyFileLog.shared.log("app: suppressed spurious terminate at \(String(format: "%.2f", elapsed))s after launch")
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyFileLog.shared.log("=== app launched ===")
        HotkeyFileLog.shared.log("axTrusted at launch = \(AXIsProcessTrusted())")
        // 不再调用 setActivationPolicy(.accessory)：Info.plist 的 LSUIElement 已让应用
        // 以代理身份启动。macOS 26.6 上启动期再切一次策略会干扰状态项注册（已知问题）。
        // 把识别/润色各自选中的 API 配置档回写进 SpeechManager（升级迁移后保证活动值一致）
        APIProfileStore.shared.applyActive(to: SpeechManager.shared)
        HotkeyInputManager.shared.start()
        // 自动更新：延迟几秒静默检查，失败不打扰用户
        AppUpdater.shared.scheduleStartupCheck()
        HotkeyInputManager.shared.onStateChange = { newPhase in
            Task { @MainActor in
                SoundInApp.currentPhase = newPhase
                // 底部胶囊 HUD 跟随语音输入状态（移植自 reme）
                VoiceInputHUDManager.shared.apply(voicePhase: newPhase)
            }
        }
    }
}

private struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, hotkeys, engine, polish, translate, stats, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .hotkeys: "快捷键"
            case .engine: "识别引擎"
            case .polish: "文字优化"
            case .translate: "翻译"
            case .stats: "统计"
            case .about: "关于"
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .hotkeys: "keyboard"
            case .engine: "waveform.badge.mic"
            case .polish: "wand.and.stars"
            case .translate: "character.book.closed"
            case .stats: "chart.bar.fill"
            case .about: "info.circle"
            }
        }
    }

    @Bindable var speech = SpeechManager.shared
    @ObservedObject var history = InputHistory.shared
    @ObservedObject var profileStore = APIProfileStore.shared
    @ObservedObject var stats = DictationStats.shared
    @State private var selectedPage: Page = .general
    @State private var isAddingProfile = false
    @State private var newProfileName = ""
    @State private var addProfileTarget: Page = .engine
    @State private var profilePendingDelete: APIProfile?
    @State private var clickShortcut: HotkeyInputManager.Shortcut = HotkeyInputManager.shared.clickShortcut
    @State private var holdShortcut: HotkeyInputManager.Shortcut = HotkeyInputManager.shared.holdShortcut
    @State private var holdThreshold: Double = HotkeyInputManager.shared.holdThreshold
    @State private var stripTrailingPunctuation: Bool = HotkeyInputManager.shared.stripTrailingPunctuation
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var capturingSlot: Slot? = nil
    private enum Slot: Equatable { case click, hold }
    @State private var registrationError: String?
    @State private var isTestRecording = false
    @State private var isTranscribing = false
    @State private var testResult = ""
    @State private var engineConnectionTest: SpeechManager.ConnectionTestResult?
    @State private var isTestingEngineConnection = false
    @State private var polishConnectionTest: SpeechManager.ConnectionTestResult?
    @State private var isTestingPolishConnection = false
    @State private var translateConnectionTest: SpeechManager.ConnectionTestResult?
    @State private var isTestingTranslateConnection = false
    @State private var isConfirmingClearHistory = false
    @State private var sidebarVisible = true
    // 权限状态的刷新计数：TCC 授权变化系统不会推送通知，授权 API 也不是可观察状态，
    // 只能靠重查。两个触发源见权限区块上的 onReceive：应用回到前台 + 可见期间轻量轮询。
    @State private var authRevision = 0
    // 连击翻译触发键录制状态
    @State private var isCapturingTranslateKey = false
    @State private var translateKeyError: String?
    @State private var translateKey: UInt16 = HotkeyInputManager.shared.translateKey
    @State private var translateTapCount: Int = HotkeyInputManager.shared.translateTapCount
    @State private var translateInterval: Double = HotkeyInputManager.shared.translateInterval

    /// 侧边栏自定义底色：比系统默认侧边栏材质浅一档，跟随深浅色模式
    private static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)   // #3A3A3C
            : NSColor(srgbRed: 236 / 255, green: 237 / 255, blue: 240 / 255, alpha: 1) // #ECEDF0
    })

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                List(selection: $selectedPage) {
                    ForEach(Page.allCases) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                .listStyle(.sidebar)
                // 替换系统侧边栏材质：深色模式下系统默认偏深灰，这里整体提亮一档
                .scrollContentBackground(.hidden)
                .background(Self.sidebarBackground)
                .frame(minWidth: 130, idealWidth: 148, maxWidth: 176)
            }
            Form {
                switch selectedPage {
                case .general: generalPage
                case .hotkeys: hotkeysPage
                case .engine: enginePage
                case .polish: polishPage
                case .translate: translatePage
                case .stats: statsPage
                case .about: aboutPage
                }
            }
            .formStyle(.grouped)
            // 主体页背景改为白色（浅色模式下；深色模式仍跟随系统以免文字不可读）
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { sidebarVisible.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(sidebarVisible ? "收起侧边栏" : "展开侧边栏")
            }
        }
        // 关窗再开会恢复场景状态：上次会话的连接测试结果还挂着，
        // 看起来像当前配置的实时状态。菜单栏点「设置…」时发通知，这里清掉。
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowOpening)) { _ in
            engineConnectionTest = nil
            polishConnectionTest = nil
            translateConnectionTest = nil
        }
        .alert("新建配置档", isPresented: $isAddingProfile) {
            TextField("名称", text: $newProfileName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let profile = profileStore.addProfile(named: newProfileName)
                if addProfileTarget == .engine {
                    selectEngineProfile(profile.id)
                } else if addProfileTarget == .translate {
                    selectTranslateProfile(profile.id)
                } else {
                    selectPolishProfile(profile.id)
                }
            }
        } message: {
            Text("为新的接口配置起个名字，之后填入地址、Key 和模型。")
        }
        .confirmationDialog(
            "删除配置「\(profilePendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { if !$0 { profilePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let pending = profilePendingDelete {
                    let wasEngine = pending.id == profileStore.engineSelectionID
                    let wasPolish = pending.id == profileStore.polishSelectionID
                    let wasTranslate = pending.id == profileStore.translateSelectionID
                    profileStore.deleteProfile(pending.id)
                    if wasEngine || wasPolish || wasTranslate {
                        profileStore.applyActive(to: speech)
                    }
                }
                profilePendingDelete = nil
            }
            Button("取消", role: .cancel) { profilePendingDelete = nil }
        }
        .confirmationDialog(
            "清空全部输入历史？",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("最近输入记录将全部删除，听写统计数字不受影响。")
        }
    }

    // MARK: - API 配置档辅助

    /// 切换识别引擎选中的配置档，并同步活动值
    private func selectEngineProfile(_ id: UUID?) {
        profileStore.engineSelectionID = id
        engineConnectionTest = nil // 配置变化后旧测试结果失效
        if let p = profileStore.selectedEngine {
            speech.speechAPIBaseURL = p.baseURL
            speech.speechAPIKey = p.apiKey
            speech.speechModelName = p.modelName
        }
    }

    /// 切换文字优化选中的配置档，并同步活动值
    private func selectPolishProfile(_ id: UUID?) {
        profileStore.polishSelectionID = id
        polishConnectionTest = nil // 配置变化后旧测试结果失效
        if let p = profileStore.selectedPolish {
            speech.polishAPIBaseURL = p.baseURL
            speech.polishAPIKey = p.apiKey
            speech.polishModelName = p.modelName
        }
    }

    /// 切换翻译选中的配置档，并同步活动值
    private func selectTranslateProfile(_ id: UUID?) {
        profileStore.translateSelectionID = id
        translateConnectionTest = nil // 配置变化后旧测试结果失效
        if let p = profileStore.selectedTranslate {
            speech.translateAPIBaseURL = p.baseURL
            speech.translateAPIKey = p.apiKey
            speech.translateModelName = p.modelName
        }
    }

    /// 字段双写 Binding：读当前选中档的字段；写入同时更新该档与 SpeechManager 活动属性
    private func profileFieldBinding(
        selection: UUID?,
        keyPath: WritableKeyPath<APIProfile, String>,
        onActiveChange: @escaping (String) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                profileStore.profiles.first { $0.id == selection }?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                if let selection {
                    profileStore.updateProfile(selection, keyPath: keyPath, value: newValue)
                }
                onActiveChange(newValue)
                // 配置字段变化后，三处（引擎/优化/翻译）的连接测试结果都可能与当前配置不一致，统一失效
                engineConnectionTest = nil
                polishConnectionTest = nil
                translateConnectionTest = nil
            }
        )
    }

    private var engineProfilePicker: some View {
        Picker("接口配置", selection: Binding(
            get: { profileStore.engineSelectionID },
            set: { selectEngineProfile($0) }
        )) {
            ForEach(profileStore.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
    }

    private var polishProfilePicker: some View {
        Picker("接口配置", selection: Binding(
            get: { profileStore.polishSelectionID },
            set: { selectPolishProfile($0) }
        )) {
            ForEach(profileStore.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
    }

    private var translateProfilePicker: some View {
        Picker("接口配置", selection: Binding(
            get: { profileStore.translateSelectionID },
            set: { selectTranslateProfile($0) }
        )) {
            ForEach(profileStore.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
    }

    // MARK: - 通用
    @ViewBuilder
    private var generalPage: some View {
        Section {
            Toggle("开机时启动", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLogin = newValue
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        HotkeyFileLog.shared.log("launch-at-login failed — \(error.localizedDescription)")
                    }
                }
            ))

            Toggle("去掉转写结果句末标点", isOn: Binding(
                get: { stripTrailingPunctuation },
                set: { newValue in
                    stripTrailingPunctuation = newValue
                    HotkeyInputManager.shared.stripTrailingPunctuation = newValue
                }
            ))
            .help("开启后，粘贴的转写文本会去掉最后一个句号、问号、感叹号等终止标点。默认关闭。")

            Toggle("显示语音输入悬浮窗", isOn: Binding(
                get: { VoiceInputHUDManager.shared.isEnabled },
                set: { VoiceInputHUDManager.shared.isEnabled = $0 }
            ))
            .help("录音/识别时在屏幕底部居中显示状态胶囊。关闭后仅菜单栏图标反映状态。默认开启。")
        }
    }

    // MARK: - 快捷键（单击 / 长按两块独立触发）
    @ViewBuilder
    private var hotkeysPage: some View {
        Section("单击触发") {
            HStack {
                Text("单击快捷键")
                Spacer()
                shortcutCaptureButton(.click, title: clickShortcut.displayText)
            }
        }

        Section("长按触发") {
            HStack {
                Text("长按快捷键")
                Spacer()
                shortcutCaptureButton(.hold, title: holdShortcut.displayText)
            }

            Picker("长按阈值", selection: Binding(
                get: { holdThreshold },
                set: { newValue in
                    holdThreshold = newValue
                    HotkeyInputManager.shared.holdThreshold = newValue
                }
            )) {
                Text("0.5 秒").tag(0.5)
                Text("0.7 秒").tag(0.7)
                Text("1.0 秒").tag(1.0)
            }
        }

        Section {
            Text("单击键：点一下开始，再点一下结束。长按键：按住说话，松开即停。两个快捷键同时生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let registrationError {
                Text(registrationError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            ForEach(consolidatedShortcutWarnings, id: \.self) { msg in
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func shortcutCaptureButton(_ slot: Slot, title: String) -> some View {
        Button(capturingSlot == slot ? "请按下新快捷键…（点击或 Esc 取消）" : title) {
            if capturingSlot == slot {
                // 录制状态下再次点击 = 取消，避免卡死在录制态
                HotkeyInputManager.shared.cancelSystemCapture()
                capturingSlot = nil
                return
            }
            HotkeyFileLog.shared.log("settings: record \(slot) clicked")
            capturingSlot = slot
            registrationError = nil
            HotkeyInputManager.shared.beginSystemCapture(
                onCancel: {
                    capturingSlot = nil
                },
                onComplete: { keyCode, modifiers in
                    let newShortcut = HotkeyInputManager.Shortcut(
                        keyCode: keyCode,
                        modifiersRawValue: modifiers.intersection(.deviceIndependentFlagsMask).rawValue
                    )
                    switch slot {
                    case .click:
                        clickShortcut = newShortcut
                        HotkeyInputManager.shared.clickShortcut = newShortcut
                    case .hold:
                        holdShortcut = newShortcut
                        HotkeyInputManager.shared.holdShortcut = newShortcut
                    }
                    capturingSlot = nil
                    // 注册失败（组合键被占用）立即提示，而不是静默不生效
                    registrationError = HotkeyInputManager.shared.lastRegistrationError
                }
            )
        }
    }

    /// 两块快捷键的授权/接管提示合并到一处（去重），只在设置页最底部显示一次
    private var consolidatedShortcutWarnings: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for shortcut in [clickShortcut, holdShortcut] {
            if shortcut.isModifierOnly {
                let msg = "修饰键热键需要在「系统设置 → 隐私与安全性 → 输入监控」中授权 SoundIn，才能在所有应用中生效。"
                if seen.insert(msg).inserted { result.append(msg) }
            } else if !shortcut.modifiers.contains([.command, .control, .option, .shift]) {
                let msg = "当前是单键热键：该按键会被全局接管，在其他应用中按下它将不会正常输入。"
                if seen.insert(msg).inserted { result.append(msg) }
            }
        }
        return result + translateShortcutConflictWarnings
    }

    /// 翻译触发键与单击/长按快捷键的冲突（翻译页与快捷键页共用同一份提示）：
    /// - 单键热键被 Carbon 全局接管（吞键）→ 同键做触发键收不到按键，连击永远计不满
    /// - 纯修饰键热键与修饰键触发键都走 flagsChanged 观察 → 按一下同时开始录音并计入连击
    /// 组合键热键（⌘X 等）不吞裸键（见 HotkeyInputManager 的说明），不构成冲突。
    /// 只警告不阻止：换键是明确动作，强拦反而让用户找不到提示语义。
    private var translateShortcutConflictWarnings: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ msg: String) {
            if seen.insert(msg).inserted { result.append(msg) }
        }
        let translateFamily = HotkeyInputManager.modifierFamily(of: translateKey)
        for shortcut in [clickShortcut, holdShortcut] {
            if shortcut.isModifierOnly {
                // 此分支里 family 必非 nil；translateFamily 为 nil（普通键触发）时不等，不误报
                if let family = HotkeyInputManager.modifierFamily(of: shortcut.keyCode),
                   family == translateFamily {
                    add("翻译触发键与单击/长按快捷键是同一个修饰键：按下会同时开始录音并计入连击，请更换其中一个。")
                }
            } else if !shortcut.modifiers.contains([.command, .control, .option, .shift]),
                      shortcut.keyCode == translateKey {
                add("翻译触发键与单击/长按快捷键是同一个按键：该键已被全局接管，翻译收不到按键，请更换其中一个。")
            }
        }
        return result
    }

    // MARK: - 识别引擎
    @ViewBuilder
    private var enginePage: some View {
        Section("识别引擎") {
            Picker("识别方式", selection: $speech.recognitionProvider) {
                Text("本机 Apple 语音识别").tag(SpeechManager.RecognitionProvider.local)
                Text("OpenAI 兼容 API").tag(SpeechManager.RecognitionProvider.api)
            }
            .pickerStyle(.segmented)

            Picker("识别语言", selection: $speech.recognitionLanguage) {
                Text("跟随系统").tag(SpeechManager.RecognitionLanguage.followSystem)
                Text("中文（简体）").tag(SpeechManager.RecognitionLanguage.zhCN)
                Text("English (US)").tag(SpeechManager.RecognitionLanguage.enUS)
                Text("日本語").tag(SpeechManager.RecognitionLanguage.jaJP)
            }

            if speech.recognitionProvider == .api {
                Toggle("长录音分段转写", isOn: $speech.preferSegmentedTranscription)
            }

            Picker("麦克风", selection: Binding(
                get: { speech.selectedMicrophoneUID },
                set: { speech.selectedMicrophoneUID = $0 }
            )) {
                Text("跟随系统").tag("")
                ForEach(AVCaptureDevice.devices(for: .audio), id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
        }

        if speech.recognitionProvider == .api {
            Section("OpenAI 兼容 API（语音转写）") {
                engineProfilePicker
                profileFieldsSection(
                    selection: profileStore.engineSelectionID,
                    baseLabel: "Base URL",
                    onBaseChange: { speech.speechAPIBaseURL = $0 },
                    onKeyChange: { speech.speechAPIKey = $0 },
                    onModelChange: { speech.speechModelName = $0 },
                    missingWarning: (speech.speechAPIBaseURL.isEmpty || speech.speechModelName.isEmpty)
                        ? "API 模式需要填写 Base URL 和模型名称；API Key 可留空（本地网关通常不需要）。" : nil
                )
                profileActionRow(
                    target: .engine,
                    selected: profileStore.selectedEngine,
                    isTesting: isTestingEngineConnection,
                    testResult: engineConnectionTest
                ) {
                    isTestingEngineConnection = true
                    engineConnectionTest = nil
                    let base = speech.speechAPIBaseURL
                    let key = speech.speechAPIKey
                    let model = speech.speechModelName
                    let result = await SpeechManager.shared.testAPIConnection(baseURL: base, apiKey: key, model: model)
                    engineConnectionTest = result
                    isTestingEngineConnection = false
                }
            }
        }

        // 录音测试并进引擎页（原先单独成页太薄）：走与快捷键完全相同的识别链路，
        // 配完引擎往下滚就是"实际录一句"的验证，配置 → 测试连接 → 实测一条动线。
        Section("录音测试") {
            HStack {
                Button(isTestRecording ? "停止并识别" : "开始录音测试") {
                    toggleTestRecording()
                }
                .disabled(SpeechManager.shared.isRecording && !isTestRecording)

                Spacer()
            }
            if isTestRecording {
                Label("正在录音…", systemImage: "mic.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            } else if isTranscribing {
                Text("识别中…")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 「测试连接」按钮（结果由 connectionTestResult 单独渲染在按钮行下方）
    private func connectionTestButton(
        isRunning: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button(isRunning ? "测试中…" : "测试连接") {
            Task { await action() }
        }
        .disabled(isRunning)
        // 强调色填充：配置档行里使用频率最高的主操作，与相邻的普通按钮区分开
        .buttonStyle(.borderedProminent)
    }

    // MARK: - 配置档公共组件（识别引擎页 / 文字优化页共用）

    /// 配置档三字段（Base URL / API Key / 模型名称）+ 缺字段提示
    @ViewBuilder
    private func profileFieldsSection(
        selection: UUID?,
        baseLabel: String,
        onBaseChange: @escaping (String) -> Void,
        onKeyChange: @escaping (String) -> Void,
        onModelChange: @escaping (String) -> Void,
        missingWarning: String?
    ) -> some View {
        TextField(baseLabel, text: profileFieldBinding(selection: selection, keyPath: \.baseURL, onActiveChange: onBaseChange))
        SecureField("API Key", text: profileFieldBinding(selection: selection, keyPath: \.apiKey, onActiveChange: onKeyChange))
        TextField("模型名称", text: profileFieldBinding(selection: selection, keyPath: \.modelName, onActiveChange: onModelChange))
        if let missingWarning {
            Text(missingWarning)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// 配置操作行：添加 / 删除当前配置 / 测试连接 + 测试结果
    @ViewBuilder
    private func profileActionRow(
        target: Page,
        selected: APIProfile?,
        isTesting: Bool,
        testResult: SpeechManager.ConnectionTestResult?,
        onTest: @escaping () async -> Void
    ) -> some View {
        HStack {
            Button("＋ 添加配置") {
                addProfileTarget = target
                newProfileName = ""
                isAddingProfile = true
            }
            Button("删除当前配置", role: .destructive) {
                profilePendingDelete = selected
            }
            .disabled(profileStore.profiles.count <= 1)
            connectionTestButton(isRunning: isTesting) {
                await onTest()
            }
        }
        connectionTestResult(testResult)
    }

    /// 连接测试结果：独立一行显示在按钮行下方，避免挤在按钮右侧
    @ViewBuilder
    private func connectionTestResult(_ result: SpeechManager.ConnectionTestResult?) -> some View {
        if let result {
            Label(result.displayText, systemImage: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(result.isSuccess ? Color.green : Color.red)
                .textSelection(.enabled)
        }
    }

    // MARK: - 文字优化
    @ViewBuilder
    private var polishPage: some View {
        Section {
            Toggle("启用文字优化", isOn: $speech.polishEnabled)
        }

        if speech.polishEnabled {
            Section("优化模型（OpenAI 兼容）") {
                polishProfilePicker
                profileFieldsSection(
                    selection: profileStore.polishSelectionID,
                    baseLabel: "接口地址",
                    onBaseChange: { speech.polishAPIBaseURL = $0 },
                    onKeyChange: { speech.polishAPIKey = $0 },
                    onModelChange: { speech.polishModelName = $0 },
                    missingWarning: (speech.polishAPIBaseURL.isEmpty || speech.polishModelName.isEmpty)
                        ? "需要填写接口地址和模型名称才能启用文字优化。" : nil
                )
                profileActionRow(
                    target: .polish,
                    selected: profileStore.selectedPolish,
                    isTesting: isTestingPolishConnection,
                    testResult: polishConnectionTest
                ) {
                    isTestingPolishConnection = true
                    polishConnectionTest = nil
                    let base = speech.polishAPIBaseURL
                    let key = speech.polishAPIKey
                    let model = speech.polishModelName
                    let result = await SpeechManager.shared.testAPIConnection(baseURL: base, apiKey: key, model: model)
                    polishConnectionTest = result
                    isTestingPolishConnection = false
                }
            }

            Section("优化指令（Prompt）") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $speech.polishPromptTemplate)
                        .frame(height: 96)
                        .scrollContentBackground(.hidden)
                    if speech.polishPromptTemplate.isEmpty {
                        Text("留空使用系统默认优化指令")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                // 恢复默认 = 清空自定义指令（空值即跟随系统默认，保持随版本改进）
                HStack {
                    Spacer()
                    Button("恢复默认指令") {
                        speech.polishPromptTemplate = ""
                    }
                    .font(.footnote)
                    .buttonStyle(.link)
                    .disabled(speech.polishPromptTemplate.isEmpty)
                }
            }

            Section {
                Text("启用后每次输出会多一次模型调用，输出延迟会相应增加；优化失败时将直接使用原始转写结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 翻译（连击翻译：独立接口档 + 触发方式）
    @ViewBuilder
    private var translatePage: some View {
        Section {
            Toggle("启用连击翻译", isOn: $speech.translateEnabled)
                .onChange(of: speech.translateEnabled) { _, _ in
                    if !speech.translateEnabled { stopTranslateKeyCapture() }
                }
        }

        if speech.translateEnabled {
            Section("翻译接口（OpenAI 兼容）") {
                translateProfilePicker
                profileFieldsSection(
                    selection: profileStore.translateSelectionID,
                    baseLabel: "接口地址",
                    onBaseChange: { speech.translateAPIBaseURL = $0 },
                    onKeyChange: { speech.translateAPIKey = $0 },
                    onModelChange: { speech.translateModelName = $0 },
                    missingWarning: (speech.translateAPIBaseURL.isEmpty || speech.translateModelName.isEmpty)
                        ? "需要填写接口地址和模型名称才能使用连击翻译。" : nil
                )
                profileActionRow(
                    target: .translate,
                    selected: profileStore.selectedTranslate,
                    isTesting: isTestingTranslateConnection,
                    testResult: translateConnectionTest
                ) {
                    isTestingTranslateConnection = true
                    translateConnectionTest = nil
                    let base = speech.translateAPIBaseURL
                    let key = speech.translateAPIKey
                    let model = speech.translateModelName
                    let result = await SpeechManager.shared.testAPIConnection(baseURL: base, apiKey: key, model: model)
                    translateConnectionTest = result
                    isTestingTranslateConnection = false
                }
            }

            Section("触发") {
                HStack {
                    Text("触发键")
                    Spacer()
                    Button(isCapturingTranslateKey ? "请按键…（Esc 取消）" : HotkeyInputManager.translateKeyName(translateKey)) {
                        toggleTranslateKeyCapture()
                    }
                }

                Picker("连击次数", selection: $translateTapCount) {
                    Text("2 次").tag(2)
                    Text("3 次").tag(3)
                    Text("4 次").tag(4)
                    Text("5 次").tag(5)
                }
                .onChange(of: translateTapCount) { _, newValue in
                    HotkeyInputManager.shared.translateTapCount = newValue
                }

                Picker("间隔上限", selection: $translateInterval) {
                    Text("0.4 秒").tag(0.4)
                    Text("0.6 秒").tag(0.6)
                    Text("0.9 秒").tag(0.9)
                }
                .onChange(of: translateInterval) { _, newValue in
                    HotkeyInputManager.shared.translateInterval = newValue
                }

                Picker("目标语言", selection: $speech.translateTarget) {
                    ForEach(TranslateTarget.allCases) { target in
                        Text(target.rawValue).tag(target)
                    }
                }

                if let translateKeyError {
                    Text(translateKeyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                ForEach(translateShortcutConflictWarnings, id: \.self) { msg in
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Text("连按触发键到设定次数即翻译：输入框里有选区则替换选区、没有则替换全部；选中的是静态文本（网页等）时，译文显示在选区旁的弹窗里。触发键支持修饰键，如单独按 Shift。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // 无辅助功能权限时 NSEvent 全局键盘 monitor 静默不投递事件，
                // 表现是"按了完全没反应"且没有任何报错——必须在这里显式告知。
                if !AXIsProcessTrusted() {
                    Label("需要在「系统设置 → 隐私与安全性 → 辅助功能」中授权 SoundIn，否则无法监听按键。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - 连击翻译触发键录制

    private func toggleTranslateKeyCapture() {
        if isCapturingTranslateKey {
            stopTranslateKeyCapture()
            return
        }
        translateKeyError = nil
        isCapturingTranslateKey = true
        HotkeyInputManager.shared.onTriggerKeyCaptureComplete = { code in
            isCapturingTranslateKey = false
            translateKeyError = nil
            translateKey = code
            HotkeyInputManager.shared.translateKey = code
        }
        HotkeyInputManager.shared.onTriggerKeyCaptureCancelled = {
            isCapturingTranslateKey = false
        }
        HotkeyInputManager.shared.beginTriggerKeyCapture(
            onReject: { message in
                // 非法键不结束录制：按钮保持"请按键…"，用户直接重按即可
                translateKeyError = message
            }
        )
    }

    private func stopTranslateKeyCapture() {
        isCapturingTranslateKey = false
        HotkeyInputManager.shared.endTriggerKeyCapture()
    }

    // MARK: - 录音测试（引擎页底部区块）

    /// 设置页内的语音转文字测试：走与快捷键完全相同的识别链路（仅显示原始转写，不含文字优化）
    private func toggleTestRecording() {
        if isTestRecording {
            isTestRecording = false
            isTranscribing = true
            Task { @MainActor in
                let text = await SpeechManager.shared.stopRecordingAndWaitForText()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 区分「没说话」与「说了但识别失败」，给出针对性提示
                testResult = trimmed.isEmpty
                    ? (SpeechManager.shared.hasDetectedSpeech
                        ? "（未识别到内容，请检查配置或重试）"
                        : "（未检测到声音，请说话后再试）")
                    : trimmed
                isTranscribing = false
                SpeechManager.shared.resetSession()
            }
        } else {
            testResult = ""
            SpeechManager.shared.useSegmentedAPIRecording =
                speech.recognitionProvider == .api && SpeechManager.shared.preferSegmentedTranscription
            SpeechManager.shared.startRecordingSafe()
            if SpeechManager.shared.isRecording {
                isTestRecording = true
            } else {
                // isRecording 为 false 有两种可能：
                //  (a) 麦克风/语音识别权限「待定」(.notDetermined)——startRecordingSafe 已弹出系统授权框，
                //      用户允许后 requestPermissions 回调会自动启动录音，这属于「进行中」，不是失败；
                //  (b) 权限被拒或启动真的失败——errorMessage 已写明原因。
                // 只有 (b) 才报「无法开始录音」，避免授权弹窗刚弹出就被误报成失败。
                let mic = AVCaptureDevice.authorizationStatus(for: .audio)
                let needsSpeech = SpeechManager.shared.recognitionProvider != .api
                let speechPending = needsSpeech && SFSpeechRecognizer.authorizationStatus() == .notDetermined
                if mic == .notDetermined || speechPending {
                    isTestRecording = true
                    testResult = "已在系统弹窗中请求麦克风授权，允许后即可开始录音"
                } else {
                    isTestRecording = false
                    testResult = SpeechManager.shared.errorMessage ?? "无法开始录音，请检查麦克风权限"
                }
            }
        }
    }

    // MARK: - 统计
    @ViewBuilder
    private var statsPage: some View {
        Section("听写统计") {
            HStack(spacing: 10) {
                statBox(value: stats.todayCount, label: "今日", highlight: true)
                statBox(value: stats.weekCount, label: "本周")
                statBox(value: stats.totalCount, label: "累计（近半年）")
            }
            .padding(.vertical, 4)
        }

        Section("最近半年") {
            DictationHeatmapView(cells: stats.heatmapCells(weeks: 26))
        }

        Section("最近输入") {
            // 保留条数就放在列表旁边：调小立即裁剪，所见即所留
            Picker("保留条数", selection: Binding(
                get: { history.maxEntries },
                set: { history.maxEntries = $0 }
            )) {
                ForEach(InputHistory.limitChoices, id: \.self) { limit in
                    Text("\(limit) 条").tag(limit)
                }
            }

            if history.entries.isEmpty {
                Text("暂无记录，语音输入成功后显示在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.entries) { entry in
                    // 完整换行显示：不限行数、允许纵向撑高，长文本不会被截断；
                    // 时间/复制按钮对齐首行，避免在大段文本旁垂直居中显得悬空
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Text(InputHistory.timeText(entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("复制") { history.copyToPasteboard(entry) }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
                HStack(spacing: 14) {
                    Button("导出") { exportHistory() }
                    Button("清空历史", role: .destructive) { isConfirmingClearHistory = true }
                }
            }
        }
    }

    /// 导出历史为纯文本文件：NSSavePanel 让用户选位置；失败只记日志（导出非关键路径）
    private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "SoundIn-输入历史.txt"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try InputHistory.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
                HotkeyFileLog.shared.log("history: exported \(InputHistory.shared.entries.count) entries")
            } catch {
                HotkeyFileLog.shared.log("history: export failed — \(error.localizedDescription)")
            }
        }
    }

    private func statBox(value: Int, label: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlight ? Color(red: 0.44, green: 0.62, blue: 0.24) : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlight ? Color(red: 0.96, green: 0.98, blue: 0.93) : Color.primary.opacity(0.04))
        )
    }

    // MARK: - 关于
    @ViewBuilder
    private var aboutPage: some View {
        Section("版本") {
            LabeledContent("SoundIn 声入", value: appVersion)
            LabeledContent("定位", value: "语音输入工具")
        }

        Section("更新") {
            Toggle("自动检查更新", isOn: Binding(
                get: { AppUpdater.shared.automaticallyChecksForUpdates },
                set: { AppUpdater.shared.setAutomaticChecks($0) }
            ))
            Button("检查更新") {
                AppUpdater.shared.checkForUpdatesManually()
            }
        }

        Section("权限状态") {
            // 读一次 authRevision 让 body 对刷新计数产生依赖：revision 变化 → 重查权限
            let auth = authSnapshot
            permissionRow(title: "麦克风", granted: auth.micAuthorized, undetermined: auth.micNotDetermined,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            permissionRow(title: "语音识别", granted: auth.speechAuthorized, undetermined: auth.speechNotDetermined,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            permissionRow(title: "辅助功能（按键监听/模拟粘贴）", granted: auth.axTrusted, undetermined: false,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Text("未授权项可点「去授权」直达对应设置面板；辅助功能换版本后失效时，在面板中删除旧条目重新添加即可。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // 授权完从系统设置切回本应用 → 触发重查
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authRevision += 1
        }
        // 应用内系统授权弹窗里点「允许」不会走 activation 事件 → 可见期间每 2 秒兜底轮询
        //（三次 TCC 查询开销可忽略；区块随页面切走自动停表）
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            authRevision += 1
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version! : "开发版"
    }

    private var authSnapshot: (micAuthorized: Bool, micNotDetermined: Bool,
                               speechAuthorized: Bool, speechNotDetermined: Bool, axTrusted: Bool) {
        _ = authRevision  // 建立依赖：仅为此让 SwiftUI 在刷新计数变化时重算本快照
        return (
            micAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            micNotDetermined: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined,
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized,
            speechNotDetermined: SFSpeechRecognizer.authorizationStatus() == .notDetermined,
            axTrusted: AXIsProcessTrusted()
        )
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, undetermined: Bool, panel: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if undetermined {
                Label("待授权", systemImage: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                if let panel {
                    Button("去授权") { openSettingsPanel(panel) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            } else {
                Label("未授权", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                if let panel {
                    Button("去授权") { openSettingsPanel(panel) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    /// 打开系统设置对应隐私面板
    private func openSettingsPanel(_ panel: String) {
        guard let url = URL(string: panel) else { return }
        NSWorkspace.shared.open(url)
    }
}
