import AppKit
import Foundation

/// 最近输入历史：成功输入的转写文本，保留条数用户可调（默认 10），去重置顶。
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
    private static let limitKey = "vs.historyLimit"

    /// 保留条数上限：必须 @Published——设置页 Picker 直接绑定它，若不可观察，
    /// 调整后没有触发重绘的路径（裁剪 entries 才发 objectWillChange，条数不足时不裁），
    /// Picker 显示会弹回旧值。调小立即裁剪既有条目（用户在设置里看到的就是实际保留的）。
    @Published
    var maxEntries: Int = UserDefaults.standard.object(forKey: limitKey) as? Int ?? 10 {
        didSet {
            UserDefaults.standard.set(maxEntries, forKey: Self.limitKey)
            guard entries.count > maxEntries else { return }
            entries = Array(entries.prefix(maxEntries))
            save()
        }
    }

    /// 设置页可选的档位
    static let limitChoices = [10, 20, 50, 100]

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
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    /// 复制指定条目到剪贴板
    func copyToPasteboard(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    /// 导出为纯文本（新→旧，与界面顺序一致）。落盘路径由保存面板决定，这里只负责拼内容。
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "SoundIn 输入历史（导出于 \(formatter.string(from: Date()))，共 \(entries.count) 条）",
            "",
        ]
        for entry in entries {
            lines.append("—— \(formatter.string(from: entry.timestamp))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
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
