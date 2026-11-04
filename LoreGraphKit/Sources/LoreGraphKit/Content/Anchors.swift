import Foundation

/// Where a comment is in a section's text (loregraph ADR D-84), on the app's side.
///
/// The text is what a reader sees: the text of the section's HTML outside figures, with every run
/// of whitespace one space. The server (`app/domain/anchors.py`) and the web app
/// (`frontend/src/lib/anchors.ts`) take the same text from the same HTML, so a passage picked here
/// is found by the server. Positions never cross between them: the server sends the passage it
/// found, which occurrence of it that is and the words around it, and the app finds it again in
/// its own copy. Text is counted in Unicode scalars, as the server counts code points.
public enum Anchors {
    /// Characters of context sent with a quote, on either side.
    public static let context = 32
    /// The longest quote the server takes.
    public static let maxQuote = 2000

    /// Elements whose text is not part of a section's text (an image's caption and credit).
    static let skipped: Set<String> = ["figure", "script", "style", "template"]
    /// Elements that start a new line when the text is shown for picking a passage.
    static let paragraphs: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre",
                                          "table", "div", "section", "article", "hr", "dl"]
    static let lines: Set<String> = ["li", "tr", "br", "dt", "dd"]
    /// Containers a highlight is never put straight into (the space between two paragraphs).
    static let containers: Set<String> = ["#root", "body", "div", "ul", "ol", "dl", "table", "thead", "tbody", "tfoot", "tr",
                                          "blockquote", "section"]

    /// JavaScript's `\s`, which both the server and the web app collapse.
    public static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    /// Every run of whitespace one space, none at either end (the server's `collapse`).
    public static func collapse(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for s in text.unicodeScalars {
            if isSpace(s) {
                space = !out.isEmpty
            } else {
                if space { out.append(" ") }
                out.append(s)
                space = false
            }
        }
        return String(out)
    }

    /// A section's text with where each character comes from in the HTML's tokens.
    struct TextMap {
        var text: [Unicode.Scalar] = []
        /// For each character: the token and the scalar offset in it.
        var at: [(token: Int, offset: Int)] = []
        /// Before which characters a new paragraph (2) or line (1) starts, for showing the text.
        var breaks: [Int: Int] = [:]
    }

    static func textMap(_ tokens: [HTMLContent.Token]) -> TextMap {
        var map = TextMap()
        var skipping = 0
        var pendingBreak = 0
        for (t, token) in tokens.enumerated() {
            switch token {
            case .start(let name, _, let selfClosing):
                if skipped.contains(name), !selfClosing { skipping += 1 }
                if paragraphs.contains(name) { pendingBreak = 2 } else if lines.contains(name) { pendingBreak = max(pendingBreak, 1) }
            case .end(let name):
                if skipped.contains(name), skipping > 0 { skipping -= 1 }
                if paragraphs.contains(name) { pendingBreak = 2 } else if lines.contains(name) { pendingBreak = max(pendingBreak, 1) }
            case .text(let s):
                guard skipping == 0 else { continue }
                for (i, c) in s.unicodeScalars.enumerated() {
                    if !isSpace(c) {
                        if pendingBreak > 0, !map.text.isEmpty {
                            let at = map.text.last == " " ? map.text.count - 1 : map.text.count
                            map.breaks[at] = max(map.breaks[at] ?? 0, pendingBreak)
                        }
                        pendingBreak = 0
                        map.text.append(c)
                        map.at.append((t, i))
                    } else if let last = map.text.last, last != " " {
                        map.text.append(" ")
                        map.at.append((t, i))
                    }
                }
            }
        }
        if map.text.last == " " {
            map.text.removeLast()
            map.at.removeLast()
        }
        map.breaks = map.breaks.filter { $0.key < map.text.count }
        return map
    }

    /// A section's text as a reader sees it, from its HTML (the server's `html_text`).
    public static func sectionText(_ html: String) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: textMap(HTMLContent.Tokenizer.tokens(html)).text)
        return String(v)
    }

    /// Where a passage starts in the text, overlapping repeats included.
    static func occurrences(_ text: [Unicode.Scalar], _ passage: [Unicode.Scalar]) -> [Int] {
        guard !passage.isEmpty, passage.count <= text.count else { return [] }
        var out: [Int] = []
        var i = 0
        while i + passage.count <= text.count {
            if text[i] == passage[0], Array(text[i..<(i + passage.count)]) == passage { out.append(i) }
            i += 1
        }
        return out
    }

    /// Where the passage the server found is in this copy of the text: its occurrence, or, when
    /// the copies count differently, the occurrence whose surroundings match best.
    static func find(_ text: [Unicode.Scalar], _ anchor: PageComment.Anchor) -> Range<Int>? {
        guard let passage = anchor.text, !passage.isEmpty else { return nil }
        let p = Array(passage.unicodeScalars)
        let starts = occurrences(text, p)
        guard let first = starts.first else { return nil }
        let prefix = Array((anchor.prefix ?? "").unicodeScalars)
        let suffix = Array((anchor.suffix ?? "").unicodeScalars)
        func fits(_ s: Int) -> Int {
            let before = Array(text[max(0, s - context)..<s])
            let after = Array(text[(s + p.count)..<min(text.count, s + p.count + context)])
            return sharedEnd(before, prefix) + sharedStart(after, suffix)
        }
        var start = first
        if let n = anchor.occurrence, n >= 0, n < starts.count {
            start = starts[n]
        } else {
            for s in starts.dropFirst() where fits(s) > fits(start) { start = s }
        }
        return start..<(start + p.count)
    }

    static func sharedEnd(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[a.count - 1 - n] == b[b.count - 1 - n] { n += 1 }
        return n
    }

    static func sharedStart(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        return n
    }

    // MARK: - highlights

    /// A comment's passage to highlight.
    public struct Highlight: Hashable, Sendable {
        public var id: String
        public var anchor: PageComment.Anchor

        public init(id: String, anchor: PageComment.Anchor) {
            self.id = id
            self.anchor = anchor
        }
    }

    /// The HTML's tokens with each highlighted passage wrapped in `<mark data-comments="id …">`
    /// (marks add no text, so every later passage reads the same). Passages not found are left out.
    static func marked(_ tokens: [HTMLContent.Token], _ highlights: [Highlight]) -> [HTMLContent.Token] {
        guard !highlights.isEmpty else { return tokens }
        let map = textMap(tokens)
        // which comments cover each character of the text
        var cover: [[String]] = Array(repeating: [], count: map.text.count)
        var any = false
        for h in highlights {
            guard let r = find(map.text, h.anchor) else { continue }
            for i in r { cover[i].append(h.id) }
            any = true
        }
        guard any else { return tokens }
        // per token: the covered scalar offsets and their comments
        var perToken: [Int: [Int: [String]]] = [:]
        for (i, ids) in cover.enumerated() where !ids.isEmpty {
            let (t, offset) = map.at[i]
            perToken[t, default: [:]][offset] = ids
        }
        var out: [HTMLContent.Token] = []
        var stack: [String] = ["#root"]
        for (t, token) in tokens.enumerated() {
            switch token {
            case .start(let name, _, let selfClosing):
                out.append(token)
                if !selfClosing && !HTMLContent.voidElements.contains(name) { stack.append(name) }
            case .end(let name):
                out.append(token)
                if let i = stack.lastIndex(of: name), i > 0 { stack.removeSubrange(i...) }
            case .text(let s):
                guard let covered = perToken[t] else {
                    out.append(token)
                    continue
                }
                let scalars = Array(s.unicodeScalars)
                // a run of whitespace between blocks takes no mark
                if scalars.allSatisfy(isSpace), containers.contains(stack.last ?? "#root") {
                    out.append(token)
                    continue
                }
                // the comments over each scalar; the extra spaces of a run (not in the text) go with
                // the characters on both sides when those share a mark
                var idsAt: [[String]] = Array(repeating: [], count: scalars.count)
                var mapped = Array(repeating: false, count: scalars.count)
                for (o, ids) in covered where o < scalars.count {
                    idsAt[o] = ids
                    mapped[o] = true
                }
                var o = 0
                while o < scalars.count {
                    guard !mapped[o] else { o += 1; continue }
                    var e = o
                    while e < scalars.count, !mapped[e] { e += 1 }
                    if o > 0, e < scalars.count, idsAt[o - 1] == idsAt[e], !idsAt[e].isEmpty {
                        for k in o..<e { idsAt[k] = idsAt[e] }
                    }
                    o = e
                }
                var i = 0
                while i < scalars.count {
                    let ids = idsAt[i]
                    var j = i + 1
                    while j < scalars.count, idsAt[j] == ids { j += 1 }
                    var piece = String.UnicodeScalarView()
                    piece.append(contentsOf: scalars[i..<j])
                    if ids.isEmpty {
                        out.append(.text(String(piece)))
                    } else {
                        out.append(.start("mark", ["data-comments": ids.joined(separator: " ")], selfClosing: false))
                        out.append(.text(String(piece)))
                        out.append(.end("mark"))
                    }
                    i = j
                }
            }
        }
        return out
    }

    // MARK: - picking a passage

    /// A passage picked in a section's text, ready for `add_comment`.
    public struct Picked: Hashable, Sendable {
        public var quote: String
        public var prefix: String
        public var suffix: String
    }

    /// A section's text laid out for picking a passage: paragraphs on lines of their own, with
    /// each shown character's place in the section's text.
    public struct Selectable: Hashable, Sendable {
        /// The section's text as the server reads it.
        public let text: String
        /// The same text with paragraph breaks, to show.
        public let display: String
        let scalars: [Unicode.Scalar]
        /// For each scalar of `display`: the position in `scalars` before it, and the character it shows (nil for a break).
        let positions: [Int]
        let sources: [Int?]

        public init(html: String) {
            let map = textMap(HTMLContent.Tokenizer.tokens(html))
            scalars = map.text
            var v = String.UnicodeScalarView()
            v.append(contentsOf: map.text)
            text = String(v)
            var shown = String.UnicodeScalarView()
            var positions: [Int] = []
            var sources: [Int?] = []
            for (i, c) in map.text.enumerated() {
                if let b = map.breaks[i], i > 0 {
                    for _ in 0..<b {
                        shown.append("\n")
                        positions.append(i)
                        sources.append(nil)
                    }
                    if c == " " { continue }   // the space the break stands for
                }
                shown.append(c)
                positions.append(i)
                sources.append(i)
            }
            display = String(shown)
            self.positions = positions
            self.sources = sources
        }

        public var isEmpty: Bool { scalars.isEmpty }

        /// The passage a selection of `display` covers, in UTF-16 units (a text view's range),
        /// trimmed of spaces at its ends; nil when it holds no text.
        public func pick(utf16 range: Range<Int>) -> Picked? {
            let units = Array(display.utf16)
            guard range.lowerBound >= 0, range.upperBound <= units.count, !range.isEmpty else { return nil }
            // UTF-16 offsets to scalar offsets of `display`
            var scalarAt: [Int] = []
            scalarAt.reserveCapacity(units.count + 1)
            var n = 0
            for s in display.unicodeScalars {
                scalarAt.append(n)
                if s.value > 0xFFFF { scalarAt.append(n) }
                n += 1
            }
            scalarAt.append(n)
            let first = scalarAt[range.lowerBound]
            let last = scalarAt[range.upperBound] - 1
            guard first <= last, last < positions.count else { return nil }
            var start = positions[first]
            var end = sources[last].map { $0 + 1 } ?? positions[last]
            while start < end, scalars[start] == " " { start += 1 }
            while end > start, scalars[end - 1] == " " { end -= 1 }
            return Selectable.picked(scalars, start, end)
        }

        static func picked(_ text: [Unicode.Scalar], _ start: Int, _ end: Int) -> Picked? {
            guard start < end else { return nil }
            func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
                var v = String.UnicodeScalarView()
                v.append(contentsOf: s)
                return String(v)
            }
            return Picked(quote: string(text[start..<end]), prefix: string(text[max(0, start - context)..<start]),
                          suffix: string(text[end..<min(text.count, end + context)]))
        }

        /// Where a comment's passage is in `display`, in UTF-16 units (to show it selected).
        public func displayRange(of anchor: PageComment.Anchor) -> Range<Int>? {
            guard let r = find(scalars, anchor) else { return nil }
            guard let lo = sources.firstIndex(where: { $0 == r.lowerBound }),
                  let hi = sources.lastIndex(where: { $0 == r.upperBound - 1 }) else { return nil }
            var u = 0
            var startUnit = 0
            var endUnit = 0
            for (i, s) in display.unicodeScalars.enumerated() {
                if i == lo { startUnit = u }
                u += s.value > 0xFFFF ? 2 : 1
                if i == hi { endUnit = u }
            }
            return startUnit..<endUnit
        }
    }
}
