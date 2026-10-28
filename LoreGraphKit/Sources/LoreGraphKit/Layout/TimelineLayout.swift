import Foundation

/// The window of years the timeline shows, zoomed from millennia to seasons (F-6.1).
public struct TimeWindow: Hashable, Sendable, Codable {
    public var from: Double
    public var to: Double

    public init(from: Double, to: Double) {
        self.from = min(from, to)
        self.to = max(from, to)
    }

    public var span: Double { to - from }
    public var centre: Double { (from + to) / 2 }

    /// Shortest window: one season. Longest: the whole extent.
    public static let minSpan = 0.25

    /// Zoomed by `factor` (above 1 zooms in) around a year, kept inside `bounds`.
    public func zoomed(by factor: Double, around year: Double, within bounds: TimeWindow) -> TimeWindow {
        let f = max(0.01, factor)
        let newSpan = min(max(span / f, Self.minSpan), bounds.span)
        let t = span > 0 ? (year - from) / span : 0.5
        return TimeWindow(from: year - t * newSpan, to: year - t * newSpan + newSpan).clamped(to: bounds)
    }

    /// Moved by some years, kept inside `bounds`.
    public func panned(by years: Double, within bounds: TimeWindow) -> TimeWindow {
        TimeWindow(from: from + years, to: to + years).clamped(to: bounds)
    }

    public func clamped(to bounds: TimeWindow) -> TimeWindow {
        let s = min(span, bounds.span)
        var lo = max(from, bounds.from)
        if lo + s > bounds.to { lo = bounds.to - s }
        return TimeWindow(from: lo, to: lo + s)
    }

    /// Where a year falls, from 0 at `from` to 1 at `to`.
    public func fraction(_ year: Double) -> Double { span > 0 ? (year - from) / span : 0 }

    public func year(atFraction f: Double) -> Double { from + f * span }

    public func overlaps(_ range: ClosedRange<Double>) -> Bool { range.upperBound >= from && range.lowerBound <= to }
}

/// One tick on the timeline's axis.
public struct TimeTick: Hashable, Sendable {
    public var year: Double
    public var label: String
    public var major: Bool
}

/// Lays out the timeline: the overview strip's extent and rows, the reading list's groups, and
/// the axis ticks (F-6.1 to F-6.3).
public struct TimelineLayout: Sendable {
    public struct Bar: Hashable, Sendable, Identifiable {
        public var id: String
        public var item: Timeline.Item
        /// Inner span and the faint outer envelope ("c." dates), in years.
        public var range: ClosedRange<Double>
        public var outer: ClosedRange<Double>?
        public var row: Int
        /// A point in time rather than a span (drawn as a dot).
        public var isPoint: Bool
        /// Runs on past its last known date ("since 1045").
        public var isOpen: Bool
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var items: [Timeline.Item]
    }

    public let items: [Timeline.Item]
    public let present: Double
    public let bars: [Bar]
    public let extent: TimeWindow
    public let rows: Int

    public init(items: [Timeline.Item], present: Double) {
        self.items = items.sorted { Self.start($0) < Self.start($1) }
        self.present = present
        var bars: [Bar] = []
        var rowEnds: [Double] = []
        var lo = Double.infinity, hi = -Double.infinity
        for item in self.items {
            guard let (range, outer, isOpen) = Self.ranges(item, present: present) else { continue }
            let drawn = outer ?? range
            lo = min(lo, drawn.lowerBound)
            hi = max(hi, drawn.upperBound)
            // greedy rows so bars never overlap in the strip
            let gap = max(0.001, (drawn.upperBound - drawn.lowerBound) * 0.02)
            let row = rowEnds.firstIndex { $0 + gap <= drawn.lowerBound } ?? rowEnds.count
            if row == rowEnds.count { rowEnds.append(drawn.upperBound) } else { rowEnds[row] = drawn.upperBound }
            bars.append(Bar(id: item.id + ":" + item.kind, item: item, range: range, outer: outer, row: row,
                            isPoint: range.upperBound - range.lowerBound <= 1.0001 && item.date.precision != "decade",
                            isOpen: isOpen))
        }
        if lo > hi { lo = present - 100; hi = present }
        let pad = max(1, (hi - lo) * 0.03)
        self.bars = bars
        self.extent = TimeWindow(from: lo - pad, to: hi + pad)
        self.rows = rowEnds.count
    }

    static func start(_ item: Timeline.Item) -> Double {
        item.date.outer?.from ?? item.date.from ?? item.date.to ?? .infinity
    }

    /// The inner span, the outer envelope, and whether the span is open-ended. Open ends run to
    /// the present; an open start is drawn as a point at its end.
    static func ranges(_ item: Timeline.Item, present: Double) -> (ClosedRange<Double>, ClosedRange<Double>?, Bool)? {
        let d = item.date
        guard d.from != nil || d.to != nil else { return nil }
        let isOpen = d.from != nil && d.to == nil
        let lo = d.from ?? (d.to! - 1)
        let hi = d.to ?? max(lo + 1, present)
        let range = lo...max(lo, hi)
        var outer: ClosedRange<Double>?
        if let o = d.outer {
            let olo = min(o.from ?? lo, lo), ohi = max(o.to ?? hi, hi)
            outer = olo...ohi
        }
        return (range, outer, isOpen)
    }

    /// Bars that show in a window.
    public func bars(in window: TimeWindow) -> [Bar] {
        bars.filter { window.overlaps($0.outer ?? $0.range) }
    }

    /// The reading list grouped by decade, or by century when the history is long (F-6.1).
    public func groups(in window: TimeWindow? = nil) -> [Group] {
        let shown = window.map { w in bars.filter { w.overlaps($0.outer ?? $0.range) }.map(\.item) } ?? items
        let span = (window ?? extent).span
        let size: Double = span > 400 ? 100 : 10
        var order: [String] = []
        var groups: [String: [Timeline.Item]] = [:]
        for item in shown {
            let s = Self.start(item)
            let title = s.isFinite ? Self.groupTitle(floor(s / size) * size, size: size) : "Undated"
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        return order.map { Group(title: $0, items: groups[$0]!) }
    }

    static func groupTitle(_ start: Double, size: Double) -> String {
        let y = Int(start)
        if size >= 100 { return "YV \(y) to \(y + 99)" }
        return "The \(y)s"
    }

    /// Items grouped by lane under a scheme (type, faction, place, person), lanes in first-seen
    /// order, items without a lane last (F-6.3).
    public func lanes(_ scheme: String) -> [Group] {
        var order: [String] = []
        var groups: [String: [Timeline.Item]] = [:]
        for item in items {
            let lane = item.lane(scheme) ?? "Other"
            if groups[lane] == nil { order.append(lane) }
            groups[lane, default: []].append(item)
        }
        let sorted = order.filter { $0 != "Other" } + (order.contains("Other") ? ["Other"] : [])
        return sorted.map { Group(title: $0, items: groups[$0]!) }
    }

    /// Axis ticks for a window: at most about `maxTicks`, from millennia down to seasons.
    public static func ticks(_ window: TimeWindow, maxTicks: Int = 8) -> [TimeTick] {
        let steps: [Double] = [0.25, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000]
        let s = steps.first { window.span / $0 <= Double(max(1, maxTicks)) }
            ?? 1000 * (window.span / 1000 / Double(max(1, maxTicks))).rounded(.up)
        var out: [TimeTick] = []
        var y = (window.from / s).rounded(.up) * s
        let seasons = ["winter", "spring", "summer", "autumn"]
        while y <= window.to + 1e-9 {
            let whole = y.rounded() == y
            let label: String
            if s < 1 {
                let q = Int(((y - floor(y)) * 4).rounded()) % 4
                label = q == 0 ? "YV \(Int(floor(y)))" : seasons[q]
            } else {
                label = "\(Int(y))"
            }
            out.append(TimeTick(year: y, label: label, major: whole && Int(y) % Int(max(1, s * 2)) == 0))
            y += s
        }
        return out
    }
}

/// Years as the map's slider and the strip write them.
public enum YearText {
    /// "spring YV 1131": the season from the quarter of the year (the server's words are used
    /// wherever it sends them).
    public static func label(_ year: Double) -> String {
        let seasons = ["winter", "spring", "summer", "autumn"]
        let whole = floor(year)
        let q = Int(((year - whole) * 4).rounded()) % 4
        let y = Int(whole) + (((year - whole) * 4).rounded() >= 4 ? 1 : 0)
        return "\(seasons[q]) YV \(y)"
    }

    /// The slider's range: from YV 900 or the first era, whichever is earlier, to the present.
    public static func sliderRange(eras: [Timeline.Era], present: Double) -> ClosedRange<Double> {
        let first = eras.compactMap(\.span.from).map { floor($0) }.min() ?? 900
        let lo = min(900, first)
        return lo...max(lo + 1, present)
    }
}
