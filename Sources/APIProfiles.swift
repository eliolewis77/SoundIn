import Foundation
import SwiftUI

/// 一份 OpenAI 兼容接口配置：名称 + 地址 + Key + 模型。
/// 识别引擎与文字优化共用同一份列表，各自独立选择用哪一份。
struct APIProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var modelName: String

    init(name: String, baseURL: String = "", apiKey: String = "", modelName: String = "") {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
    }
}

/// 配置档库。profiles 以 JSON 存 UserDefaults；
/// engineSelectionID / polishSelectionID 记录两处各自的选中项（可指向同一档）。
@MainActor
final class APIProfileStore: ObservableObject {
    static let shared = APIProfileStore()

    private static let profilesKey = "vs.apiProfiles"
    private static let engineSelectionKey = "vs.engineProfileID"
    private static let polishSelectionKey = "vs.polishProfileID"

    @Published var profiles: [APIProfile] = [] {
        didSet { persistProfiles() }
    }
    @Published var engineSelectionID: UUID? {
        didSet { persistSelection(engineSelectionID, key: Self.engineSelectionKey) }
    }
    @Published var polishSelectionID: UUID? {
        didSet { persistSelection(polishSelectionID, key: Self.polishSelectionKey) }
    }

    var selectedEngine: APIProfile? {
        profiles.first { $0.id == engineSelectionID }
    }
    var selectedPolish: APIProfile? {
        profiles.first { $0.id == polishSelectionID }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([APIProfile].self, from: data), !decoded.isEmpty {
            profiles = decoded
            engineSelectionID = loadSelection(key: Self.engineSelectionKey, validIn: profiles)
            polishSelectionID = loadSelection(key: Self.polishSelectionKey, validIn: profiles)
        } else {
            if UserDefaults.standard.data(forKey: Self.profilesKey) != nil {
                HotkeyFileLog.shared.log("profiles: stored JSON unreadable — falling back to legacy migration")
            }
            profiles = Self.migrateLegacySettings()
            engineSelectionID = profiles.first?.id
            // 润色旧配置与识别不同 → 单独建档并选中；相同/为空 → 与识别共用第一档
            if profiles.count > 1 {
                polishSelectionID = profiles[1].id
            } else {
                polishSelectionID = profiles.first?.id
            }
            persistProfiles()
            // 迁移完成即删除旧键：否则主数据将来损坏时，这里会把升级前的
            // 旧 Base URL / Key 静默"复活"，用户拿到过期凭据且无从排查。
            Self.removeLegacyKeys()
        }
        // 兜底：选中项失效（如手动改了存储）时指回第一档
        if engineSelectionID == nil { engineSelectionID = profiles.first?.id }
        if polishSelectionID == nil { polishSelectionID = profiles.first?.id }
    }

    /// 删除升级迁移来源的 6 个旧键（迁移只应发生一次）
    private static func removeLegacyKeys() {
        let d = UserDefaults.standard
        ["vs.apiBaseURL", "vs.apiKey", "vs.apiModel",
         "vs.polishBaseURL", "vs.polishAPIKey", "vs.polishModel"].forEach { d.removeObject(forKey: $0) }
    }

    /// 首次升级迁移：把旧的三个单独字段打包成「默认」档；
    /// 若润色配置与识别不同，再建「默认（润色）」档，保证行为不变。
    private static func migrateLegacySettings() -> [APIProfile] {
        let d = UserDefaults.standard
        let engineBase = d.string(forKey: "vs.apiBaseURL") ?? ""
        let engineKey = d.string(forKey: "vs.apiKey") ?? ""
        let engineModel = d.string(forKey: "vs.apiModel") ?? ""
        let polishBase = d.string(forKey: "vs.polishBaseURL") ?? ""
        let polishKey = d.string(forKey: "vs.polishAPIKey") ?? ""
        let polishModel = d.string(forKey: "vs.polishModel") ?? ""

        let engineHasContent = !(engineBase.isEmpty && engineKey.isEmpty && engineModel.isEmpty)
        let polishHasContent = !(polishBase.isEmpty && polishKey.isEmpty && polishModel.isEmpty)

        let defaultProfile = APIProfile(
            name: "默认",
            baseURL: engineBase,
            apiKey: engineKey,
            modelName: engineModel
        )

        guard polishHasContent else { return [defaultProfile] }
        if engineHasContent,
           polishBase == engineBase, polishKey == engineKey, polishModel == engineModel {
            return [defaultProfile]
        }
        // 两者都有且不同 → 第二档留给润色
        if engineHasContent {
            let polishProfile = APIProfile(
                name: "默认（润色）",
                baseURL: polishBase,
                apiKey: polishKey,
                modelName: polishModel
            )
            return [defaultProfile, polishProfile]
        }
        // 只有润色有内容：唯一一档用润色的值
        let onlyPolish = APIProfile(name: "默认", baseURL: polishBase, apiKey: polishKey, modelName: polishModel)
        return [onlyPolish]
    }

    // MARK: - 增删改

    @discardableResult
    func addProfile(named rawName: String) -> APIProfile {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "配置 \(profiles.count + 1)" : trimmed
        let profile = APIProfile(name: name)
        profiles.append(profile)
        return profile
    }

    /// 删除指定档；若删的是当前选中项则自动切到剩余第一档。
    /// 调用方随后应调用 applyActive(to:) 把新的选中档回写进 SpeechManager。
    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if engineSelectionID == id { engineSelectionID = profiles.first?.id }
        if polishSelectionID == id { polishSelectionID = profiles.first?.id }
    }

    func updateProfile(_ id: UUID, keyPath: WritableKeyPath<APIProfile, String>, value: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index][keyPath: keyPath] = value
    }

    /// 启动时把两个选中档的内容回写进 SpeechManager 的活动属性。
    func applyActive(to speech: SpeechManager) {
        if let p = selectedEngine {
            speech.speechAPIBaseURL = p.baseURL
            speech.speechAPIKey = p.apiKey
            speech.speechModelName = p.modelName
        }
        if let p = selectedPolish {
            speech.polishAPIBaseURL = p.baseURL
            speech.polishAPIKey = p.apiKey
            speech.polishModelName = p.modelName
        }
    }

    // MARK: - 持久化

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
    }

    private func persistSelection(_ id: UUID?, key: String) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func loadSelection(key: String, validIn list: [APIProfile]) -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let id = UUID(uuidString: raw),
              list.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}
