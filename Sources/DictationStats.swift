import Foundation

/// 每日听写字数统计：按日累计成功输入的转写字符数（去除空白）。
/// 数据仅存本机 UserDefaults（键 dictationStats.yyyyMMdd），自动清理 90 天前的旧数据。
@MainActor
final class DictationStats: ObservableObject {
    static let shared = DictationStats()

    private let prefix = "dictationStats."
    private let retentionDays = 90
    /// 当天已做过一次清理的标记（避免每次记录都全量扫描）
    private var lastCleanupDay = ""

    /// 粘贴成功后调用：累计本次输入的字符数（空白字符不计）
    func record(_ text: String) {
        let count = text.filter { !$0.isWhitespace && !$0.isNewline }.count
        guard count > 0 else { return }
        let key = Self.dayKey(Date())
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + count, forKey: key)
        cleanupOldEntriesIfNeeded()
        HotkeyFileLog.shared.log("stats: +\(count) chars, today=\(todayCount)")
        // 统计页实时刷新：数字与热力图随每次成功输入更新
        objectWillChange.send()
    }

    var todayCount: Int { count(for: Date()) }

    /// 最近 7 天（含今天）合计
    var weekCount: Int {
        (0..<7).reduce(0) { sum, offset in
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return sum }
            return sum + count(for: day)
        }
    }

    /// 保留期内累计（所有统计键求和）
    var totalCount: Int {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .compactMap { $0 as? Int }
            .reduce(0, +)
    }

    // MARK: - 热力图数据

    /// 热力图单元格：date 为 nil 表示未来日期（不渲染）
    struct DayCell {
        let date: Date?
        let count: Int
        var isFuture: Bool { date == nil }
    }

    /// 以周一为列起始对齐的最近 weeks 周网格（GitHub 贡献图布局，最后一格 = 今天）
    func heatmapCells(weeks: Int) -> [[DayCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // 今天是周几（周一=0 … 周日=6）
        let weekdayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day,
                                            value: -(weeks * 7 - 1 - weekdayOffset),
                                            to: today) else { return [] }

        return (0..<weeks).map { week in
            (0..<7).compactMap { dayOffset in
                guard let date = calendar.date(byAdding: .day,
                                               value: week * 7 + dayOffset,
                                               to: gridStart) else { return nil }
                if date > today {
                    return DayCell(date: nil, count: 0)
                }
                return DayCell(date: date, count: count(for: date))
            }
        }
    }

    // MARK: - Private

    private static func dayKey(_ date: Date) -> String {
        "dictationStats." + dateString(date)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private func count(for date: Date) -> Int {
        UserDefaults.standard.integer(forKey: Self.dayKey(date))
    }

    /// 每天首次记录时清理超过保留期的旧键
    private func cleanupOldEntriesIfNeeded() {
        let today = Self.dateString(Date())
        guard today != lastCleanupDay else { return }
        lastCleanupDay = today

        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoff = Self.dateString(cutoffDate)
        for (key, _) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if String(key.dropFirst(prefix.count)) < cutoff {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
