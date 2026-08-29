import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import Speech

enum VoiceInputPhase {
    case idle
    case recording
    case transcribing
    case success
    case clipboardFallback
    case cancelled
    case permissionDenied(message: String)
    case failure(message: String)
}

extension Notification.Name {
    static let voicePhaseChanged = Notification.Name("voicePhaseChanged")
}

@main
struct VoiceScribeApp: App {
    @State private var speechManager = SpeechManager.shared
    @State private var phase: VoiceInputPhase = VoiceScribeApp.currentPhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            VStack {
                Text(statusText).foregroundStyle(.secondary)
                Button("设置…") {
                    // 常规原生窗口：可缩放、三个窗口按钮均可用
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider()
                Button("退出") { NSApp.terminate(nil) }
            }
            .padding(8)
            // 菜单栏此前从未订阅 voicePhaseChanged，图标与状态文字永远停留在初始值
            .onReceive(NotificationCenter.default.publisher(for: .voicePhaseChanged)) { _ in
                phase = VoiceScribeApp.currentPhase
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
        case .success: "已输入到光标"
        case .clipboardFallback: "已复制，请手动粘贴"
        case .cancelled: "已取消"
        case .permissionDenied(let message), .failure(let message): message
        }
    }

    static var currentPhase: VoiceInputPhase = .idle {
        didSet { NotificationCenter.default.post(name: .voicePhaseChanged, object: nil) }
    }

    /// SoundIn 品牌状态栏图标：与 App 图标同构「三根声波条(渐弱) + 输入块 + 细光标」
    /// 按 gen_icon.py 的几何比例缩放（1024 → 16pt，k=0.03125），isTemplate 自适应深浅色
    static let brandMenuBarIcon: NSImage = {
        let canvas: CGFloat = 16
        // gen_icon.py 尺寸 × k
        let k: CGFloat = 0.03125
        let barW = 48 * k      // 1.5
        let gap = 48 * k       // 1.5
        let blockW = 80 * k    // 2.5（对应 App 图标的绿色输入块）
        let cursorW = 40 * k   // 1.25
        let startX = (canvas - (456 * k)) / 2   // 整体水平居中
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            NSColor.black.setFill()
            var x = startX
            // 左侧白色声波（透明度渐弱，与 App 图标一致）
            for (heightRaw, alpha) in [(160.0, 1.0), (288.0, 0.8), (416.0, 0.55)] {
                let h = CGFloat(heightRaw) * k
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: (canvas - h) / 2, width: barW, height: h),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            // 输入块 + 细光标（等高）
            let blockH = 384 * k
            for width in [blockW, cursorW] {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: (canvas - blockH) / 2, width: width, height: blockH),
                             xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
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
        case .success: "checkmark.circle.fill"
        case .clipboardFallback: "doc.on.doc.fill"
        case .cancelled: "xmark.circle.fill"
        case .permissionDenied, .failure: "exclamationmark.triangle.fill"
        }
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyFileLog.shared.log("=== app launched ===")
        HotkeyFileLog.shared.log("axTrusted at launch = \(AXIsProcessTrusted())")
        NSApp.setActivationPolicy(.accessory)
        // 把识别/润色各自选中的 API 配置档回写进 SpeechManager（升级迁移后保证活动值一致）
        APIProfileStore.shared.applyActive(to: SpeechManager.shared)
        HotkeyInputManager.shared.start()
        HotkeyInputManager.shared.onStateChange = { newPhase in
            Task { @MainActor in
                VoiceScribeApp.currentPhase = newPhase
                // 底部胶囊 HUD 跟随语音输入状态（移植自 reme）
                VoiceInputHUDManager.shared.apply(voicePhase: newPhase)
            }
        }
    }
}

private struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, hotkeys, engine, polish, test, stats, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .hotkeys: "快捷键"
            case .engine: "识别引擎"
            case .polish: "文字优化"
            case .test: "录音测试"
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
            case .test: "checkmark.bubble"
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
    @State private var isConfirmingClearHistory = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPage) {
                ForEach(Page.allCases) { page in
                    Label(page.title, systemImage: page.icon).tag(page)
                }
            }
            .navigationSplitViewColumnWidth(min: 130, ideal: 148, max: 176)
        } detail: {
            Form {
            switch selectedPage {
            case .general: generalPage
            case .hotkeys: hotkeysPage
            case .engine: enginePage
            case .polish: polishPage
            case .test: testPage
            case .stats: statsPage
            case .about: aboutPage
            }
            }
            .formStyle(.grouped)
        }
        .alert("新建配置档", isPresented: $isAddingProfile) {
            TextField("名称", text: $newProfileName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let profile = profileStore.addProfile(named: newProfileName)
                if addProfileTarget == .engine {
                    selectEngineProfile(profile.id)
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
                    profileStore.deleteProfile(pending.id)
                    if wasEngine || wasPolish {
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
                // 配置字段变化后，两页的连接测试结果都可能与当前配置不一致，统一失效
                engineConnectionTest = nil
                polishConnectionTest = nil
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
        } footer: {
            Text("单击键：点一下开始，再点一下结束。长按键：按住说话，松开自动识别并输入。录音中按 Esc 取消。")
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
            Text("点击后按下任意按键即可：单键、组合键、或仅修饰键（如 ⌘⌥）均可。Esc 取消。")
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
                let msg = "修饰键热键需要在「系统设置 → 隐私与安全性 → 输入监控」中授权 VoiceScribe，才能在所有应用中生效。"
                if seen.insert(msg).inserted { result.append(msg) }
            } else if !shortcut.modifiers.contains([.command, .control, .option, .shift]) {
                let msg = "当前是单键热键：该按键会被全局接管，在其他应用中按下它将不会正常输入。"
                if seen.insert(msg).inserted { result.append(msg) }
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
                    missingWarning: (speech.speechAPIBaseURL.isEmpty || speech.speechAPIKey.isEmpty || speech.speechModelName.isEmpty)
                        ? "API 模式需要填写 Base URL、API Key 和模型名称。" : nil
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
                Text("下方字段即当前选中的配置，直接修改会保存回该配置档。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        } footer: {
            Text("语音转写完成后，可选地用大语言模型润色文字再输出：修正错别字、去除语气词、整理为书面语。")
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
                Text("系统默认指令会将转写结果整理为通顺书面语并保持原意，此处自定义后以你的指令为准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("启用后每次输出会多一次模型调用，输出延迟会相应增加；优化失败时将直接使用原始转写结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 录音测试
    @ViewBuilder
    private var testPage: some View {
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
            } else if isTestRecording || isTranscribing {
                Text("说几句话，然后点「停止并识别」查看转写结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

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
            isTestRecording = SpeechManager.shared.isRecording
            if !isTestRecording {
                testResult = SpeechManager.shared.errorMessage ?? "无法开始录音，请检查麦克风权限"
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
                statBox(value: stats.totalCount, label: "累计（保留期内）")
            }
            .padding(.vertical, 4)
        }

        Section("最近 13 周") {
            DictationHeatmapView(cells: stats.heatmapCells(weeks: 13))
        }

        Section("最近输入") {
            if history.entries.isEmpty {
                Text("暂无记录，语音输入成功后显示在这里（最多保留 10 条）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.entries) { entry in
                    HStack(spacing: 10) {
                        Text(entry.text)
                            .lineLimit(1)
                            .help(entry.text)
                        Spacer()
                        Text(InputHistory.timeText(entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("复制") { history.copyToPasteboard(entry) }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
                Button("清空历史", role: .destructive) { isConfirmingClearHistory = true }
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

        Section("权限状态") {
            permissionRow(title: "麦克风", granted: micAuthorized, undetermined: micNotDetermined,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            permissionRow(title: "语音识别", granted: speechAuthorized, undetermined: speechNotDetermined,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            permissionRow(title: "辅助功能（模拟粘贴）", granted: AXIsProcessTrusted(), undetermined: false,
                         panel: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            Text("未授权项可点「去授权」直达对应设置面板；辅助功能换版本后失效时，在面板中删除旧条目重新添加即可。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version! : "开发版"
    }

    private var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    private var micNotDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
    private var speechAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    private var speechNotDetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
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
