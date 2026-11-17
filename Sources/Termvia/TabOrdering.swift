import SwiftUI

enum TabOrdering {
    /// Move existing objects without replacing their sessions, buffers or selection.
    static func moving<Element, ID: Hashable>(_ elements: [Element], ids: [ID], before target: ID?, id: KeyPath<Element, ID>) -> [Element]? {
        let sourceIDs = Set(ids)
        let allIDs = elements.map { $0[keyPath: id] }
        guard !ids.isEmpty, sourceIDs.count == ids.count, Set(allIDs).count == elements.count,
              sourceIDs.isSubset(of: Set(allIDs)), target.map({ allIDs.contains($0) && !sourceIDs.contains($0) }) ?? true else { return nil }
        let moved = ids.compactMap { source in elements.first { $0[keyPath: id] == source } }
        var remaining = elements.filter { !sourceIDs.contains($0[keyPath: id]) }
        let index = target.flatMap { target in remaining.firstIndex { $0[keyPath: id] == target } } ?? remaining.endIndex
        remaining.insert(contentsOf: moved, at: index)
        return remaining
    }
}

/// Shared viewport insets keep the system glass rim inside the scroll clip.
struct CompactTabStrip<Item, ID: Hashable & Sendable, Tab: View, Trailing: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    let selected: ID?
    let move: ([ID], ID?) -> Void
    @ViewBuilder let tab: (Item) -> Tab
    @ViewBuilder let trailing: () -> Trailing
    static var height: CGFloat { 34 }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(items, id: id) { item in tab(item).id(item[keyPath: id]) }.reorderable()
                        trailing()
                    }
                    .frame(minWidth: max(0, geometry.size.width - 8), minHeight: Self.height, alignment: .leading)
                    .reorderContainer(for: Item.self, itemID: id) { difference in
                        switch difference.destination.position {
                        case .before(let target): move(difference.sources, target)
                        case .end: move(difference.sources, nil)
                        }
                    }
                }
                .contentMargins(.horizontal, 4, for: .scrollContent)
                .scrollIndicators(.hidden)
                .onAppear { if let selected { reader.scrollTo(selected) } }
                .onChange(of: selected) { _, value in if let value { reader.scrollTo(value) } }
                .onChange(of: geometry.size.width) { _, _ in if let selected { reader.scrollTo(selected) } }
            }
        }.frame(height: Self.height)
    }
}
