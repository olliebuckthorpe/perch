import SwiftUI

enum Palette {
    static let colors: [Color] = [
        Color(red: 0.49, green: 0.77, blue: 1.00),  // sky
        Color(red: 1.00, green: 0.54, blue: 0.40),  // coral
        Color(red: 0.72, green: 0.61, blue: 1.00),  // violet
        Color(red: 0.37, green: 0.88, blue: 0.63),  // mint
        Color(red: 1.00, green: 0.82, blue: 0.40),  // sun
        Color(red: 1.00, green: 0.49, blue: 0.71),  // pink
        Color(red: 0.43, green: 0.91, blue: 0.98),  // aqua
        Color(red: 0.77, green: 0.91, blue: 0.42),  // lime
        Color(red: 1.00, green: 0.66, blue: 0.30),  // orange
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }

    /// Grok Bot's avatar palette, in the app's own order.
    static let grokIDs = ["brown", "red", "orange", "yellow", "green", "cyan", "blue", "violet", "magenta", "gray"]
    static let grok: [String: Color] = [
        // Black would vanish against the island, so it is drawn as charcoal with light features.
        "black": Color(white: 0.24),
        "brown": Color(red: 0.58, green: 0.39, blue: 0.22),
        "red": Color(red: 1.00, green: 0.15, blue: 0.24),
        "orange": Color(red: 1.00, green: 0.40, blue: 0.00),
        "yellow": Color(red: 1.00, green: 0.60, blue: 0.00),
        "green": Color(red: 0.00, green: 0.79, blue: 0.45),
        "cyan": Color(red: 0.00, green: 0.74, blue: 0.65),
        "blue": Color(red: 0.06, green: 0.52, blue: 1.00),
        "violet": Color(red: 0.57, green: 0.35, blue: 1.00),
        "magenta": Color(red: 1.00, green: 0.19, blue: 0.61),
        "gray": Color(white: 0.47),
    ]

    /// The colour Grok Bot gives an agent that has none set: the app's own hash of the agent id.
    static func grokDefault(for id: String) -> String {
        var t: UInt32 = 2_166_136_261
        for unit in id.utf16 { t = (t ^ UInt32(unit)) &* 16_777_619 }
        t = t &+ 0x6D2B_79F5
        var n = (t ^ (t >> 15)) &* (1 | t)
        n = (n &+ ((n ^ (n >> 7)) &* (61 | n))) ^ n
        let unit = Double(n ^ (n >> 14)) / 4_294_967_296
        return grokIDs[Int(unit * Double(grokIDs.count))]
    }

    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let green = Color(red: 0.3, green: 0.85, blue: 0.5)
    static let blue = Color(red: 0.4, green: 0.7, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.33, blue: 0.33)
}

extension Agent {
    var color: Color { avatarColor.flatMap { Palette.grok[$0] } ?? Palette.color(colorIndex) }
}

/// A hand-drawn-looking burst of rays, in the spirit of Claude's spark.
struct Spark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let rays = 11
        // Rays of slightly different lengths, so it looks drawn, not stamped.
        let lengths: [CGFloat] = [1.0, 0.86, 0.97, 0.9, 1.0, 0.84, 0.95, 0.9, 1.0, 0.88, 0.94]
        let half = Double.pi / Double(rays) * 0.42
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
            let tip = radius * lengths[i]
            let base = radius * 0.2
            p.move(to: CGPoint(x: c.x + base * cos(a - 1.1), y: c.y + base * sin(a - 1.1)))
            p.addLine(to: CGPoint(x: c.x + tip * cos(a - half * 0.55), y: c.y + tip * sin(a - half * 0.55)))
            p.addLine(to: CGPoint(x: c.x + tip * cos(a + half * 0.55), y: c.y + tip * sin(a + half * 0.55)))
            p.addLine(to: CGPoint(x: c.x + base * cos(a + 1.1), y: c.y + base * sin(a + 1.1)))
            p.closeSubpath()
        }
        p.addEllipse(in: CGRect(x: c.x - radius * 0.24, y: c.y - radius * 0.24, width: radius * 0.48, height: radius * 0.48))
        return p
    }
}

/// A scalloped circle. Claude Code sessions wear this one.
struct Burst: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0...96 {
            let t = Double(i) / 96 * 2 * .pi
            let r = radius * (0.87 + 0.13 * cos(8 * t))
            let pt = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// One little character per agent. The body shape says what kind of agent it is,
/// the colour says which one, and the expression says what it is up to.
struct FaceView: View {
    let agent: Agent
    let size: CGFloat

    private var ink: Color { agent.avatarColor == "black" ? .white.opacity(0.9) : .black.opacity(0.82) }

    var body: some View {
        let quiet = agent.status == .idle
        ZStack {
            if agent.source == .grok {
                grokBody
            } else if agent.source == .claude {
                // Every Claude chat wears the same orange spark, so it reads as Claude at a glance.
                Spark().fill(Palette.claude)
            } else {
                bodyShape.fill(agent.color)
                VStack(spacing: size * 0.07) {
                    eyes
                    if size >= 24 { mouth }
                }
                .offset(y: size >= 24 ? size * 0.02 : 0)
            }
        }
        .frame(width: size, height: size)
        .saturation(quiet ? 0.75 : 1)
        .opacity(quiet ? 0.8 : 1)
        .modifier(Bounce(active: agent.status == .needsYou))
        .overlay(alignment: .topTrailing) { badge.offset(x: size * 0.16, y: -size * 0.12) }
    }

    /// Grok Bot's own look: a round blob with two tilted highlight eyes, top right.
    @ViewBuilder private var grokBody: some View {
        let black = agent.avatarColor == "black"
        Circle().fill(black ? Color.black : agent.color)
            // A black blob needs an edge to show up against the island.
            .overlay(Circle().strokeBorder(.white.opacity(black ? 0.9 : 0), lineWidth: max(1.2, size * 0.07)))
        if agent.status == .working {
            TimelineView(.periodic(from: .now, by: 1.1)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 1.1) % 4
                grokEyes.offset(x: [-1.0, 0, 1.0, 0][step] * size * 0.05)
                    .animation(.easeInOut(duration: 0.3), value: step)
            }
        } else {
            grokEyes
        }
    }

    private var grokEyes: some View {
        ZStack {
            Capsule().fill(.white).frame(width: size * 0.10, height: size * 0.24)
                .rotationEffect(.degrees(-24)).offset(x: size * 0.05, y: -size * 0.16)
            Capsule().fill(.white).frame(width: size * 0.09, height: size * 0.17)
                .rotationEffect(.degrees(-24)).offset(x: size * 0.25, y: -size * 0.22)
        }
    }

    private var bodyShape: AnyShape {
        switch agent.source {
        case .grok: return AnyShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
        case .claude: return AnyShape(Burst())
        case .codex: return AnyShape(Circle())
        }
    }

    @ViewBuilder private var eyes: some View {
        let w = size * 0.13
        HStack(spacing: size * 0.17) {
            switch agent.status {
            case .idle:
                ForEach(0..<2, id: \.self) { _ in
                    Capsule().fill(ink).frame(width: w * 1.7, height: max(1.5, size * 0.07))
                }
            case .done:
                ForEach(0..<2, id: \.self) { _ in
                    Circle().trim(from: 0.5, to: 1).stroke(ink, style: .init(lineWidth: max(1.5, size * 0.08), lineCap: .round))
                        .frame(width: w * 1.8, height: w * 1.8)
                        .offset(y: w * 0.4)
                }
            case .needsYou:
                ForEach(0..<2, id: \.self) { _ in Circle().fill(ink).frame(width: size * 0.2, height: size * 0.2) }
            case .working:
                TimelineView(.periodic(from: .now, by: 1.1)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / 1.1) % 4
                    let dx = [-1.0, 0, 1.0, 0][step] * size * 0.05
                    HStack(spacing: size * 0.17) {
                        ForEach(0..<2, id: \.self) { _ in Capsule().fill(ink).frame(width: w, height: size * 0.24) }
                    }
                    .offset(x: dx)
                    .animation(.easeInOut(duration: 0.3), value: step)
                }
            case .unread:
                ForEach(0..<2, id: \.self) { _ in Capsule().fill(ink).frame(width: w, height: size * 0.24) }
            }
        }
        .frame(height: size * 0.26)
    }

    @ViewBuilder private var mouth: some View {
        switch agent.status {
        case .done, .unread:
            Circle().trim(from: 0, to: 0.5).stroke(ink, style: .init(lineWidth: size * 0.06, lineCap: .round))
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(y: -size * 0.08)
                .frame(height: size * 0.1)
        case .needsYou:
            Circle().fill(ink).frame(width: size * 0.12, height: size * 0.12)
        default:
            Capsule().fill(ink).frame(width: size * 0.16, height: max(1.5, size * 0.05))
        }
    }

    @ViewBuilder private var badge: some View {
        let d = max(6, size * 0.34)
        switch agent.status {
        case .needsYou:
            Circle().fill(Palette.amber).frame(width: d, height: d)
                .overlay(Circle().stroke(.black, lineWidth: 1.5))
        case .unread:
            if size >= 24 {
                Text("\(agent.unread)")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, size * 0.12)
                    .frame(minWidth: size * 0.46, minHeight: size * 0.46)
                    .background(Palette.red, in: Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 1.5))
            } else {
                Circle().fill(Palette.red).frame(width: d, height: d).overlay(Circle().stroke(.black, lineWidth: 1.5))
            }
        case .done:
            if agent.source != .grok {
                Circle().fill(Palette.green).frame(width: d, height: d).overlay(Circle().stroke(.black, lineWidth: 1.5))
            }
        default:
            EmptyView()
        }
    }
}

private struct Bounce: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([0.0, -2.5]) { view, y in
                view.offset(y: y)
            } animation: { _ in .easeInOut(duration: 0.42) }
        } else {
            content
        }
    }
}
