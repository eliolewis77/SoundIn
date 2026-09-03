import Foundation

/// 每日听写字数统计：按日累计成功输入的转写字符数（去除空白）。
/// 数据仅存本机 UserDefaults（键 dictationStats.yyyyMMdd），自动清理 90 天前的旧数据。
@MainActor
final class DictationStats: ObservableObject {
    static let shared = DictationStats()

    /// UserDefaults 键前缀（静态常量：缓存、清理、日键构造共用一份，避免两处硬编码不一致）
    private static let keyPrefix = "dictationStats."
    private var prefix: String { Self.keyPrefix }
    private let retentionDays = 90
    /// 当天已做过一次清理的标记（避免每次记录都全量扫描）
    private var lastCleanupDay = ""

    // MARK: - PERF-5：避免重复读 UserDefaults / 重复新建 DateFormatter
    //
    // 统计页一次渲染的开销原本是：heatmapCells(weeks:13) 触发 91 次 count(for:)，
    // 每次 count(for:) 都新建一个 DateFormatter（dateString 内）并读一次 UserDefaults；
    // totalCount 还会额外做一次 UserDefaults.dictionaryRepresentation() 全量快照。
    // 这里改为：复用单个 DateFormatter + 按天失效的内存计数缓存。

    /// 复用的日期格式化器：类为 @MainActor，不存在并发访问
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    /// 每日计数内存缓存：dayKey -> count
    private var cachedCounts: [String: Int]?
    /// 缓存所属日期：跨天后自动重建
    private var cachedDay = ""

    /// 内存缓存中的每日计数（跨天、写入、清理后失效重建）
    private var counts: [String: Int] {
        let today = Self.dateString(Date())
        if let cachedCounts, cachedDay == today { return cachedCounts }
        let snapshot = UserDefaults.standard.dictionaryRepresentation()
            .reduce(into: [String: Int]()) { result, pair in
                guard pair.key.hasPrefix(Self.keyPrefix), let value = pair.value as? Int else { return }
                result[pair.key] = value
            }
        cachedCounts = snapshot
        cachedDay = today
        return snapshot
    }

    private func invalidateCountsCache() { cachedCounts = nil }

    /// 粘贴成功后调用：累计本次输入的字符数（空白字符不计）
    func record(_ text: String) {
        let count = text.filter { !$0.isWhitespace && !$0.isNewline }.count
        guard count > 0 else { return }
        let key = Self.dayKey(Date())
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + count, forKey: key)
        cleanupOldEntriesIfNeeded()
        invalidateCountsCache()
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
    var totalCount: Int { counts.values.reduce(0, +) }

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
        Self.keyPrefix + dateString(date)
    }

    private static func dateString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func count(for date: Date) -> Int {
        counts[Self.dayKey(date)] ?? 0
    }

    /// 每天首次记录时清理超过保留期的旧键
    private func cleanupOldEntriesIfNeeded() {
        let today = Self.dateString(Date())
        guard today != lastCleanupDay else { return }
        lastCleanupDay = today

        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoff = Self.dateString(cutoffDate)
        // 走内存缓存的键集合，避免再对 UserDefaults 做一次全量快照
        for key in counts.keys where key.hasPrefix(prefix) {
            if String(key.dropFirst(prefix.count)) < cutoff {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
