/// Pure tree policy; callbacks can read an AX cache or an in-memory fixture.
enum TreeFilter {
    static let containers: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem"]
    static let passiveActions: Set<String> = ["AXShowMenu", "AXScrollToVisible"]
    /// Bounds work per candidate, including cached descendants. Unknown means keep.
    static let maximumProbeDescendants = 200

    static func anonymousContainer(role: String, hasTitle: Bool, hasDescription: Bool,
                                   hasIdentifier: Bool, hasPlaceholder: Bool, hasValue: Bool,
                                   hasKind: Bool, actions: [String]) -> Bool {
        containers.contains(role)
            && !hasTitle && !hasDescription && !hasIdentifier && !hasPlaceholder && !hasValue && !hasKind
            && actions.allSatisfy { passiveActions.contains($0) || $0 == "AXPress" }
    }

    struct Node {
        let role: String
        /// The pre-existing informative rule, before web wrapper folding.
        let informative: Bool
        let anonymousContainer: Bool
        /// nil means the child count could not be read.
        let childCount: Int?
    }

    static func collapseWebContainer<ID: Hashable>(root: ID, inWebArea: Bool,
        maximumDescendants: Int = maximumProbeDescendants,
        node: (ID) -> Node?, children: (ID, Int) -> [ID]) -> Bool {
        // Native UI must not invoke either reader, even for anonymous groups.
        guard inWebArea, let rootNode = node(root), rootNode.anonymousContainer,
              let count = rootNode.childCount, count > 0 else { return false }
        var remaining = max(0, maximumDescendants)
        var ancestors: Set<ID> = [root]

        // true: a non-text destination survives; false: fully checked, none;
        // nil: unknown. In particular, budget exhaustion is not evidence that
        // an inner card survives, and must not authorize folding its parent.
        func destinationBelow(_ id: ID, _ current: Node) -> Bool? {
            guard let count = current.childCount, count >= 0 else { return nil }
            if count == 0 { return false }
            guard remaining > 0 else { return nil }
            let requested = min(count, remaining)
            let descendants = Array(children(id, requested).prefix(requested))
            // Reserve fetched siblings too: the bound covers child enumeration,
            // not just attribute reads along the first branch of a wide tree.
            remaining -= descendants.count
            for child in descendants {
                guard ancestors.insert(child).inserted else { return nil }
                guard let next = node(child) else { return nil }
                if next.role != "AXStaticText", next.informative, !next.anonymousContainer {
                    return true
                }
                let nested = destinationBelow(child, next)
                ancestors.remove(child)
                guard let nested else { return nil }
                if nested { return true }
                // An anonymous pressable card with only text/empty layout below
                // it stays listed. Its parent wrapper can fold into that card.
                if next.role != "AXStaticText", next.informative { return true }
            }
            return requested == count && descendants.count == count ? false : nil
        }
        return destinationBelow(root, rootNode) == true
    }
}
