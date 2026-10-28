import Foundation

/// The view every screen reads through (F-3): the year, whose eyes, the calendar and the
/// preview level. It travels with every read as as_of, viewpoint, calendar and view_as, and is
/// remembered per world.
public struct ViewState: Codable, Hashable, Sendable {
    public struct Viewpoint: Codable, Hashable, Sendable {
        public var ref: String
        public var title: String

        public init(ref: String, title: String) {
            self.ref = ref
            self.title = title
        }
    }

    /// The year shown, as a fractional YV number; nil is "all time".
    public var asOf: Double?
    /// The server's words for that year ("summer YV 1020"), shown in the banner.
    public var asOfLabel: String?
    public var viewpoint: Viewpoint?
    /// A calendar key; nil is the world's default.
    public var calendar: String?
    /// Lowers what you see to preview a page as a player would. Never raises the ceiling.
    public var viewAs: Visibility?

    public init(asOf: Double? = nil, asOfLabel: String? = nil, viewpoint: Viewpoint? = nil, calendar: String? = nil,
                viewAs: Visibility? = nil) {
        self.asOf = asOf
        self.asOfLabel = asOfLabel
        self.viewpoint = viewpoint
        self.calendar = calendar
        self.viewAs = viewAs
    }

    public static let `default` = ViewState()

    /// Whether anything differs from the plain view, so the banner shows (F-3.5).
    public var isDefault: Bool { asOf == nil && viewpoint == nil && calendar == nil && viewAs == nil }

    /// The query items every read carries.
    public var queryItems: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let asOf { q.append(URLQueryItem(name: "as_of", value: Self.yearText(asOf))) }
        if let viewpoint { q.append(URLQueryItem(name: "viewpoint", value: viewpoint.ref)) }
        if let calendar { q.append(URLQueryItem(name: "calendar", value: calendar)) }
        if let viewAs, viewAs != .designer { q.append(URLQueryItem(name: "view_as", value: viewAs.rawValue)) }
        return q
    }

    /// The level actually shown: the preview level when it is below the ceiling.
    public func effectiveLevel(ceiling: Visibility) -> Visibility {
        guard let viewAs else { return ceiling }
        return min(viewAs, ceiling)
    }

    /// The banner sentence (F-3.5): "As of summer YV 1020, through Dirk's eyes, shown as Public."
    public func banner(calendarName: String? = nil) -> String? {
        guard !isDefault else { return nil }
        var parts: [String] = []
        if let asOf { parts.append("as of \(asOfLabel ?? "YV \(Self.yearText(asOf))")") }
        if let viewpoint { parts.append("through \(Self.possessive(viewpoint.title)) eyes") }
        if let calendar { parts.append("dates in \(calendarName ?? calendar)") }
        if let viewAs, viewAs != .designer { parts.append("shown as \(viewAs.label)") }
        guard let first = parts.first else { return nil }
        let rest = parts.dropFirst()
        let sentence = ([first.prefix(1).uppercased() + first.dropFirst()] + rest).joined(separator: ", ")
        return sentence + "."
    }

    /// A year as the server reads it: "1020", "1020.414".
    public static func yearText(_ year: Double) -> String {
        if year.rounded() == year { return String(Int(year)) }
        var s = String(format: "%.3f", year)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? "\(name)'" : "\(name)'s"
    }

    /// The view after switching worlds: year and viewpoint belong to one world (F-2.2).
    public func forNewWorld() -> ViewState {
        ViewState(calendar: nil, viewAs: viewAs)
    }
}
