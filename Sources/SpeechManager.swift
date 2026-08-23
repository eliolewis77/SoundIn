import Foundation
import Speech
import SwiftUI
import AVFoundation
import CoreAudio

/// A thread-safe audio buffer handler for speech recognition
/// This class handles audio capture on the audio thread without MainActor isolation
private final class AudioBufferHandler: @unchecked Sendable {
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    
    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        recognitionRequest = request
    }
    
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = recognitionRequest
        lock.unlock()
        request?.append(buffer)
    }
    
    func endAudio() {
        lock.lock()
        let request = recognitionRequest
        recognitionRequest = nil
        lock.unlock()
        // Call endAudio outside the lock to prevent potential deadlock
        request?.endAudio()
    }
}

private final class AudioFileBufferWriter: @unchecked Sendable {
    private var audioFile: AVAudioFile?
    private let lock = NSLock()

    func setFile(_ file: AVAudioFile?) {
        lock.lock()
        defer { lock.unlock() }
        audioFile = file
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = audioFile
        lock.unlock()

        do {
            try file?.write(from: buffer)
        } catch {
            #if DEBUG
            print("❌ Audio file write error: \(error.localizedDescription)")
            #endif
        }
    }

    func close() {
        setFile(nil)
    }
}

private struct SpeechAudioSegment: Sendable {
    let index: Int
    let url: URL
}

private final class SegmentedAudioFileWriter: @unchecked Sendable {
    private struct RecentBuffer {
        let buffer: AVAudioPCMBuffer
        let frameLength: AVAudioFrameCount
    }

    private let lock = NSLock()
    private var segmentFile: AVAudioFile?
    private var fullAudioFile: AVAudioFile?
    private var recordingFormat: AVAudioFormat?
    private var sessionID: UUID?
    private var nextIndex = 0
    private var currentURL: URL?
    private var fullURL: URL?
    private var completedSegments: [SpeechAudioSegment] = []
    private var recentBuffers: [RecentBuffer] = []
    private var recentFrameCount: AVAudioFramePosition = 0
    private var currentSegmentFrameCount: AVAudioFramePosition = 0
    private var fullFrameCount: AVAudioFramePosition = 0
    private var consecutiveSilentFrames: AVAudioFramePosition = 0
    private var currentSegmentHasSpeech = false

    private let shortAudioDuration: TimeInterval = 20
    private let minimumSegmentDuration: TimeInterval = 8
    private let maximumSegmentDuration: TimeInterval = 25
    private let minimumSilenceDuration: TimeInterval = 0.45
    private let overlapDuration: TimeInterval = 0.4
    private let silencePowerThreshold: Float = -45
    private let speechPowerThreshold: Float = -42

    func start(sessionID: UUID, format: AVAudioFormat) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        resetLocked()
        self.sessionID = sessionID
        self.recordingFormat = format
        self.nextIndex = 0

        let fullURL = Self.audioURL(sessionID: sessionID, name: "full")
        self.fullURL = fullURL
        self.fullAudioFile = try AVAudioFile(forWriting: fullURL, settings: format.settings)
        self.segmentFile = try createNextSegmentFileLocked()
        return fullURL
    }

    func write(_ buffer: AVAudioPCMBuffer) -> SpeechAudioSegment? {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fullAudioFile?.write(from: buffer)
            try segmentFile?.write(from: buffer)
            appendRecentBufferLocked(buffer)
            updateSegmentStateLocked(with: buffer)

            guard shouldRotateSegmentLocked() else { return nil }
            return try rotateSegmentLocked()
        } catch {
            #if DEBUG
            print("❌ Segmented audio write error: \(error.localizedDescription)")
            #endif
            return nil
        }
    }


    func finish() -> (segments: [SpeechAudioSegment], cleanupSegments: [SpeechAudioSegment], fullURL: URL?, shouldUseSegments: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let sampleRate = recordingFormat?.sampleRate ?? 0
        let fullDuration = sampleRate > 0 ? Double(fullFrameCount) / sampleRate : 0
        let shouldUseSegments = fullDuration >= shortAudioDuration
        var segments = shouldUseSegments ? completedSegments : []
        var cleanupSegments: [SpeechAudioSegment] = []

        if let currentURL {
            let currentSegment = SpeechAudioSegment(index: nextIndex - 1, url: currentURL)
            if shouldUseSegments, currentSegmentHasSpeech {
                segments.append(currentSegment)
            } else {
                cleanupSegments.append(currentSegment)
            }
        }

        let fullURL = self.fullURL
        segmentFile = nil
        fullAudioFile = nil
        currentURL = nil
        self.fullURL = nil
        recordingFormat = nil
        sessionID = nil
        completedSegments.removeAll()
        recentBuffers.removeAll()
        recentFrameCount = 0
        currentSegmentFrameCount = 0
        fullFrameCount = 0
        consecutiveSilentFrames = 0
        currentSegmentHasSpeech = false
        return (segments, cleanupSegments, fullURL, shouldUseSegments)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    private func createNextSegmentFileLocked() throws -> AVAudioFile {
        guard let sessionID, let recordingFormat else {
            throw CocoaError(.fileNoSuchFile)
        }

        let url = Self.audioURL(sessionID: sessionID, name: "segment-\(nextIndex)")
        currentURL = url
        nextIndex += 1
        return try AVAudioFile(forWriting: url, settings: recordingFormat.settings)
    }

    private func rotateSegmentLocked() throws -> SpeechAudioSegment? {
        guard let currentURL else { return nil }
        let completed = SpeechAudioSegment(index: nextIndex - 1, url: currentURL)
        completedSegments.append(completed)
        segmentFile = nil
        segmentFile = try createNextSegmentFileLocked()
        currentSegmentFrameCount = 0
        consecutiveSilentFrames = 0
        currentSegmentHasSpeech = false
        writeOverlapBuffersLocked()
        return completed
    }

    private func writeOverlapBuffersLocked() {
        guard let segmentFile else { return }

        for recentBuffer in recentBuffers {
            do {
                try segmentFile.write(from: recentBuffer.buffer)
                currentSegmentFrameCount += AVAudioFramePosition(recentBuffer.frameLength)
            } catch {
                #if DEBUG
                print("❌ Segment overlap write error: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func appendRecentBufferLocked(_ buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = Self.copyBuffer(buffer) else { return }
        recentBuffers.append(RecentBuffer(buffer: copiedBuffer, frameLength: copiedBuffer.frameLength))
        recentFrameCount += AVAudioFramePosition(copiedBuffer.frameLength)

        guard let recordingFormat else { return }
        let maxFrames = AVAudioFramePosition(recordingFormat.sampleRate * overlapDuration)
        while recentFrameCount > maxFrames, let first = recentBuffers.first {
            recentFrameCount -= AVAudioFramePosition(first.frameLength)
            recentBuffers.removeFirst()
        }
    }

    private func updateSegmentStateLocked(with buffer: AVAudioPCMBuffer) {
        let frameLength = AVAudioFramePosition(buffer.frameLength)
        currentSegmentFrameCount += frameLength
        fullFrameCount += frameLength

        let averagePower = Self.averagePower(buffer)
        if averagePower <= silencePowerThreshold {
            consecutiveSilentFrames += frameLength
        } else {
            consecutiveSilentFrames = 0
        }

        if averagePower >= speechPowerThreshold {
            currentSegmentHasSpeech = true
        }
    }

    private func shouldRotateSegmentLocked() -> Bool {
        guard let recordingFormat, currentSegmentHasSpeech else { return false }

        let sampleRate = recordingFormat.sampleRate
        let minimumFrames = AVAudioFramePosition(sampleRate * minimumSegmentDuration)
        let maximumFrames = AVAudioFramePosition(sampleRate * maximumSegmentDuration)
        let requiredSilenceFrames = AVAudioFramePosition(sampleRate * minimumSilenceDuration)

        guard currentSegmentFrameCount >= minimumFrames else { return false }
        if currentSegmentFrameCount >= maximumFrames { return true }
        return consecutiveSilentFrames >= requiredSilenceFrames
    }

    private func resetLocked() {
        segmentFile = nil
        fullAudioFile = nil
        recordingFormat = nil
        sessionID = nil
        nextIndex = 0
        currentURL = nil
        fullURL = nil
        completedSegments.removeAll()
        recentBuffers.removeAll()
        recentFrameCount = 0
        currentSegmentFrameCount = 0
        fullFrameCount = 0
        consecutiveSilentFrames = 0
        currentSegmentHasSpeech = false
    }

    private static func audioURL(sessionID: UUID, name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voicescribe-speech-\(sessionID.uuidString)-\(name).wav")
    }

    private static func averagePower(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return -100 }

        var sum: Float = 0
        var sampleCount = 0

        if let data = buffer.floatChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = data[channel][frame]
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = Float(data[channel][frame]) / Float(Int16.max)
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = Float(data[channel][frame]) / Float(Int32.max)
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return -100 }
        let rms = sqrt(sum / Float(sampleCount))
        return 20 * log10(max(rms, 1e-10))
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }

        copy.frameLength = buffer.frameLength
        let frameLength = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameLength)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameLength)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].update(from: source[channel], count: frameLength)
            }
        }

        return copy
    }
}

private actor TranscriptionConcurrencyLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}

private struct SpeechTranscriptionResponse: Decodable {
    let text: String
}

/// 把音频/后台线程的事件安全投递回主线程。
/// AVAudioEngine tap、语音识别回调都在非主线程上触发，且 Swift 6 会推断
/// 在 @MainActor 方法内创建的闭包继承主线程隔离——直接访问主线程状态会在
/// 运行时触发 dispatch_assert_queue_fail 崩溃。用此通道显式跳回主线程。
private final class MainActorEventSink<T>: @unchecked Sendable {
    private let apply: @MainActor (T) -> Void

    init(_ apply: @escaping @MainActor (T) -> Void) {
        self.apply = apply
    }

    func send(_ value: T) {
        // 值只被转移到主线程且本地不再使用，装箱以通过隔离检查是安全的
        let box = UnsafeSendableBox(value: value)
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.apply(box.value) }
        } else {
            Task { @MainActor in
                self.apply(box.value)
            }
        }
    }
}

private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
}

@Observable
@MainActor
final class SpeechManager: NSObject, SFSpeechRecognizerDelegate {    static let shared = SpeechManager()

    enum RecognitionProvider: String, Hashable {
        case local
        case api
    }

    enum RecognitionLanguage: String, Hashable, CaseIterable {
        case followSystem
        case zhCN
        case enUS
        case jaJP
    }
    
    // MARK: - Properties
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    // Guards against double installTap/removeTap, which would otherwise crash
    private var isTapInstalled = false

    // Thread-safe buffer handler for audio capture thread
    private let bufferHandler = AudioBufferHandler()
    private let audioFileWriter = AudioFileBufferWriter()
    private let segmentedAudioWriter = SegmentedAudioFileWriter()
    private let segmentTranscriptionLimiter = TranscriptionConcurrencyLimiter(limit: 2)
    private var recordedAudioURL: URL?
    private var completedSpeechSegments: [SpeechAudioSegment] = []
    private var segmentTranscriptionTasks: [Int: Task<String?, Never>] = [:]
    // ── 用户设置：UserDefaults 持久化（重启后保留）──
    // 注意：API Key 以明文存储在 UserDefaults，如需更高安全性应迁移到 Keychain
    var recognitionProvider: RecognitionProvider = SpeechManager.loadProvider() {
        didSet { UserDefaults.standard.set(recognitionProvider.rawValue, forKey: "vs.recognitionProvider") }
    }
    var recognitionLanguage: RecognitionLanguage = SpeechManager.loadLanguage() {
        didSet { UserDefaults.standard.set(recognitionLanguage.rawValue, forKey: "vs.recognitionLanguage") }
    }
    var speechAPIBaseURL: String = UserDefaults.standard.string(forKey: "vs.apiBaseURL") ?? "https://api.openai.com/v1" {
        didSet { UserDefaults.standard.set(speechAPIBaseURL, forKey: "vs.apiBaseURL") }
    }
    var speechAPIKey: String = UserDefaults.standard.string(forKey: "vs.apiKey") ?? "" {
        didSet { UserDefaults.standard.set(speechAPIKey, forKey: "vs.apiKey") }
    }
    var speechModelName: String = UserDefaults.standard.string(forKey: "vs.apiModel") ?? "whisper-1" {
        didSet { UserDefaults.standard.set(speechModelName, forKey: "vs.apiModel") }
    }
    /// 用户偏好：API 模式下是否启用长录音分段转写
    var preferSegmentedTranscription: Bool = UserDefaults.standard.object(forKey: "vs.preferSegmented") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preferSegmentedTranscription, forKey: "vs.preferSegmented") }
    }

    // ── 文字优化（LLM 润色）设置：与识别引擎的 API 配置相互独立 ──
    var polishEnabled: Bool = UserDefaults.standard.object(forKey: "vs.polishEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(polishEnabled, forKey: "vs.polishEnabled") }
    }
    var polishAPIBaseURL: String = UserDefaults.standard.string(forKey: "vs.polishBaseURL") ?? "https://api.openai.com/v1" {
        didSet { UserDefaults.standard.set(polishAPIBaseURL, forKey: "vs.polishBaseURL") }
    }
    var polishAPIKey: String = UserDefaults.standard.string(forKey: "vs.polishAPIKey") ?? "" {
        didSet { UserDefaults.standard.set(polishAPIKey, forKey: "vs.polishAPIKey") }
    }
    var polishModelName: String = UserDefaults.standard.string(forKey: "vs.polishModel") ?? "gpt-4o-mini" {
        didSet { UserDefaults.standard.set(polishModelName, forKey: "vs.polishModel") }
    }
    /// 用户自定义优化指令；为空时使用系统默认（defaultPolishPrompt，UI 上不可见）
    var polishPromptTemplate: String = UserDefaults.standard.string(forKey: "vs.polishPrompt") ?? "" {
        didSet { UserDefaults.standard.set(polishPromptTemplate, forKey: "vs.polishPrompt") }
    }

    static let defaultPolishPrompt =
        "将语音转写结果整理为通顺的书面语：修正错别字和口误，去除语气词，保持原意与原语言，不要添加任何内容。只输出整理后的文字。"

    // MARK: - 连接测试

    enum ConnectionTestResult {
        case ok(detail: String)
        case failed(message: String)

        var displayText: String {
            switch self {
            case .ok(let detail): return detail
            case .failed(let message): return message
            }
        }

        var isSuccess: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    /// 向 OpenAI 兼容接口的 /models 发轻量请求，验证地址可达、Key 有效、模型是否在服务端列表。
    /// 注意：部分本地单模型服务不校验 model 字段也不提供 /models，此时返回"连接成功但无列表"。
    func testAPIConnection(baseURL: String, apiKey: String, model: String) async -> ConnectionTestResult {
        let cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty else { return .failed(message: "请先填写接口地址") }

        let normalizedBase = cleanBase.hasSuffix("/") ? String(cleanBase.dropLast()) : cleanBase
        guard let url = URL(string: normalizedBase)?.appendingPathComponent("models") else {
            return .failed(message: "接口地址格式无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let first = await executeConnectionTest(request, baseURL: normalizedBase, model: cleanModel)
        if first.result.isSuccess { return first.result }

        // 应用启动后首次访问局域网地址时，macOS 可能尚未完成本地网络放行，
        // 请求会以 -1009「似乎已断开与互联网的连接」失败；这次失败本身会触发放行，
        // 因此对这类瞬时错误自动重试一次（间隔 0.8 秒），用户无感。
        if first.isTransientNetworkFailure {
            try? await Task.sleep(for: .milliseconds(800))
            HotkeyFileLog.shared.log("conn-test: retry after transient network failure")
            return (await executeConnectionTest(request, baseURL: normalizedBase, model: cleanModel)).result
        }
        return first.result
    }

    private static func transientCode(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    private func executeConnectionTest(_ request: URLRequest, baseURL normalizedBase: String, model cleanModel: String) async -> (result: ConnectionTestResult, isTransientNetworkFailure: Bool) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (ConnectionTestResult.failed(message: "无效的服务端响应"), false)
            }
            switch http.statusCode {
            case 200:
                HotkeyFileLog.shared.log("conn-test: ok \(normalizedBase)")
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["data"] as? [[String: Any]] {
                    let ids = list.compactMap { $0["id"] as? String }
                    if ids.isEmpty {
                        return (ConnectionTestResult.ok(detail: "连接成功（服务端未返回模型列表）"), false)
                    }
                    if !cleanModel.isEmpty && ids.contains(cleanModel) {
                        return (ConnectionTestResult.ok(detail: "连接成功，模型「\(cleanModel)」已在服务端列表中"), false)
                    }
                    let preview = ids.prefix(5).joined(separator: ", ")
                    let suffix = ids.count > 5 ? " 等 \(ids.count) 个" : ""
                    return (ConnectionTestResult.ok(detail: "连接成功；服务端未列出「\(cleanModel)」，现有：\(preview)\(suffix)"), false)
                }
                return (ConnectionTestResult.ok(detail: "连接成功"), false)
            case 401, 403:
                return (ConnectionTestResult.failed(message: "鉴权失败（HTTP \(http.statusCode)），请检查 API Key"), false)
            case 404:
                return (ConnectionTestResult.failed(message: "接口路径不存在（404），请确认 Base URL 是否以 /v1 结尾"), false)
            default:
                return (ConnectionTestResult.failed(message: "服务端返回 HTTP \(http.statusCode)"), false)
            }
        } catch {
            HotkeyFileLog.shared.log("conn-test: failed \(normalizedBase) — \(error.localizedDescription)")
            let result = ConnectionTestResult.failed(message: "无法连接：\(error.localizedDescription)")
            return (result, Self.transientCode(error))
        }
    }
    /// 本次录音会话的运行时状态（不持久化），由开始录音时根据 provider 与用户偏好计算
    var useSegmentedAPIRecording = true

    private static func loadProvider() -> RecognitionProvider {
        RecognitionProvider(rawValue: UserDefaults.standard.string(forKey: "vs.recognitionProvider") ?? "") ?? .local
    }

    private static func loadLanguage() -> RecognitionLanguage {
        RecognitionLanguage(rawValue: UserDefaults.standard.string(forKey: "vs.recognitionLanguage") ?? "") ?? .followSystem
    }

    private var activeRecognitionProvider: RecognitionProvider = .local
    var lastCompletedRecognitionProvider: RecognitionProvider = .local
    
    public enum SaveStatus: Sendable {
        case idle
        case shrinking
        case complete
        case gone
    }
    
    // Animation constants for consistency
    public enum AnimationConfig {
        static let shrinkDuration: Double = 0.4
        static let shrinkSleep: UInt64 = 300_000_000
        static let checkmarkSleep: UInt64 = 600_000_000
        static let exitDuration: Double = 0.3
        static let exitSleep: UInt64 = 300_000_000
    }
    
    // Observable UI state
    var isRecording = false
    private var isStarting = false // Guards the async permission → start window against re-entry
    var isPTTMode = false
    var isTestMode = false
    var transcribedText = ""
    var audioLevel: CGFloat = 0.0
    var errorMessage: String?
    var lastPermissionError: VoiceInputPhase = .idle

    /// 录音无法启动时的具体原因（nil = 可以启动）。供热键路径与 HUD 显示，
    /// 避免 canStartRecording 为 false 时静默失败。
    var permissionBlockedReason: String? {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            return "麦克风权限未授权"
        }
        if recognitionProvider != .api {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .denied || speechStatus == .restricted {
                return "语音识别权限未授权"
            }
        }
        return nil
    }

    var canStartRecording: Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized || micStatus == .notDetermined else { return false }
        if recognitionProvider != .api {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            guard speechStatus == .authorized || speechStatus == .notDetermined else { return false }
        }
        return true
    }
    var saveStatus: SaveStatus = .idle

    /// 指定录音麦克风（AVCaptureDevice.uniqueID）；空字符串 = 跟随系统默认。
    /// 保存的设备不存在（已拔出）时自动回落系统默认。
    /// 实现：macOS 无 AVAudioSession，通过 CoreAudio 把设备绑到引擎输入节点。
    var selectedMicrophoneUID: String = UserDefaults.standard.string(forKey: "selectedMicrophoneUID") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneUID, forKey: "selectedMicrophoneUID")
        }
    }

    /// 录音启动前调用：把选中设备绑到音频引擎输入节点；设备不可用则回落默认
    func applyPreferredInputDevice() {
        guard !selectedMicrophoneUID.isEmpty else { return }
        guard let deviceID = Self.audioDeviceID(forUID: selectedMicrophoneUID) else {
            HotkeyFileLog.shared.log("mic: saved device unavailable, fallback to default")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioEngine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            HotkeyFileLog.shared.log("mic: input device bound (\(deviceID))")
        } else {
            HotkeyFileLog.shared.log("mic: bind FAILED status=\(status), fallback to default")
        }
    }

    /// AVCaptureDevice.uniqueID → CoreAudio AudioDeviceID
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var result = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let cfUID = uid as CFString
        let status = withUnsafePointer(to: cfUID) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeRawPointer(ptr),
                &size,
                &result)
        }
        return (status == noErr && result != 0) ? result : nil
    }

    private var lastTranscriptionUpdate = Date.distantPast
    private var recognitionDidFinish = false
    
    // MARK: - Animation Sequence
    
    // Internal session tracking to prevent ghosting
    private var currentSessionID: UUID? = nil
    
    override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        // Ignore taps while a start attempt (including the async permission prompt) is in flight,
        // otherwise a second tap can install a second tap / start the engine twice.
        guard !isStarting else { return }
        isStarting = true

        let provider = SpeechManager.shared.recognitionProvider
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if micStatus == .authorized && (provider == .api || speechStatus == .authorized) {
            startRecordingSafe()
        } else {
            requestPermissions()
        }
    }
    
    func startRecordingSafe() {
        let provider = SpeechManager.shared.recognitionProvider
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        HotkeyFileLog.shared.log("rec: start requested provider=\(provider == .api ? "api" : "local") mic=\(micStatus.rawValue)")

        if let reason = permissionBlockedReason {
            HotkeyFileLog.shared.log("rec: blocked — \(reason)")
        }

        if micStatus == .notDetermined {
            requestPermissions()
            return
        }

        guard micStatus == .authorized else {
            self.errorMessage = NSLocalizedString("speech_microphone_permission_error", comment: "")
            lastPermissionError = .permissionDenied(message: self.errorMessage ?? "麦克风权限未授权")
            isStarting = false
            return
        }

        if provider != .api {
            let speechStatus = SFSpeechRecognizer.authorizationStatus()
            if speechStatus == .notDetermined {
                requestPermissions()
                return
            }

            guard speechStatus == .authorized else {
                self.errorMessage = NSLocalizedString("speech_permission_error", comment: "")
                lastPermissionError = .permissionDenied(message: self.errorMessage ?? "语音识别权限未授权")
                isStarting = false
                return
            }
        }

        do {
            self.saveStatus = .idle // Ensure we start from idle
            applyPreferredInputDevice()
            try startRecording()
            HotkeyFileLog.shared.log("rec: engine started ok (isRecording=\(isRecording))")
        } catch {
            HotkeyFileLog.shared.log("rec: start FAILED — \(error.localizedDescription)")
            self.errorMessage = String(format: NSLocalizedString("speech_start_error", comment: ""), error.localizedDescription)
            isStarting = false
            stopRecording()
        }
    }
    
    /// Idempotent tap removal — safe to call when no tap is installed (avoid the
    /// removeTap-without-install crash on rapid stop / error-callback re-entry).
    private func removeInputTap() {
        guard isTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    func stopRecording() {
        isRecording = false
        isStarting = false
        audioLevel = 0.0
        // we don't clear transcribedText here to allow the very last partial results to sync
        bufferHandler.endAudio()
        if activeRecognitionProvider != .api {
            audioFileWriter.close()
        }

        removeInputTap()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        speechRecognizer = nil
    }

    func stopRecordingAndWaitForText() async -> String {
        let provider = activeRecognitionProvider
        stopRecording()

        if provider == .api {
            return await transcribeRecordedAudioFile()
        }

        let timeout = Date().addingTimeInterval(1.2)
        var lastText = transcribedText
        var lastChange = Date()

        while Date() < timeout {
            try? await Task.sleep(for: .milliseconds(80))

            if transcribedText != lastText {
                lastText = transcribedText
                lastChange = Date()
            }

            if recognitionDidFinish || Date().timeIntervalSince(lastChange) > 0.35 {
                break
            }
        }

        return lastText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stopRecordingAndWaitForText 的日志版结果（供热键路径记录转写结果长度）
    func logTranscriptionResult(_ text: String) {
        HotkeyFileLog.shared.log("rec: transcription finished, length=\(text.count), empty=\(text.isEmpty)")
    }

    /// 用 OpenAI 兼容 Chat Completions 接口润色转写文本。
    /// 未启用 / 配置缺失 / 请求失败 / 返回为空时一律回退原始转写。
    func polishTranscription(_ text: String) async -> String {
        guard polishEnabled, !text.isEmpty else { return text }

        let baseURL = polishAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = polishModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty else {
            HotkeyFileLog.shared.log("polish: skipped (missing baseURL/model)")
            return text
        }
        let customPrompt = polishPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = customPrompt.isEmpty ? Self.defaultPolishPrompt : customPrompt

        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: normalizedBase)?.appendingPathComponent("chat/completions") else {
            HotkeyFileLog.shared.log("polish: invalid baseURL")
            return text
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return text }
        request.httpBody = payload

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                HotkeyFileLog.shared.log("polish: unexpected response format")
                return text
            }
            let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
            HotkeyFileLog.shared.log("polish: ok, length \(text.count) -> \(polished.count)")
            return polished.isEmpty ? text : polished
        } catch {
            HotkeyFileLog.shared.log("polish: failed — \(error.localizedDescription)")
            return text
        }
    }

    /// 取消本次语音输入：立即停止录音并丢弃全部会话数据，不产出转写结果
    func cancelSession() {
        HotkeyFileLog.shared.log("rec: cancelSession — discard recording")
        stopRecording()
        resetSession()
    }

    func resetSession() {
        currentSessionID = nil
        transcribedText = ""
        audioLevel = 0.0
        recordedAudioURL = nil
        useSegmentedAPIRecording = false
        completedSpeechSegments.removeAll()
        // Cancel in-flight transcription tasks before dropping references —
        // removeAll() alone leaves them running (resource leak + transcribedText race).
        segmentTranscriptionTasks.values.forEach { $0.cancel() }
        segmentTranscriptionTasks.removeAll()
        segmentedAudioWriter.reset()
    }
    
    // MARK: - Private Methods
    
    private func requestPermissions() {
        let provider = SpeechManager.shared.recognitionProvider

                AVCaptureDevice.requestAccess(for: .audio) { [weak self] micAuthorized in
            if provider == .api {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if micAuthorized {
                        self.startRecordingSafe()
                    } else {
                        self.errorMessage = NSLocalizedString("speech_microphone_permission_error", comment: "")
                        self.isStarting = false
                    }
                }
                return
            }

            SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if authStatus == .authorized && micAuthorized {
                        self.startRecordingSafe()
                    } else {
                        self.errorMessage = NSLocalizedString("speech_permission_error", comment: "")
                        self.isStarting = false
                    }
                }
            }
        }
    }
    
    private func startRecording() throws {
        activeRecognitionProvider = SpeechManager.shared.recognitionProvider
        lastCompletedRecognitionProvider = activeRecognitionProvider

        switch activeRecognitionProvider {
        case .local:
            try startLocalRecording()
        case .api:
            try startAPIRecording()
        }
    }

    private func startAPIRecording() throws {
        let sessionID = UUID()
        self.currentSessionID = sessionID
        self.recognitionDidFinish = false
        self.lastTranscriptionUpdate = .distantPast

        if let recognitionTask = recognitionTask {
            recognitionTask.cancel()
            self.recognitionTask = nil
        }

        transcribedText = ""
        audioLevel = 0.0
        errorMessage = nil
        speechRecognizer = nil
        bufferHandler.setRequest(nil)
        completedSpeechSegments.removeAll()
        segmentTranscriptionTasks.removeAll()

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTap()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            errorMessage = NSLocalizedString("audio_input_unavailable", comment: "")
            return
        }

        let useSegments = useSegmentedAPIRecording
        if useSegments {
            recordedAudioURL = try segmentedAudioWriter.start(sessionID: sessionID, format: recordingFormat)
            audioFileWriter.close()
        } else {
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicescribe-speech-\(sessionID.uuidString).wav")
            recordedAudioURL = audioURL

            let audioFile = try AVAudioFile(forWriting: audioURL, settings: recordingFormat.settings)
            audioFileWriter.setFile(audioFile)
            segmentedAudioWriter.reset()
        }

        let simpleWriter = audioFileWriter
        let segmentedWriter = segmentedAudioWriter
        // 音频线程回调必须显式 @Sendable（否则闭包继承 MainActor 隔离，音频线程触发断言崩溃）
        let segmentSink = MainActorEventSink<SpeechAudioSegment> { [weak self] segment in
            guard let self, self.currentSessionID == sessionID else { return }
            self.queueSegmentTranscription(segment)
        }
        let apiLevelSink = MainActorEventSink<CGFloat> { [weak self] level in
            self?.audioLevel = level
        }
        let apiTapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            if useSegments {
                if let segment = segmentedWriter.write(buffer) {
                    segmentSink.send(segment)
                }
            } else {
                simpleWriter.write(buffer)
            }

            Self.updateAudioLevel(from: buffer) { level in
                apiLevelSink.send(level)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: apiTapHandler)

        isTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        isStarting = false
    }

    private func startLocalRecording() throws {
        // Initialize session
        let sessionID = UUID()
        self.currentSessionID = sessionID
        self.recognitionDidFinish = false
        self.lastTranscriptionUpdate = .distantPast
        self.recordedAudioURL = nil
        
        let localeId = preferredSpeechLocaleIdentifier()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)), recognizer.isAvailable else {
            errorMessage = NSLocalizedString("speech_unavailable", comment: "")
            return
        }
        
        self.speechRecognizer = recognizer
        recognizer.delegate = self

        if let recognitionTask = recognitionTask {
            recognitionTask.cancel()
            self.recognitionTask = nil
        }
        
        transcribedText = ""
        audioLevel = 0.0
        errorMessage = nil
        
        if audioEngine.isRunning {
             audioEngine.stop()
        }
        removeInputTap()

        let engine = audioEngine
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        bufferHandler.setRequest(request)
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            errorMessage = NSLocalizedString("audio_input_unavailable", comment: "")
            return
        }
        
        let handler = self.bufferHandler
        // 音频线程回调必须显式 @Sendable（否则闭包继承 MainActor 隔离，音频线程触发断言崩溃）
        let levelSink = MainActorEventSink<CGFloat> { [weak self] level in
            self?.audioLevel = level
        }
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            handler.appendBuffer(buffer)

            // Calculate audio level for waveform visualization
            Self.updateAudioLevel(from: buffer) { level in
                levelSink.send(level)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, block: tapHandler)
        
        // 识别回调在 Speech 框架内部队列触发，同样需要显式 @Sendable + 主线程投递
        let resultSink = MainActorEventSink<(SFSpeechRecognitionResult?, Error?)> { [weak self] payload in
            guard let self = self, self.currentSessionID == sessionID else { return }
            let (result, error) = payload

            var isFinal = false
            if let result {
                self.transcribedText = result.bestTranscription.formattedString
                self.lastTranscriptionUpdate = Date()
                isFinal = result.isFinal
            }

            if let error {
                if (error as NSError).code != 216 { // 216 = Cancelled
                    let message = NSLocalizedString("speech_recognition_error", value: "语音识别出错,请重试", comment: "")
                    self.errorMessage = message
                    self.lastPermissionError = .failure(message: message)
                    // errorMessage isn't shown on the main capsule UI, so also surface a HUD toast
                }
                self.recognitionDidFinish = true
                self.stopRecording()
            } else if isFinal {
                self.recognitionDidFinish = true
                self.stopRecording()
            }
        }
        let recognitionHandler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
            resultSink.send((result, error))
        }
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: recognitionHandler)
        
        isTapInstalled = true
        engine.prepare()
        try engine.start()
        isRecording = true
        isStarting = false
    }

    private nonisolated static func updateAudioLevel(from buffer: AVAudioPCMBuffer, onUpdate: @Sendable @escaping (CGFloat) -> Void) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let channelDataElementCount = Int(buffer.frameLength)
        guard channelDataElementCount > 0 else { return }

        var sum: Float = 0
        for i in 0..<channelDataElementCount {
            sum += channelData[i] * channelData[i]
        }

        let rms = sqrt(sum / Float(channelDataElementCount))
        let avgPower = 20 * log10(max(rms, 1e-10))
        let level = max(0, min(1, (avgPower + 60) / 60))
        onUpdate(CGFloat(level))
    }

    private func transcribeRecordedAudioFile() async -> String {
        guard let audioURL = recordedAudioURL else { return "" }
        audioFileWriter.close()

        defer {
            try? FileManager.default.removeItem(at: audioURL)
            recordedAudioURL = nil
        }

        let baseURLString = speechAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = speechAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = speechModelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURLString.isEmpty, !apiKey.isEmpty, !modelName.isEmpty else {
            errorMessage = NSLocalizedString("speech_api_config_missing", comment: "")
            return await transcribeAudioFileLocally(audioURL)
        }

        guard let endpointURL = speechTranscriptionEndpoint(from: baseURLString) else {
            errorMessage = NSLocalizedString("speech_api_invalid_url", comment: "")
            return await transcribeAudioFileLocally(audioURL)
        }

        if useSegmentedAPIRecording {
            let segmentedText = await finishSegmentedTranscription(
                endpointURL: endpointURL,
                apiKey: apiKey,
                modelName: modelName
            )
            if !segmentedText.isEmpty {
                transcribedText = segmentedText
                lastCompletedRecognitionProvider = .api
                return segmentedText
            }

            errorMessage = NSLocalizedString("speech_api_request_failed", comment: "")
            return await transcribeAudioFileLocally(audioURL)
        }

        do {
            guard let text = try await transcribeAudioFileWithAPI(
                audioURL,
                endpointURL: endpointURL,
                apiKey: apiKey,
                modelName: modelName
            ) else {
                errorMessage = NSLocalizedString("speech_api_request_failed", comment: "")
                return await transcribeAudioFileLocally(audioURL)
            }

            transcribedText = text
            lastCompletedRecognitionProvider = .api
            return text
        } catch {
            errorMessage = String(format: NSLocalizedString("speech_api_error", comment: ""), error.localizedDescription)
            return await transcribeAudioFileLocally(audioURL)
        }
    }

    private func queueSegmentTranscription(
        _ segment: SpeechAudioSegment,
        endpointURL: URL? = nil,
        apiKey: String? = nil,
        modelName: String? = nil
    ) {
        guard segmentTranscriptionTasks[segment.index] == nil else { return }

        completedSpeechSegments.append(segment)
        segmentTranscriptionTasks[segment.index] = Task { [weak self] in
            await self?.transcribeSegment(segment, endpointURL: endpointURL, apiKey: apiKey, modelName: modelName)
        }
    }

    private func finishSegmentedTranscription(endpointURL: URL, apiKey: String, modelName: String) async -> String {
        let finished = segmentedAudioWriter.finish()
        recordedAudioURL = finished.fullURL

        if !finished.shouldUseSegments {
            let queuedSegments = completedSpeechSegments
            segmentTranscriptionTasks.values.forEach { $0.cancel() }
            cleanupSegmentFiles(queuedSegments + finished.segments + finished.cleanupSegments)
            completedSpeechSegments.removeAll()
            segmentTranscriptionTasks.removeAll()

            guard let fullURL = finished.fullURL else { return "" }
            do {
                return try await transcribeAudioFileWithAPI(
                    fullURL,
                    endpointURL: endpointURL,
                    apiKey: apiKey,
                    modelName: modelName
                ) ?? ""
            } catch {
                #if DEBUG
                print("❌ Full audio transcription failed after short segmented recording: \(error.localizedDescription)")
                #endif
                return ""
            }
        }

        for segment in finished.segments {
            queueSegmentTranscription(
                segment,
                endpointURL: endpointURL,
                apiKey: apiKey,
                modelName: modelName
            )
        }

        let orderedSegments = (completedSpeechSegments + finished.segments)
            .reduce(into: [Int: SpeechAudioSegment]()) { result, segment in
                result[segment.index] = segment
            }
            .values
            .sorted { $0.index < $1.index }

        var segmentTexts: [(Int, String)] = []
        for segment in orderedSegments {
            guard let task = segmentTranscriptionTasks[segment.index],
                  let text = await task.value,
                  !text.isEmpty else {
                continue
            }
            segmentTexts.append((segment.index, text))
        }

        cleanupSegmentFiles(orderedSegments + finished.cleanupSegments)
        completedSpeechSegments.removeAll()
        segmentTranscriptionTasks.removeAll()

        return mergeSegmentTexts(segmentTexts.map(\.1))
    }

    private func transcribeSegment(
        _ segment: SpeechAudioSegment,
        endpointURL: URL?,
        apiKey: String?,
        modelName: String?
    ) async -> String? {
        let resolvedEndpointURL: URL?
        if let endpointURL {
            resolvedEndpointURL = endpointURL
        } else {
            let baseURLString = speechAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedEndpointURL = speechTranscriptionEndpoint(from: baseURLString)
        }

        guard let endpointURL = resolvedEndpointURL else { return nil }
        let apiKey = apiKey ?? speechAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = modelName ?? speechModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !modelName.isEmpty else { return nil }

        await segmentTranscriptionLimiter.acquire()
        defer {
            Task {
                await segmentTranscriptionLimiter.release()
            }
        }

        do {
            return try await transcribeAudioFileWithAPI(
                segment.url,
                endpointURL: endpointURL,
                apiKey: apiKey,
                modelName: modelName
            )
        } catch {
            #if DEBUG
            print("❌ Segment transcription failed[\(segment.index)]: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private func transcribeAudioFileWithAPI(
        _ audioURL: URL,
        endpointURL: URL,
        apiKey: String,
        modelName: String
    ) async throws -> String? {
        let recognitionURL = await Self.trimmedAudioURLForRecognition(audioURL) ?? audioURL
        defer {
            if recognitionURL != audioURL {
                try? FileManager.default.removeItem(at: recognitionURL)
            }
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartTranscriptionBody(
            boundary: boundary,
            modelName: modelName,
            audioURL: recognitionURL,
            languageCode: preferredSpeechAPILanguageCode()
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let transcription = try JSONDecoder().decode(SpeechTranscriptionResponse.self, from: data)
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func trimmedAudioURLForRecognition(_ audioURL: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            do {
                return try createTrimmedAudioURLForRecognition(audioURL)
            } catch {
                #if DEBUG
                print("❌ Audio silence trim failed: \(error.localizedDescription)")
                #endif
                return nil
            }
        }.value
    }

    private nonisolated static func createTrimmedAudioURLForRecognition(_ audioURL: URL) throws -> URL? {
        let inputFile = try AVAudioFile(forReading: audioURL)
        let format = inputFile.processingFormat
        let totalFrames = inputFile.length
        let sampleRate = format.sampleRate
        guard totalFrames > 0, sampleRate > 0 else { return nil }

        let chunkCapacity: AVAudioFrameCount = 4096
        let silenceThreshold: Float = -50
        let paddingFrames = AVAudioFramePosition(sampleRate * 0.2)
        let minimumSavedFrames = AVAudioFramePosition(sampleRate * 0.25)

        var scanPosition: AVAudioFramePosition = 0
        var firstSpeechFrame: AVAudioFramePosition?
        var lastSpeechFrame: AVAudioFramePosition?

        while scanPosition < totalFrames {
            let framesToRead = min(chunkCapacity, AVAudioFrameCount(totalFrames - scanPosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                return nil
            }

            try inputFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }

            if averagePower(buffer) > silenceThreshold {
                if firstSpeechFrame == nil {
                    firstSpeechFrame = scanPosition
                }
                lastSpeechFrame = scanPosition + AVAudioFramePosition(buffer.frameLength)
            }

            scanPosition += AVAudioFramePosition(buffer.frameLength)
        }

        guard let firstSpeechFrame, let lastSpeechFrame else { return nil }

        let startFrame = max(0, firstSpeechFrame - paddingFrames)
        let endFrame = min(totalFrames, lastSpeechFrame + paddingFrames)
        let keptFrames = endFrame - startFrame
        let savedFrames = totalFrames - keptFrames
        guard keptFrames > 0, savedFrames >= minimumSavedFrames else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicescribe-speech-trimmed-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outputURL)

        inputFile.framePosition = startFrame
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        var remainingFrames = keptFrames
        while remainingFrames > 0 {
            let framesToRead = min(chunkCapacity, AVAudioFrameCount(remainingFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                break
            }

            try inputFile.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
            remainingFrames -= AVAudioFramePosition(buffer.frameLength)
        }

        return outputURL
    }

    private nonisolated static func averagePower(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return -100 }

        var sum: Float = 0
        var sampleCount = 0

        if let data = buffer.floatChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = data[channel][frame]
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = Float(data[channel][frame]) / Float(Int16.max)
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        } else if let data = buffer.int32ChannelData {
            for channel in 0..<channelCount {
                for frame in 0..<frameLength {
                    let sample = Float(data[channel][frame]) / Float(Int32.max)
                    sum += sample * sample
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return -100 }
        let rms = sqrt(sum / Float(sampleCount))
        return 20 * log10(max(rms, 1e-10))
    }

    private func cleanupSegmentFiles(_ segments: [SpeechAudioSegment]) {
        for segment in segments {
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    private func mergeSegmentTexts(_ texts: [String]) -> String {
        texts.reduce("") { partialResult, nextText in
            mergeAdjacentTranscription(partialResult, nextText)
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeAdjacentTranscription(_ previous: String, _ next: String) -> String {
        let lhs = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = next.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }

        if let suffixStart = suffixStartAfterOverlap(previous: lhs, next: rhs) {
            let suffix = rhs[suffixStart...]
            let normalizedSuffix = lhs.last.map { isTranscriptionPunctuation($0) } == true
                ? suffix.trimmingCharacters(in: transcriptionBoundaryCharacters)
                : String(suffix)
            return lhs + normalizedSuffix
        }

        if endsWithSentencePunctuation(lhs) || startsWithPunctuation(rhs) {
            return lhs + rhs
        }

        if shouldInsertSpaceBetween(lhs, rhs) {
            return lhs + " " + rhs
        }

        return lhs + rhs
    }

    private func suffixStartAfterOverlap(previous: String, next: String) -> String.Index? {
        let previousChars = normalizedMergeCharacters(from: previous, limit: 36, fromEnd: true)
        let nextChars = normalizedMergeCharacters(from: next, limit: 36, fromEnd: false)
        guard !previousChars.isEmpty, !nextChars.isEmpty else { return nil }

        let maxLength = min(previousChars.count, nextChars.count)
        for length in stride(from: maxLength, through: 3, by: -1) {
            let previousSuffix = previousChars.suffix(length).map(\.normalized)
            let nextPrefix = nextChars.prefix(length).map(\.normalized)
            if previousSuffix.joined() == nextPrefix.joined() {
                return nextChars[length - 1].endIndex
            }
        }

        for length in stride(from: maxLength, through: 4, by: -1) {
            let previousSuffix = Array(previousChars.suffix(length).map(\.normalized))
            let nextPrefix = Array(nextChars.prefix(length).map(\.normalized))
            if isLikelySameTranscription(previousSuffix, nextPrefix) {
                return nextChars[length - 1].endIndex
            }
        }

        return nil
    }

    private func isLikelySameTranscription(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }

        let distance = editDistance(lhs, rhs)
        let similarity = 1.0 - (Double(distance) / Double(lhs.count))

        switch lhs.count {
        case 0...5:
            return distance <= 1 && similarity >= 0.8
        case 6...10:
            return distance <= 2 && similarity >= 0.78
        case 11...18:
            return distance <= 4 && similarity >= 0.72
        default:
            return distance <= 7 && similarity >= 0.68
        }
    }

    private func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previousRow = Array(0...rhs.count)
        var currentRow = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            currentRow[0] = lhsIndex

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                currentRow[rhsIndex] = min(
                    previousRow[rhsIndex] + 1,
                    currentRow[rhsIndex - 1] + 1,
                    previousRow[rhsIndex - 1] + substitutionCost
                )
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[rhs.count]
    }

    private struct MergeCharacter {
        let normalized: String
        let endIndex: String.Index
    }

    private var transcriptionBoundaryCharacters: CharacterSet {
        .whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "，。！？；：、,.!?;:\"'“”‘’（）()[]{}《》<>「」『』-—… "))
    }

    private func normalizedMergeCharacters(
        from text: String,
        limit: Int,
        fromEnd: Bool
    ) -> [MergeCharacter] {
        let characterPairs = text.indices.map { index in
            let character = text[index]
            let endIndex = text.index(after: index)
            return (character, endIndex)
        }

        let selectedPairs = fromEnd ? characterPairs.suffix(limit * 2) : characterPairs.prefix(limit * 2)
        let normalized = selectedPairs.compactMap { character, endIndex -> MergeCharacter? in
            guard !isTranscriptionBoundary(character) else { return nil }
            return MergeCharacter(
                normalized: String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                endIndex: endIndex
            )
        }

        return fromEnd ? Array(normalized.suffix(limit)) : Array(normalized.prefix(limit))
    }

    private func isTranscriptionBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            transcriptionBoundaryCharacters.contains(scalar)
        }
    }

    private func isTranscriptionPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            transcriptionBoundaryCharacters.contains(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？.!?".contains(last)
    }

    private func startsWithPunctuation(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return "，。！？,.!?;；:：".contains(first)
    }

    private func shouldInsertSpaceBetween(_ previous: String, _ next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        return last.isASCII && first.isASCII && !last.isWhitespace && !first.isWhitespace
    }

    private func transcribeAudioFileLocally(_ audioURL: URL) async -> String {
        let recognitionURL = await Self.trimmedAudioURLForRecognition(audioURL) ?? audioURL
        defer {
            if recognitionURL != audioURL {
                try? FileManager.default.removeItem(at: recognitionURL)
            }
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            let isAuthorized = await requestSpeechRecognitionAuthorization()
            guard isAuthorized else { return "" }
        } else {
            guard speechStatus == .authorized else { return "" }
        }

        let localeId = preferredSpeechLocaleIdentifier()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)), recognizer.isAvailable else {
            errorMessage = NSLocalizedString("speech_unavailable", comment: "")
            return ""
        }

        let fallbackText: String = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = SFSpeechURLRecognitionRequest(url: recognitionURL)
            request.shouldReportPartialResults = false

            var didResume = false
            var latestText = ""
            var timeoutTask: Task<Void, Never>?
            var fallbackRecognitionTask: SFSpeechRecognitionTask?

            func finish(_ text: String) {
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                fallbackRecognitionTask?.cancel()
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmedText)
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                finish(latestText)
            }

            fallbackRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    if let result {
                        latestText = result.bestTranscription.formattedString
                    }

                    if let result, result.isFinal {
                        finish(result.bestTranscription.formattedString)
                        return
                    }

                    if let error {
                        #if DEBUG
                        print("❌ Local fallback recognition error: \(error.localizedDescription)")
                        #endif
                        self?.errorMessage = NSLocalizedString("speech_api_request_failed", comment: "")
                        finish(latestText)
                    }
                }
            }
            recognitionTask = fallbackRecognitionTask
        }

        if !fallbackText.isEmpty {
            errorMessage = nil
        }
        transcribedText = fallbackText
        lastCompletedRecognitionProvider = .local
        return fallbackText
    }

    private func requestSpeechRecognitionAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func speechTranscriptionEndpoint(from rawURLString: String) -> URL? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSlashes = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmedSlashes.hasSuffix("/audio/transcriptions") {
            return URL(string: trimmed)
        }

        return URL(string: "\(trimmedSlashes)/audio/transcriptions")
    }

    private func multipartTranscriptionBody(
        boundary: String,
        modelName: String,
        audioURL: URL,
        languageCode: String?
    ) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(modelName)\r\n")

        if let languageCode, !languageCode.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(languageCode)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    private func preferredSpeechLocaleIdentifier() -> String {
        switch recognitionLanguage {
        case .followSystem:
            return supportedSystemSpeechLocaleIdentifier()
        case .zhCN:
            return "zh-CN"
        case .enUS:
            return "en-US"
        case .jaJP:
            return "ja-JP"
        }
    }

    private func preferredSpeechAPILanguageCode() -> String? {
        switch recognitionLanguage {
        case .followSystem:
            return apiLanguageCode(from: supportedSystemSpeechLocaleIdentifier())
        case .zhCN:
            return "zh"
        case .enUS:
            return "en"
        case .jaJP:
            return "ja"
        }
    }

    private func apiLanguageCode(from localeIdentifier: String) -> String? {
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        switch languageCode {
        case "zh":
            return "zh"
        case "en":
            return "en"
        case "ja":
            return "ja"
        default:
            return nil
        }
    }

    private func supportedSystemSpeechLocaleIdentifier() -> String {
        let supported = SFSpeechRecognizer.supportedLocales().map { $0.identifier }

        // 注意：不能用 Locale.current —— 它返回的是本 App 的本地化语言，
        // 未做中文本地化的 App 即使系统是中文也会得到 en_US。
        // 这里改读 AppleLanguages（用户真实的系统首选语言列表，如 ["zh-Hans-CN"]）。
        let preferredLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        for rawId in preferredLanguages {
            if supported.contains(rawId) { return rawId }

            let langCode = Locale(identifier: rawId).language.languageCode?.identifier ?? ""
            guard !langCode.isEmpty else { continue }
            let sameLang = supported.filter { Locale(identifier: $0).language.languageCode?.identifier == langCode }
            if sameLang.isEmpty { continue }

            // 中文需区分简繁：原始偏好含 Hant 时优先繁体地区，否则优先简体
            if langCode == "zh" {
                if rawId.contains("Hant"),
                   let trad = sameLang.first(where: { $0.contains("TW") || $0.contains("HK") || $0.contains("MO") || $0.contains("Hant") }) {
                    return trad
                }
                if let simp = sameLang.first(where: { $0.contains("CN") || $0.contains("SG") || $0.contains("Hans") }) {
                    return simp
                }
            }
            return sameLang[0]
        }

        let currentIdentifier = Locale.current.identifier
        if supported.contains(currentIdentifier) {
            return currentIdentifier
        }

        return "en-US"
    }
}
