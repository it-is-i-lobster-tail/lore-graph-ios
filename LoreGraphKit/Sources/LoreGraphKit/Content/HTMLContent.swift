import Foundation

/// Where a link in prose goes.
public enum LinkTarget: Hashable, Sendable {
    /// Another wiki page, by slug.
    case page(String)
    /// A web address outside the wiki.
    case web(URL)
}

/// Inline prose.
public indirect enum Inline: Hashable, Sendable {
    case text(String)
    case emphasis([Inline])
    case strong([Inline])
    case strike([Inline])
    case code(String)
    case link(LinkTarget, [Inline])
    case lineBreak
    case image(src: String, alt: String)

    public var plainText: String {
        switch self {
        case .text(let s), .code(let s): s
        case .emphasis(let c), .strong(let c), .strike(let c), .link(_, let c): c.map(\.plainText).joined()
        case .lineBreak: "\n"
        case .image(_, let alt): alt
        }
    }
}

public enum ColumnAlignment: String, Hashable, Sendable { case leading, centre, trailing }

/// Block prose: what the server's sanitised HTML (CommonMark with tables) can hold.
public indirect enum Block: Hashable, Sendable {
    case paragraph([Inline])
    case heading(level: Int, [Inline])
    case list(ordered: Bool, start: Int, items: [[Block]])
    case quote([Block])
    case code(String)
    case rule
    case table(header: [[Inline]], rows: [[[Inline]]], alignments: [ColumnAlignment])

    public var plainText: String {
        switch self {
        case .paragraph(let i), .heading(_, let i): i.map(\.plainText).joined()
        case .list(_, _, let items): items.map { $0.map(\.plainText).joined(separator: "\n") }.joined(separator: "\n")
        case .quote(let b): b.map(\.plainText).joined(separator: "\n")
        case .code(let s): s
        case .rule: ""
        case .table(let h, let rows, _):
            ([h] + rows).map { $0.map { $0.map(\.plainText).joined() }.joined(separator: "\t") }.joined(separator: "\n")
        }
    }
}

/// Reads the HTML loregraph renders for a section (DESIGN.md 12.5: markdown-it, CommonMark with
/// tables, raw HTML off) into blocks the app draws natively. Wiki links become `.page`; a link to
/// a page the reader cannot see arrives as plain text or a "missing" link, and is shown as text.
public enum HTMLContent {
    public static func parse(_ html: String) -> [Block] {
        let root = TreeBuilder.build(Tokenizer.tokens(html))
        return blocks(root.children)
    }

    // MARK: - tree to blocks

    static func blocks(_ nodes: [Node]) -> [Block] {
        var out: [Block] = []
        var pending: [Inline] = []
        func flush() {
            let trimmed = trim(pending)
            if !trimmed.isEmpty { out.append(.paragraph(trimmed)) }
            pending = []
        }
        for node in nodes {
            guard case .element(let e) = node else {
                pending += inlines([node])
                continue
            }
            switch e.name {
            case "p":
                flush()
                let i = trim(inlines(e.children))
                if !i.isEmpty { out.append(.paragraph(i)) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                out.append(.heading(level: Int(e.name.dropFirst()) ?? 2, trim(inlines(e.children))))
            case "ul", "ol":
                flush()
                let items = e.children.compactMap { child -> [Block]? in
                    guard case .element(let li) = child, li.name == "li" else { return nil }
                    return blocks(li.children)
                }
                out.append(.list(ordered: e.name == "ol", start: Int(e.attributes["start"] ?? "") ?? 1, items: items))
            case "blockquote":
                flush()
                out.append(.quote(blocks(e.children)))
            case "pre":
                flush()
                var text = e.textContent
                if text.hasSuffix("\n") { text.removeLast() }
                out.append(.code(text))
            case "hr":
                flush()
                out.append(.rule)
            case "table":
                flush()
                out.append(table(e))
            case "div", "section", "article", "li":
                flush()
                out += blocks(e.children)
            default:
                pending += inlines([node])
            }
        }
        flush()
        return out
    }

    static func table(_ e: Element) -> Block {
        var header: [[Inline]] = []
        var rows: [[[Inline]]] = []
        var alignments: [ColumnAlignment] = []
        func cells(_ tr: Element) -> [(Element, [Inline])] {
            tr.children.compactMap { c in
                guard case .element(let cell) = c, cell.name == "td" || cell.name == "th" else { return nil }
                return (cell, trim(inlines(cell.children)))
            }
        }
        for tr in e.descendants(named: "tr") {
            let row = cells(tr)
            if header.isEmpty && row.contains(where: { $0.0.name == "th" }) {
                header = row.map(\.1)
                alignments = row.map { alignment($0.0.attributes["style"]) }
            } else {
                rows.append(row.map(\.1))
            }
        }
        if alignments.isEmpty { alignments = Array(repeating: .leading, count: max(header.count, rows.first?.count ?? 0)) }
        return .table(header: header, rows: rows, alignments: alignments)
    }

    static func alignment(_ style: String?) -> ColumnAlignment {
        let s = (style ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        if s.contains("text-align:center") { return .centre }
        if s.contains("text-align:right") { return .trailing }
        return .leading
    }

    static func inlines(_ nodes: [Node]) -> [Inline] {
        var out: [Inline] = []
        for node in nodes {
            switch node {
            case .text(let t):
                out.append(.text(collapse(t)))
            case .element(let e):
                switch e.name {
                case "em", "i": out.append(.emphasis(inlines(e.children)))
                case "strong", "b": out.append(.strong(inlines(e.children)))
                case "del", "s": out.append(.strike(inlines(e.children)))
                case "code": out.append(.code(e.textContent))
                case "br": out.append(.lineBreak)
                case "img": out.append(.image(src: e.attributes["src"] ?? "", alt: e.attributes["alt"] ?? ""))
                case "a":
                    let content = inlines(e.children)
                    if let target = linkTarget(e) {
                        out.append(.link(target, content))
                    } else {
                        out += content
                    }
                default: out += inlines(e.children)
                }
            }
        }
        return merge(out)
    }

    static func linkTarget(_ a: Element) -> LinkTarget? {
        if a.attributes["data-missing"] != nil || (a.attributes["class"] ?? "").contains("wikilink-missing") { return nil }
        if let slug = a.attributes["data-slug"], !slug.isEmpty { return .page(slug) }
        guard let href = a.attributes["href"], !href.isEmpty else { return nil }
        if href.hasPrefix("/wiki/") {
            let rest = href.dropFirst("/wiki/".count).split(separator: "#").first.map(String.init) ?? ""
            return rest.isEmpty ? nil : .page(rest.removingPercentEncoding ?? rest)
        }
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else {
            return nil
        }
        return .web(url)
    }

    /// Runs of whitespace as one space, as a browser shows them.
    static func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in s {
            if ch.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(ch)
                lastSpace = false
            }
        }
        return out
    }

    /// Joins neighbouring text and drops doubled spaces between them.
    static func merge(_ items: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for item in items {
            if case .text(let b) = item, case .text(let a)? = out.last {
                out[out.count - 1] = .text(a.hasSuffix(" ") && b.hasPrefix(" ") ? a + b.dropFirst() : a + b)
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// Leading and trailing spaces of a block's inlines removed.
    static func trim(_ items: [Inline]) -> [Inline] {
        var items = merge(items)
        while case .text(let t)? = items.first {
            let s = String(t.drop(while: { $0 == " " }))
            if s.isEmpty { items.removeFirst() } else { items[0] = .text(s); break }
        }
        while case .text(let t)? = items.last {
            var s = t
            while s.hasSuffix(" ") { s.removeLast() }
            if s.isEmpty { items.removeLast() } else { items[items.count - 1] = .text(s); break }
        }
        return items
    }

    // MARK: - a small HTML tree

    struct Element {
        var name: String
        var attributes: [String: String]
        var children: [Node]

        var textContent: String {
            children.map { n -> String in
                switch n {
                case .text(let t): t
                case .element(let e): e.name == "br" ? "\n" : e.textContent
                }
            }.joined()
        }

        func descendants(named name: String) -> [Element] {
            children.flatMap { n -> [Element] in
                guard case .element(let e) = n else { return [] }
                return e.name == name ? [e] : e.descendants(named: name)
            }
        }
    }

    indirect enum Node {
        case text(String)
        case element(Element)
    }

    enum Token: Equatable {
        case start(String, [String: String], selfClosing: Bool)
        case end(String)
        case text(String)
    }

    static let voidElements: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col", "wbr"]
    static let blockElements: Set<String> = ["ul", "ol", "table", "blockquote", "pre", "hr", "div", "h1", "h2", "h3", "h4", "h5", "h6"]

    enum TreeBuilder {
        static func build(_ tokens: [Token]) -> Element {
            var stack = [Element(name: "#root", attributes: [:], children: [])]
            func close() {
                let e = stack.removeLast()
                stack[stack.count - 1].children.append(.element(e))
            }
            for token in tokens {
                switch token {
                case .text(let t):
                    stack[stack.count - 1].children.append(.text(t))
                case .start(let name, let attrs, let selfClosing):
                    // a new paragraph or list item ends an open one, as browsers do
                    if ["p", "li", "tr", "td", "th"].contains(name), let i = stack.lastIndex(where: { $0.name == name }),
                       stack[(i + 1)...].allSatisfy({ !["ul", "ol", "table", "blockquote"].contains($0.name) }) {
                        while stack.count > i { close() }
                    }
                    // and a block inside an open paragraph ends the paragraph
                    if blockElements.contains(name), let i = stack.lastIndex(where: { $0.name == "p" }),
                       stack[(i + 1)...].allSatisfy({ !["ul", "ol", "table", "blockquote"].contains($0.name) }) {
                        while stack.count > i { close() }
                    }
                    let e = Element(name: name, attributes: attrs, children: [])
                    if selfClosing || voidElements.contains(name) {
                        stack[stack.count - 1].children.append(.element(e))
                    } else {
                        stack.append(e)
                    }
                case .end(let name):
                    guard let i = stack.lastIndex(where: { $0.name == name }), i > 0 else { continue }
                    while stack.count > i { close() }
                }
            }
            while stack.count > 1 { close() }
            return stack[0]
        }
    }

    enum Tokenizer {
        static func tokens(_ html: String) -> [Token] {
            var out: [Token] = []
            let chars = Array(html)
            var i = 0
            var text = ""
            func flushText() {
                if !text.isEmpty { out.append(.text(decodeEntities(text))) }
                text = ""
            }
            while i < chars.count {
                let ch = chars[i]
                guard ch == "<" else {
                    text.append(ch)
                    i += 1
                    continue
                }
                // comments
                if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    flushText()
                    var j = i + 4
                    while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                    i = min(chars.count, j + 3)
                    continue
                }
                guard let close = chars[(i + 1)...].firstIndex(of: ">") else {
                    text.append(ch)
                    i += 1
                    continue
                }
                let inner = String(chars[(i + 1)..<close])
                guard let first = inner.first, first.isLetter || first == "/" || first == "!" else {
                    text.append(ch)
                    i += 1
                    continue
                }
                flushText()
                i = close + 1
                if first == "!" { continue }   // doctype
                if first == "/" {
                    out.append(.end(String(inner.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()))
                    continue
                }
                let selfClosing = inner.hasSuffix("/")
                let body = selfClosing ? String(inner.dropLast()) : inner
                let (name, attrs) = parseTag(body)
                out.append(.start(name, attrs, selfClosing: selfClosing))
            }
            flushText()
            return out
        }

        static func parseTag(_ s: String) -> (String, [String: String]) {
            let chars = Array(s)
            var i = 0
            var name = ""
            while i < chars.count, !chars[i].isWhitespace { name.append(chars[i]); i += 1 }
            var attrs: [String: String] = [:]
            while i < chars.count {
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                var key = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "=" { key.append(chars[i]); i += 1 }
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                var value = ""
                if i < chars.count, chars[i] == "=" {
                    i += 1
                    while i < chars.count, chars[i].isWhitespace { i += 1 }
                    if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                        let quote = chars[i]
                        i += 1
                        while i < chars.count, chars[i] != quote { value.append(chars[i]); i += 1 }
                        i += 1
                    } else {
                        while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                    }
                }
                if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
            }
            return (name.lowercased(), attrs)
        }
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "copy": "\u{00A9}", "dagger": "\u{2020}", "middot": "\u{00B7}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = namedEntities[name]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
