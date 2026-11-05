import Foundation
import Observation

/// The family tree (F-8): drawn around a person, with the kinship between the root and a second
/// person picked on the tree.
@Observable
@MainActor
public final class FamilyModel {
    public let ref: String
    public private(set) var options: FamilyOptions
    public private(set) var loader: Loader<FamilyTree>
    /// The second person, for kinship (F-8.6).
    public private(set) var selected: String?
    public private(set) var kinship: Loader<Kinship>?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored private var memo: (tree: FamilyTree, year: Double?, layout: FamilyLayout)?

    public init(ref: String, options: FamilyOptions = FamilyOptions(), context: ReadContext) {
        self.ref = ref
        self.options = options
        self.context = context
        loader = context.loader(Self.endpoint(ref, options))
    }

    static func endpoint(_ ref: String, _ o: FamilyOptions) -> Endpoint<FamilyTree> {
        API.familyTree(ref, up: o.up, down: o.down, mode: o.mode.rawValue, account: o.account)
    }

    public func load() async { await loader.load() }

    public func refresh() async {
        await loader.refresh()
        if let kinship { await kinship.refresh() }
    }

    public func set(_ options: FamilyOptions) async {
        guard options != self.options else { return }
        self.options = options
        loader = context.loader(Self.endpoint(ref, options))
        await loader.load()
    }

    /// Generations up and down, within the server's limits.
    public func more(up: Int = 0, down: Int = 0) async {
        var o = options
        o.up = max(0, min(10, o.up + up))
        o.down = max(0, min(10, o.down + down))
        await set(o)
    }

    /// The year the tree is drawn at: the view's, else the present.
    public var year: Double { context.view.asOf ?? context.present }

    public var layout: FamilyLayout? {
        guard let tree = loader.value else { return nil }
        if let memo, memo.tree == tree, memo.year == year { return memo.layout }
        let layout = FamilyLayout(tree: tree, year: year)
        memo = (tree, year, layout)
        return layout
    }

    /// The root person's ref as the tree names it.
    public var rootRef: String { loader.value?.root.ref ?? ref }

    /// Picks a second person to see how they are related; picking the root or the same person
    /// again clears it.
    public func select(_ person: String?) async {
        guard let person, person != rootRef, person != selected else {
            selected = nil
            kinship = nil
            return
        }
        selected = person
        let k = context.loader(API.kinship(rootRef, person))
        kinship = k
        await k.load()
    }

    /// The lines to highlight: the kinship path between the two.
    public var highlighted: [FamilyLayout.Line] {
        guard let path = kinship?.value?.path?.map(\.ref), path.count > 1, let layout else { return [] }
        return layout.lines(along: path)
    }

    public var shareURL: URL { context.shareURL(.family(ref, options), selected: selected) }
}
