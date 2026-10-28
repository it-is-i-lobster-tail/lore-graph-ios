import LoreGraphKit
import SwiftUI

extension Color {
    static let accentInk = Color(red: 63 / 255, green: 63 / 255, blue: 196 / 255)
    static let designer = Color(red: 109 / 255, green: 40 / 255, blue: 217 / 255)
    static let restricted = Color(red: 180 / 255, green: 83 / 255, blue: 9 / 255)
    static let claim = Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255)

    init(_ c: RGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// The colour that goes with a visibility mark (always beside its words, never alone).
    static func visibility(_ v: Visibility?) -> Color {
        switch v {
        case .designer: .designer
        case .restricted: .restricted
        default: .secondary
        }
    }
}

extension Font {
    /// The reading serif for page text (F-4.4).
    static func reading(_ style: Font.TextStyle = .body) -> Font { .system(style, design: .serif) }
}

/// "Designer only" or "Restricted", with a lock: never colour alone (F-4.8).
struct VisibilityChip: View {
    let visibility: Visibility?
    var compact = false

    var body: some View {
        if let v = visibility, v != .public {
            Label(compact ? (v == .designer ? "Designer" : "Restricted") : v.label, systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.visibility(v))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.visibility(v).opacity(0.12), in: Capsule())
                .accessibilityLabel(v.label)
        }
    }
}

/// A canon status that isn't plain canon (proposed, draft, retired).
struct CanonChip: View {
    let canon: Canon?

    var body: some View {
        if let c = canon, !c.isCanon {
            Text(c.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        }
    }
}

/// A small grey chip (kinds, roles, stances).
struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// A coloured edge down the side of designer-only and restricted material (F-4.8).
struct VisibilityEdge: ViewModifier {
    let visibility: Visibility?

    func body(content: Content) -> some View {
        if let v = visibility, v != .public {
            content
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.visibility(v)).frame(width: 3)
                }
        } else {
            content
        }
    }
}

extension View {
    func visibilityEdge(_ v: Visibility?) -> some View { modifier(VisibilityEdge(visibility: v)) }
}

/// A row for a page: type symbol, title, kind and short description.
struct EntityRow: View {
    let card: EntityCard
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: (card.type ?? .misc).symbol)
                .foregroundStyle(Color.accentInk)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.shownTitle).font(.body.weight(.medium))
                    VisibilityChip(visibility: card.visibility, compact: true)
                    CanonChip(canon: card.canon)
                }
                if let line = detail ?? card.shortDescription ?? kindLabel(card.kind) {
                    Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A byte count in words ("12.4 MB").
func byteText(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}
