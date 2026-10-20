import Foundation

/// Locks one trackpad gesture to the row where it started. Momentum cannot dismiss
/// a second row after the first disappears and the pointer is over its neighbour.
struct SidebarSwipe {
    private(set) var targetID: String?
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var horizontal: Bool?
    private var finished = true
    private(set) var consumesMomentum = false

    mutating func begin(over id: String?) {
        targetID = id
        x = 0; y = 0; horizontal = nil; finished = false
        consumesMomentum = false
    }

    @discardableResult mutating func update(dx: CGFloat, dy: CGFloat) -> Bool {
        guard targetID != nil, !finished else { return false }
        x += dx; y += dy
        if horizontal == nil, abs(x) + abs(y) > 10 {
            horizontal = x < 0 && abs(x) > abs(y) * 1.8
        }
        return horizontal == true
    }

    var offset: CGFloat {
        guard horizontal == true else { return 0 }
        let distance = max(0, -x)
        return -(min(distance, 90) + max(0, distance - 90) * 0.28)
    }
    var ready: Bool { horizontal == true && x <= -90 }

    mutating func end(cancelled: Bool) -> (id: String?, remove: Bool, consumed: Bool) {
        guard !finished else { return (nil, false, consumesMomentum) }
        let consumed = horizontal == true
        let result = (targetID, !cancelled && ready, consumed)
        consumesMomentum = consumed
        finished = true
        targetID = nil
        return result
    }

    /// Native deltas include the user's scrolling preference; the row follows fingers.
    static func fingerDelta(_ delta: CGFloat, inverted: Bool) -> CGFloat { inverted ? delta : -delta }
}
