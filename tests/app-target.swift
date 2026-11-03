@main struct AppTargetTests {
    static func main() {
        precondition(AppTarget.processID("pid:123") == 123)
        precondition(AppTarget.processID("pid:2147483647") == 2147483647)
        for query in ["pid:abc", "pid:12a", "pid:0", "pid:", "pid:-1", "pid:+1",
                      "pid: 123", "pid:123 ", "pid:１２３", "pid:2147483648", "Finder"] {
            precondition(AppTarget.processID(query) == nil, query)
        }
        print("App target checks passed (positive decimal PID, invalid input and overflow).")
    }
}
