import Foundation

/// A run of inline prose with one style, ready to draw: the app turns runs into an attributed
/// string with its own fonts. A wiki link becomes `loregraph://wiki/<slug>`, which the app opens
/// itself (and which `WebLink.parse` reads).
public struct ProseRun: Hashable, Sendable {
    public struct Style: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let emphasis = Style(rawValue: 1)
        public static let strong = Style(rawValue: 2)
        public static let code = Style(rawValue: 4)
        public static let strike = Style(rawValue: 8)
    }

    public var text: String
    public var style: Style
    public var link: URL?
    /// The comments whose passage this run is in (highlighted, ADR D-84).
    public var comments: [String]

    public init(_ text: String, style: Style = [], link: URL? = nil, comments: [String] = []) {
        self.text = text
        self.style = style
        self.link = link
        self.comments = comments
    }
}

public enum Prose {
    public static func pageURL(_ slug: String) -> URL {
        URL(string: "loregraph://wiki/\(segment(slug))")!
    }

    /// The link a highlighted passage opens: its comment (the page shows it).
    public static func commentURL(_ id: String) -> URL {
        URL(string: "loregraph://comment/\(segment(id))")!
    }

    /// The comment a `commentURL` names.
    public static func commentID(_ url: URL) -> String? {
        guard url.scheme == OAuthClient.callbackScheme, url.host == "comment" else { return nil }
        let id = url.path.split(separator: "/").first.map(String.init)
        return id.flatMap { $0.removingPercentEncoding }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Inline prose as runs; neighbouring runs with the same style and link are joined.
    public static func runs(_ inlines: [Inline]) -> [ProseRun] {
        var out: [ProseRun] = []
        for inline in inlines { append(inline, style: [], link: nil, comments: [], to: &out) }
        return out
    }

    static func append(_ inline: Inline, style: ProseRun.Style, link: URL?, comments: [String], to out: inout [ProseRun]) {
        func add(_ text: String, _ style: ProseRun.Style) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.style == style, last.link == link, last.comments == comments {
                out[out.count - 1].text += text
            } else {
                out.append(ProseRun(text, style: style, link: link, comments: comments))
            }
        }
        func each(_ c: [Inline], _ style: ProseRun.Style, _ link: URL?, _ comments: [String]) {
            c.forEach { append($0, style: style, link: link, comments: comments, to: &out) }
        }
        switch inline {
        case .text(let s): add(s, style)
        case .code(let s): add(s, style.union(.code))
        case .lineBreak: add("\n", style)
        case .image(_, let alt): if !alt.isEmpty { add("[\(alt)]", style) }
        case .emphasis(let c): each(c, style.union(.emphasis), link, comments)
        case .strong(let c): each(c, style.union(.strong), link, comments)
        case .strike(let c): each(c, style.union(.strike), link, comments)
        case .mark(let ids, let c): each(c, style, link, comments + ids.filter { !comments.contains($0) })
        case .link(let target, let c):
            let url: URL
            switch target {
            case .page(let slug): url = pageURL(slug)
            case .web(let u): url = u
            }
            each(c, style, url, comments)
        }
    }

    /// The slugs a block links to, for prefetching previews.
    public static func linkedPages(_ blocks: [Block]) -> [String] {
        var seen: [String] = []
        func walk(_ inlines: [Inline]) {
            for i in inlines {
                switch i {
                case .link(.page(let slug), let c):
                    if !seen.contains(slug) { seen.append(slug) }
                    walk(c)
                case .emphasis(let c), .strong(let c), .strike(let c), .link(_, let c), .mark(_, let c): walk(c)
                default: break
                }
            }
        }
        func walkBlocks(_ bs: [Block]) {
            for b in bs {
                switch b {
                case .paragraph(let i), .heading(_, let i): walk(i)
                case .list(_, _, let items): items.forEach(walkBlocks)
                case .quote(let inner): walkBlocks(inner)
                case .table(let h, let rows, _):
                    h.forEach(walk)
                    rows.forEach { $0.forEach(walk) }
                case .code, .rule: break
                }
            }
        }
        walkBlocks(blocks)
        return seen
    }
}
