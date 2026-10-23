import SwiftUI

/// 翻译与文字识别共用的结果浮窗规格。
enum ResultPanelStyle {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    static let bodyHeight: CGFloat = 360
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 9
    static let cornerRadius: CGFloat = 12

    /// 长文、多行或需要滚动的结果保留到用户主动关闭。
    static func autoHideDelay(for text: String, scrolls: Bool) -> TimeInterval? {
        guard !scrolls, text.count <= 240, text.split(separator: "\n", omittingEmptySubsequences: false).count <= 6 else {
            return nil
        }
        return 15
    }
}

struct ResultPanelHeader: View {
    let title: String
    let systemImage: String
    var onCopy: (() -> Void)?
    let onClose: () -> Void
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let onCopy {
                Button {
                    onCopy()
                    justCopied = true
                } label: {
                    Label(justCopied ? "已复制" : "复制", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 6)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭\(title)")
        }
        .task(id: justCopied) {
            guard justCopied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }
}
