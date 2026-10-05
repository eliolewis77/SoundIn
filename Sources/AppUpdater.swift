import AppKit
import Sparkle

/// Sparkle 自动更新封装。
///
/// 触发时机两条：
/// - 启动后延迟 `startupDelay` 静默检查（自动检查开关开启时，Sparkle 自行节流，
///   最短间隔由 Info.plist 的 `SUScheduledCheckInterval` 控制，不会每次启动都联网）
/// - 设置页「检查更新…」手动触发（忽略节流，强制检查）
///
/// 关键约束：Sparkle 要求更新包用 EdDSA 签名，公钥写在 Info.plist 的 `SUPublicEDKey`。
/// 公钥不匹配时 Sparkle 会拒绝安装并报错——这是安全边界，不要为了"让更新能用"而绕过。
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    private var startupTask: Task<Void, Never>?

    /// 延迟启动检查的秒数。立刻检查会拖慢冷启动，且用户常在启动瞬间就要说话。
    private static let startupDelay: TimeInterval = 3

    private init() {
        // 第三个参数 `startingUpdater: false` = 不自动立即检查，由我们控制时机。
        // 第二个参数 `updaterDelegate: nil` = 用默认行为（自动解压安装）。
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // startingUpdater: false 只是不立即检查，updater 仍必须 start 才能用——
        // 缺了这一步，checkForUpdates 会以 "updater hasn't been started yet" 静默失败
        // （SPUUpdater.m 对未 start 的 updater 直接 return）。
        try? controller.startUpdater()
    }

    /// 启动后延迟静默检查。失败（无网络、appcast 不可达）静默忽略——
    /// 自动检查不该用错误提示打扰用户，手动检查才会报错。
    func scheduleStartupCheck() {
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startupDelay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.controller.updater.automaticallyChecksForUpdates else { return }
                self.controller.updater.checkForUpdates()
                HotkeyFileLog.shared.log("sparkle: startup check dispatched")
            }
        }
    }

    /// 菜单「检查更新…」：强制检查，忽略自动检查的节流间隔。
    func checkForUpdatesManually() {
        HotkeyFileLog.shared.log("sparkle: manual check requested")
        controller.updater.checkForUpdates()
    }

    /// 「自动检查更新」开关（存 UserDefaults，Sparkle 读取同一个键）。
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    var automaticallyChecksForUpdates: Bool {
        controller.updater.automaticallyChecksForUpdates
    }
}
