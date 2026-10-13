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

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let green = Color(red: 0.3, green: 0.85, blue: 0.5)
    static let blue = Color(red: 0.4, green: 0.7, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.33, blue: 0.33)
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

    private var ink: Color { .black.opacity(0.82) }

    var body: some View {
        let quiet = agent.status == .idle
        ZStack {
            bodyShape.fill(Palette.color(agent.colorIndex))
            VStack(spacing: size * 0.07) {
                eyes
                if size >= 24 { mouth }
            }
            .offset(y: size >= 24 ? size * 0.02 : 0)
        }
        .frame(width: size, height: size)
        .saturation(quiet ? 0.5 : 1)
        .opacity(quiet ? 0.7 : 1)
        .modifier(Bounce(active: agent.status == .needsYou))
        .overlay(alignment: .topTrailing) { badge.offset(x: size * 0.16, y: -size * 0.12) }
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
