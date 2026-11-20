import AppKit

/// Daily usage numbers (local only): what LocalType typed for you each day, and in which app.
final class Stats {
    static let shared = Stats()

    struct Day: Codable { var completions = 0, words = 0, chars = 0, apps: [String: Int] = [:] }
    enum Metric: Int, CaseIterable { case words, completions, characters
        var title: String { ["Words", "Completions", "Characters"][rawValue] }
        func value(_ d: Day) -> Int { [d.words, d.completions, d.chars][rawValue] }
    }
    enum Grouping: Int, CaseIterable { case day, week, month
        var title: String { ["Day", "Week", "Month"][rawValue] }
    }

    private(set) var days: [String: Day] = [:]
    private let url = AppPaths.support.appendingPathComponent("stats.json")
    private static let keyFormat: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([String: Day].self, from: d) { days = v }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(days) else { return }
        try? d.write(to: url, options: .atomic)
    }

    static func key(_ date: Date) -> String { keyFormat.string(from: date) }

    /// Text LocalType inserted for you (one accepted completion, word or emoji).
    func record(_ text: String, app: String?) {
        let k = Stats.key(Date())
        var d = days[k] ?? Day()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        d.completions += 1
        d.words += words
        d.chars += text.count
        if let app { d.apps[app, default: 0] += words }
        days[k] = d
        save()
    }

    func reset() { days = [:]; save() }

    var today: Day { days[Stats.key(Date())] ?? Day() }

    /// Buckets for the last `span` days, oldest first: (bucket start, value).
    func series(span: Int, grouping: Grouping, metric: Metric) -> [(Date, Int)] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(span - 1), to: end) else { return [] }
        var buckets: [(Date, Int)] = []
        var cursor = start
        while cursor <= end {
            let bucketStart: Date
            switch grouping {
            case .day: bucketStart = cursor
            case .week: bucketStart = cal.dateInterval(of: .weekOfYear, for: cursor)?.start ?? cursor
            case .month: bucketStart = cal.dateInterval(of: .month, for: cursor)?.start ?? cursor
            }
            let v = days[Stats.key(cursor)].map(metric.value) ?? 0
            if let last = buckets.last, last.0 == bucketStart { buckets[buckets.count - 1].1 += v } else { buckets.append((bucketStart, v)) }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        return buckets
    }

    /// Total and average per active day over the last `span` days.
    func summary(span: Int, metric: Metric) -> (total: Int, perActiveDay: Int, words: Int) {
        let s = series(span: span, grouping: .day, metric: metric)
        let words = series(span: span, grouping: .day, metric: .words).reduce(0) { $0 + $1.1 }
        let total = s.reduce(0) { $0 + $1.1 }
        let active = s.filter { $0.1 > 0 }.count
        return (total, active > 0 ? total / active : 0, words)
    }

    /// Typing time saved for `words`, as a range at 40 and 30 words per minute.
    static func timeSaved(words: Int) -> String {
        guard words > 0 else { return "–" }
        let lo = Double(words) / 40, hi = Double(words) / 30   // minutes
        if hi < 1.5 { return "≈\(Int((lo * 60).rounded()))–\(Int((hi * 60).rounded())) seconds" }
        if hi < 90 { return "≈\(Int(lo.rounded()))–\(Int(hi.rounded())) minutes" }
        return String(format: "≈%.1f–%.1f hours", lo / 60, hi / 60)
    }
}

/// Simple bar chart for the Statistics page.
final class BarChartView: NSView {
    var data: [(Date, Int)] = [] { didSet { needsDisplay = true } }
    var grouping: Stats.Grouping = .day

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    override func draw(_ dirty: NSRect) {
        let labelH: CGFloat = 16, topPad: CGFloat = 16
        let plot = NSRect(x: 0, y: labelH, width: bounds.width, height: bounds.height - labelH - topPad)
        let maxV = max(data.map(\.1).max() ?? 0, 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: labelH, width: bounds.width, height: 1).fill()
        guard !data.isEmpty else { return }
        let slot = plot.width / CGFloat(data.count)
        let barW = max(2, min(28, slot * 0.7))
        for (i, (_, v)) in data.enumerated() where v > 0 {
            let h = plot.height * CGFloat(v) / CGFloat(maxV)
            let r = NSRect(x: plot.minX + slot * CGFloat(i) + (slot - barW) / 2, y: plot.minY, width: barW, height: max(2, h))
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: min(3, barW / 2), yRadius: min(3, barW / 2)).fill()
        }
        // Max value at the top left, first and last bucket dates under the axis.
        ("\(maxV)" as NSString).draw(at: NSPoint(x: 0, y: bounds.height - topPad + 2), withAttributes: attrs)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(grouping == .month ? "MMM yyyy" : "d MMM")
        let first = f.string(from: data.first!.0) as NSString, last = f.string(from: data.last!.0) as NSString
        first.draw(at: NSPoint(x: 0, y: 1), withAttributes: attrs)
        let lw = last.size(withAttributes: attrs).width
        last.draw(at: NSPoint(x: bounds.width - lw, y: 1), withAttributes: attrs)
    }
}
