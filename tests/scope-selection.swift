@main struct ScopeSelectionTests {
    static func main() {
        var store = ScopeSelection<String>()
        let first = store.select(index: 9, request: "1", app: "a", elements: [9: "panel"])
        precondition(first.root == "panel")
        // A poll/retry must not resolve the old index in a newly numbered tree.
        let poll = store.select(index: 9, request: "1", app: "a", elements: [1: "panel", 9: "other"])
        precondition(poll.root == "panel" && poll.identity == first.identity)
        let again = store.select(index: 1, request: "2", app: "a", elements: [1: "panel"])
        precondition(again.identity == first.identity)
        let other = store.select(index: 9, request: "3", app: "a", elements: [9: "other"])
        precondition(other.root == "other" && other.identity != first.identity)
        let gone = store.select(index: 7, request: "4", app: "a", elements: [:])
        precondition(gone.root == nil)
        precondition(store.select(index: 7, request: "4", app: "a", elements: [7: "replacement"]).root == nil)
        precondition(store.select(index: 7, request: "4", app: "b", elements: [:]).identity != gone.identity)
        store.clearRequest()
        precondition(store.select(index: 7, request: "4", app: "a", elements: [7: "replacement"]).root == "replacement")
        precondition(store.select(index: 1, request: nil, app: "a", elements: [1: "panel"]).root == "panel")
        precondition(store.select(index: 1, request: nil, app: "a", elements: [1: "other"]).root == "other")
        print("Scope selection checks passed (retained objects, renumbering, retries, missing roots and stable identities).")
    }
}
