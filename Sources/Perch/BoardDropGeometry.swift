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
    static func arrange(_ ids: [String], manual: [String], urgent: Set<String>) -> [String] {
        let ranks = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.enumerated().sorted {
            let a = ranks[$0.element], b = ranks[$1.element]
            if a != nil || b != nil {
                if a != b { return (a ?? Int.max) < (b ?? Int.max) }
            }
            let x = urgent.contains($0.element), y = urgent.contains($1.element)
            if x != y { return x }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}
