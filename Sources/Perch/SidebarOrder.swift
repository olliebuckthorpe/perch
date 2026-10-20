/// Keeps a visible sidebar stable when background updates change activity ordering.
enum SidebarOrder {
    static func retaining(_ displayed: [String], candidates: [String], available: Set<String>) -> [String] {
        var seen = Set<String>()
        return (displayed + candidates).filter { available.contains($0) && seen.insert($0).inserted }
    }
}
