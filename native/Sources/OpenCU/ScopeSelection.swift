/// One request keeps the original object across retries and polling, even after
/// the returned subtree has replaced the numbered element map.
struct ScopeSelection<Node: Hashable> {
    struct Selection {
        let root: Node?
        let identity: String
    }
    private var retained: (request: String, app: String, selection: Selection)?
    private var identities: [Node: String] = [:]
    private var serial = 0

    mutating func select(index: Int, request: String?, app: String, elements: [Int: Node]) -> Selection {
        if let request, let retained, retained.request == request, retained.app == app {
            return retained.selection
        }
        let root = elements[index]
        serial += 1
        let identity = root.flatMap { identities[$0] } ?? "root:\(serial)"
        if let root { identities[root] = identity }
        let selection = Selection(root: root, identity: identity)
        retained = request.map { ($0, app, selection) }
        return selection
    }

    mutating func clearRequest() { retained = nil }
}
