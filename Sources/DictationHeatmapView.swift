import SwiftUI

// MARK: - 听写统计热力图（GitHub 贡献图风格，方案 A）

/// 背景 GeometryReader 量到的可用宽度，通过 PreferenceKey 传上来（不影响布局/行高）
private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct DictationHeatmapView: View {
    let cells: [[DictationStats.DayCell]]

    /// 格子间距与左侧星期标签列宽；格子尺寸由可用宽度反推（占满一行）
    private let gap: CGFloat = 3
    private let weekdayGutter: CGFloat = 22
    /// 宽度尚未量到时的兜底格子尺寸
    private let fallbackCell: CGFloat = 6

    /// 由背景 GeometryReader 量到的可用宽度
    @State private var measuredWidth: CGFloat = 0

    /// 由可用宽度反推格子尺寸，使整行铺满（保持方形）；未量到宽度时退回最小值
    private var cell: CGFloat {
        let cols = CGFloat(cells.count)
        let raw = (measuredWidth - weekdayGutter - (cols - 1) * gap) / cols
        return max(raw, fallbackCell)
    }

    /// 非零天里的最大字数，用于分档
    private var maxCount: Int {
        cells.flatMap { $0 }.map(\.count).max() ?? 0
    }

    /// 品牌绿梯度：0 = 浅灰，其余按最大值四档渐深
    private func color(for count: Int) -> Color {
        guard maxCount > 0, count > 0 else {
            return Color.primary.opacity(0.06)
        }
        let ratio = Double(count) / Double(maxCount)
        switch ratio {
        case ..<0.25: return Color(red: 0.84, green: 0.93, blue: 0.75)   // D7ECC0
        case ..<0.50: return Color(red: 0.71, green: 0.87, blue: 0.54)   // B4DD8A
        case ..<0.75: return Color(red: 0.59, green: 0.77, blue: 0.35)   // 97C459
        default:      return Color(red: 0.44, green: 0.62, blue: 0.24)   // 6F9E3D
        }
    }

    /// 列首月份标签：月份变化的列显示「N月」；
    /// 与上一个已显示标签不足 2 列时跳过（如首列只剩月末一两天），避免文字重叠
    private var monthLabels: [(column: Int, name: String)] {
        var result: [(Int, String)] = []
        var previousMonth = -1
        var previousShownColumn = -99
        for (column, week) in cells.enumerated() {
            guard let firstDay = week.first?.date else { continue }
            let month = Calendar.current.component(.month, from: firstDay)
            guard month != previousMonth else { continue }
            previousMonth = month
            guard column - previousShownColumn >= 2 else { continue }
            result.append((column, "\(month)月"))
            previousShownColumn = column
        }
        return result.map { (column: $0.0, name: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 月份标签行
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: 13)
                ForEach(monthLabels, id: \.column) { label in
                    Text(label.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .offset(x: weekdayGutter + CGFloat(label.column) * (cell + gap))
                }
            }

            HStack(alignment: .top, spacing: 0) {
                // 星期标签列
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(["一", "", "三", "", "五", "", "日"][row])
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: weekdayGutter, height: cell + (row == 6 ? 0 : gap), alignment: .trailing)
                    }
                }

                // 热力格子
                HStack(spacing: gap) {
                    ForEach(cells.indices, id: \.self) { column in
                        VStack(spacing: gap) {
                            ForEach(cells[column].indices, id: \.self) { row in
                                let day = cells[column][row]
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(day.isFuture ? AnyShapeStyle(.clear) : AnyShapeStyle(color(for: day.count)))
                                    .frame(width: cell, height: cell)
                                    .help(tooltip(for: day))
                            }
                        }
                    }
                }
            }

            // 图例
            HStack(spacing: 4) {
                Spacer()
                Text("少")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach([0, 1, 2, 3, 4], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(level == 0 ? Color.primary.opacity(0.06) : color(for: levelFraction(level)))
                        .frame(width: 11, height: 11)
                }
                Text("多")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // 在背景里量可用宽度，不抢占布局/行高（避免 GeometryReader 在 Form 行里把高度撑成 0）
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: WidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(WidthKey.self) { measuredWidth = $0 }
    }

    private func levelFraction(_ level: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        return Int(Double(maxCount) * [0.0, 0.24, 0.49, 0.74, 1.0][level]) + (level == 0 ? 0 : 1)
    }

    private func tooltip(for day: DictationStats.DayCell) -> String {
        guard let date = day.date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: date)) · \(day.count) 字"
    }
}
