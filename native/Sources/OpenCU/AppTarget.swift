enum AppTarget {
    /// PID selectors accept positive decimal process IDs, never signs or overflow.
    static func processID(_ query: String) -> Int32? {
        guard query.hasPrefix("pid:") else { return nil }
        let digits = query.dropFirst(4)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }
}
