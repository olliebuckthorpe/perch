import Foundation
func check(_ value: Bool, _ label: String) { precondition(value, label); print("PASS: \(label)") }
let columns = ["a": CGRect(x: 0, y: 0, width: 200, height: 400), "b": CGRect(x: 208, y: 0, width: 200, height: 400), "folded": CGRect(x: 416, y: 0, width: 40, height: 400)]
let frames = ["one": CGRect(x: 8, y: 30, width: 184, height: 60), "two": CGRect(x: 8, y: 95, width: 184, height: 80), "three": CGRect(x: 8, y: 180, width: 184, height: 40), "b1": CGRect(x: 216, y: 30, width: 184, height: 70), "hidden": CGRect(x: 424, y: 10, width: 20, height: 20)]
let ids = ["a": ["one", "two", "three"], "b": ["b1"], "folded": ["hidden"]]
func target(_ x: CGFloat, _ y: CGFloat) -> (column: String, index: Int)? { BoardDropGeometry.target(at: CGPoint(x: x, y: y), columns: columns, frames: frames, orderedIDs: ids, dragging: "one") }
check(target(50,100)?.index == 0, "Reordering excludes the lifted card without collapsing its source frame")
check(target(50,160)?.index == 1, "Insertion follows the unchanged card midpoints")
check(target(250,20)?.column == "b" && target(250,20)?.index == 0, "A card can move to the start of another column")
check(target(250,300)?.index == 1, "A card can move to the end of another column")
check(target(430,5)?.index == 1, "A folded column appends even if old hidden frames remain")
check(target(500,100) == nil && target(50,450) == nil, "Releasing outside the board cancels the drop")
let fixed = target(50,160)
check((0..<100).allSatisfy { _ in target(50,160)?.index == fixed?.index }, "A stationary pointer cannot oscillate between insertion slots")
let today = Date(), tomorrow = Date().addingTimeInterval(86400)
check(TaskOrdering.arrange(["later","soon"], manual: ["later","soon"], due: ["soon": today, "later": tomorrow]) == ["soon","later"], "A nearer due date rises above a card dragged higher")
check(TaskOrdering.arrange(["a","b","undated"], manual: ["b","a"], due: ["a": today, "b": today]) == ["b","a","undated"], "Cards due the same day keep the dragged order; undated go last")
check(TaskOrdering.arrange(["x","y","z"], manual: ["z","z","missing"], due: [:]) == ["z","x","y"], "Undated cards follow the dragged order, then the board's; stale entries lose nothing")
