@main struct TreeFilterTests {
    static func node(role: String = "AXGroup", title: Bool = false, description: Bool = false,
                     identifier: Bool = false, placeholder: Bool = false, value: Bool = false,
                     kind: Bool = false, actions: [String] = ["AXPress"], children: Int? = 1) -> TreeFilter.Node {
        let labelled = title || description || identifier || placeholder || value || kind
        let informative = (!TreeFilter.containers.contains(role) && role != "AXStaticText")
            || labelled || actions.contains { !TreeFilter.passiveActions.contains($0) }
        return TreeFilter.Node(role: role, informative: informative,
            anonymousContainer: TreeFilter.anonymousContainer(role: role, hasTitle: title,
                hasDescription: description, hasIdentifier: identifier, hasPlaceholder: placeholder,
                hasValue: value, hasKind: kind, actions: actions), childCount: children)
    }

    static func main() {
        let link = node(role: "AXLink", title: true, children: 0)
        let text = node(role: "AXStaticText", value: true, actions: [], children: 0)
        func collapse(_ root: Int = 0, nodes: [Int: TreeFilter.Node], edges: [Int: [Int]],
                      budget: Int = TreeFilter.maximumProbeDescendants, web: Bool = true) -> Bool {
            var nodeReads = 0, childReads = 0, enumerated = 0
            let result = TreeFilter.collapseWebContainer(root: root, inWebArea: web, maximumDescendants: budget,
                node: { id in nodeReads += 1; return nodes[id] },
                children: { id, limit in
                    childReads += 1
                    precondition(limit > 0 && limit <= budget)
                    let values = Array((edges[id] ?? []).prefix(limit))
                    enumerated += values.count
                    return values
                })
            precondition(nodeReads <= max(0, budget) + 1, "root plus at most N descendants")
            precondition(enumerated <= max(0, budget), "child enumeration also stays within N")
            if !web { precondition(nodeReads == 0 && childReads == 0, "native UI must not probe") }
            return result
        }
        // Previous candidate-condition cases now include a real alternative.
        func withLink(_ root: TreeFilter.Node = node(), web: Bool = true) -> Bool {
            collapse(nodes: [0: root, 1: link], edges: [0: [1]], web: web)
        }
        precondition(withLink())
        precondition(withLink(node(actions: [])))
        precondition(withLink(node(actions: ["AXPress", "AXShowMenu", "AXScrollToVisible"])))
        precondition(withLink(node(actions: ["AXShowMenu"])))
        for role in ["AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem"] {
            precondition(withLink(node(role: role)))
        }
        precondition(!withLink(node(title: true)))
        precondition(!withLink(node(description: true)))
        precondition(!withLink(node(identifier: true)))
        precondition(!withLink(node(placeholder: true)))
        precondition(!withLink(node(value: true)))
        precondition(!withLink(node(kind: true)))
        precondition(!withLink(node(actions: ["AXPress", "AXIncrement"])))
        precondition(!withLink(node(actions: ["AXConfirm"])))
        precondition(!collapse(nodes: [0: node(children: 0)], edges: [:]))
        precondition(!withLink(web: false))
        precondition(!withLink(node(role: "AXButton")))

        let wrapperChain = [0: node(), 1: node(), 2: link]
        precondition(collapse(nodes: wrapperChain, edges: [0: [1], 1: [2]]), "outer wrapper above link")
        precondition(collapse(1, nodes: wrapperChain, edges: [0: [1], 1: [2]]), "inner wrapper above link")
        precondition(!collapse(nodes: [0: node(), 1: text], edges: [0: [1]]), "text-only card is its own handle")
        let wrappedCard = [0: node(), 1: node(), 2: text]
        precondition(collapse(nodes: wrappedCard, edges: [0: [1], 1: [2]]), "wrapper folds into retained card")
        precondition(!collapse(1, nodes: wrappedCard, edges: [0: [1], 1: [2]]), "retained card")
        precondition(!collapse(nodes: [0: node(), 1: node(actions: []), 2: text],
            edges: [0: [1], 1: [2]]), "ordinary anonymous layout is not a replacement handle")
        precondition(collapse(nodes: [0: node(), 1: node(kind: true, actions: [], children: 0)],
            edges: [0: [1]]), "article kind is a destination even without an action")
        precondition(!collapse(nodes: [0: node(), 1: node(role: "AXStaticText", value: true, children: 0)],
            edges: [0: [1]]), "even actionable static text is excluded")
        precondition(collapse(nodes: [0: node(), 1: node(children: 0)], edges: [0: [1]]), "pressable leaf survives")
        precondition(!collapse(nodes: [0: node(), 1: node(actions: [], children: 0)], edges: [0: [1]]))

        // Look through ordinary layout; only the innermost press handle survives.
        let mixed = [0: node(), 1: node(actions: []), 2: node(), 3: text]
        precondition(collapse(nodes: mixed, edges: [0: [1], 1: [2], 2: [3]]))
        precondition(!collapse(2, nodes: mixed, edges: [0: [1], 1: [2], 2: [3]]))
        precondition(!collapse(nodes: wrappedCard, edges: [0: [1], 1: [2]], budget: 1),
            "budget-kept inner card is unknown, not proof for its parent")
        precondition(collapse(nodes: wrappedCard, edges: [0: [1], 1: [2]], budget: 2))
        precondition(!collapse(nodes: wrapperChain, edges: [0: [1], 1: [2]], budget: 0))

        let limit = TreeFilter.maximumProbeDescendants
        precondition(limit == 200)
        var deep = [0: node()], deepEdges: [Int: [Int]] = [:]
        for i in 1...limit { deep[i] = node(); deepEdges[i - 1] = [i] }
        deep[limit + 1] = link; deepEdges[limit] = [limit + 1]
        precondition(!collapse(nodes: deep, edges: deepEdges), "deep probe stops at N descendants")
        var wide = [0: node(children: limit + 1)]
        for i in 1...limit { wide[i] = text }
        wide[limit + 1] = link
        precondition(!collapse(nodes: wide, edges: [0: Array(1...limit + 1)]), "wide probe stops at N descendants")
        wide[0] = node(children: limit); wide[limit] = link
        precondition(collapse(nodes: wide, edges: [0: Array(1...limit)]), "destination at exact budget boundary")
        precondition(!collapse(nodes: [0: node(children: 2), 1: node(children: 2), 2: text, 3: text, 4: link],
            edges: [0: [1, 2], 1: [3, 4]], budget: 3), "prefetched siblings consume the branching probe budget")

        precondition(!collapse(nodes: [0: node(), 1: node()], edges: [0: [1], 1: [0]]), "cycle keeps wrappers")
        precondition(!collapse(nodes: [0: node()], edges: [0: [1]]), "unreadable descendant keeps handle")
        precondition(!collapse(nodes: [0: node(children: nil)], edges: [:]), "unknown root children")
        precondition(!collapse(nodes: [0: node(), 1: node(children: nil)], edges: [0: [1]]), "unknown card children")
        precondition(!collapse(nodes: [0: node(children: 2), 1: text], edges: [0: [1]]), "partial child list keeps handle")
        print("Tree filter checks passed (recursive wrappers, retained cards, ordinary layout, native exclusion, 200-node budget and incomplete reads).")
    }
}
