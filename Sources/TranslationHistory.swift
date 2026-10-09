import AppKit
import Foundation

/// 翻译历史：连击翻译成功后记录 原文/译文/目标语言/时间，本地 UserDefaults JSON。
/// 与 InputHistory 同构：新条目置顶、超上限裁剪、清空即删键。写回与弹窗两条
/// 路径共用一个写入点语义——只要翻译成功就记录，与后续交付是否成功无关。
@MainActor
final class TranslationHistory: ObservableObject {
    static let shared = TranslationHistory()

    struct Entry: Codable, Identifiable {
        let id: UUID
        let source: String
        let translated: String
        /// 目标语言显示名（如「自动（中英互译）」「英语」），仅作历史行标注
        let targetName: String
        let timestamp: Date
    }

    private static let storageKey = "translationHistory"
    /// 固定上限：回溯是低频动作，不做可调档位，先让数据存在
    static let maxEntries = 50

    @Published private(set) var entries: [Entry] = TranslationHistory.load()

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 翻译成功后记录；与既有条目三元组（原文/译文/目标语言）完全相同时不重复插入、
    /// 仅置顶——与 InputHistory 的去重置顶一致，常用词的反复翻译不会刷满历史
    func record(source: String, translated: String, targetName: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translated.isEmpty else { return }
        entries.removeAll {
            $0.source == source && $0.translated == translated && $0.targetName == targetName
        }
        entries.insert(
            Entry(id: UUID(), source: source, translated: translated,
                  targetName: targetName, timestamp: Date()),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    /// 复制指定条目的译文到剪贴板
    func copyToPasteboard(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.translated, forType: .string)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}
