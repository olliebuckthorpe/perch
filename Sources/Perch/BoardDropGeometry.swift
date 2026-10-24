import Foundation
import CoreGraphics

/// Drop hit-testing uses the unchanged card layout, never a moving insertion gap.
enum BoardDropGeometry {
    static func target(at point: CGPoint, columns: [String: CGRect], frames: [String: CGRect],
                       orderedIDs: [String: [String]], dragging: String) -> (column: String, index: Int)? {
        let candidates = columns.sorted(by: { (lhs: (key: String, value: CGRect), rhs: (key: String, value: CGRect)) in lhs.value.minX < rhs.value.minX })
        guard let column = candidates.first(where: { $0.value.insetBy(dx: -3, dy: -8).contains(point) })?.key else { return nil }
        let ids = (orderedIDs[column] ?? []).filter { $0 != dragging }
        // Folded columns have no visible card frames: dropping there appends the card.
        if let frame = columns[column], frame.width <= 60 { return (column, ids.count) }
        let index = ids.firstIndex { id in frames[id].map { point.y < $0.midY } ?? false } ?? ids.count
        return (column, index)
    }
}

enum TaskOrdering {
    /// Due date first: overdue and soonest at the top, cards with no date after every dated one.
    /// Within the same day, and among undated cards, the order the user dragged them into wins,
    /// then the board's own order.
    static func arrange(_ ids: [String], manual: [String], due: [String: Date]) -> [String] {
        let ranks = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let calendar = Calendar.current
        func day(_ id: String) -> Date { due[id].map { calendar.startOfDay(for: $0) } ?? .distantFuture }
        return ids.enumerated().sorted {
            let (x, y) = (day($0.element), day($1.element))
            if x != y { return x < y }
            let (a, b) = (ranks[$0.element] ?? Int.max, ranks[$1.element] ?? Int.max)
            if a != b { return a < b }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}
