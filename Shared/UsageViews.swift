import SwiftUI

// Small SwiftUI building blocks used both in the popover and in the widget.

enum Palette {
    static func color(for percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

enum Fmt {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "2ч 14м", "3д 4ч", "5м"
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return L("сейчас", "now") }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return L("\(d)д \(h)ч", "\(d)d \(h)h") }
        if h > 0 { return L("\(h)ч \(m)м", "\(h)h \(m)m") }
        return L("\(max(m, 1))м", "\(max(m, 1))m")
    }
}

struct UsageBar: View {
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(percent, 0), 100)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Palette.color(for: clamped))
                    .frame(width: max(height, geo.size.width * CGFloat(clamped / 100)))
            }
        }
        .frame(height: height)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    var compact = false

    private var showsReset: Bool { !compact && window.resetsAt != nil }
    private var showsSubDetail: Bool { window.usedPercent != nil && window.detail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label).lineLimit(1)
                Spacer(minLength: 4)
                if let p = window.usedPercent {
                    Text(Fmt.percent(p)).monospacedDigit().fontWeight(.medium)
                } else if let d = window.detail {
                    Text(d).monospacedDigit().fontWeight(.medium)
                }
            }
            .font(compact ? .caption2 : .caption)

            if let p = window.usedPercent {
                UsageBar(percent: p, height: compact ? 4 : 6)
            }

            if showsReset || showsSubDetail {
                HStack(spacing: 4) {
                    if showsSubDetail, let d = window.detail { Text(d) }
                    Spacer(minLength: 0)
                    if showsReset, let r = window.resetsAt { Text(L("сброс через ", "resets in ") + Fmt.remaining(until: r)) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
