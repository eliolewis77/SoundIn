import AppKit
import Foundation

/// 最近输入历史：成功输入的转写文本，最多保留 10 条，去重置顶。
/// 数据仅存本机（UserDefaults JSON）。
@MainActor
final class InputHistory: ObservableObject {
    static let shared = InputHistory()

    struct Entry: Codable, Identifiable {
        let id: UUID
        let text: String
        let timestamp: Date
    }

    private static let storageKey = "recentInputHistory"
    static let maxEntries = 10

    @Published private(set) var entries: [Entry] = InputHistory.load()

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

    /// 成功输入后记录：相同内容去掉旧条目后置顶，超出上限裁剪
    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.text == trimmed }
        entries.insert(Entry(id: UUID(), text: trimmed, timestamp: Date()), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    /// 复制指定条目到剪贴板
    func copyToPasteboard(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// 时间显示：今天 HH:mm，昨天显示「昨天」，更早「M月d日」
    static func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "昨天" }
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
