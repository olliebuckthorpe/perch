import SwiftUI

/// A Grok bot's face the way Grok Bot draws it: a ball with two eyes painted on its surface.
/// The ball turns in 3D, so the eyes squash and tilt as they near its edge, the far eye
/// narrows when it looks to the side, and a roll carries them over the top and round from
/// underneath. Drawn from keyframes taken from a recording of Grok Bot itself.
struct GrokBall: View {
    let size: CGFloat
    let color: Color
    let outlined: Bool
    let working: Bool
    @State private var hovered = false
    @State private var hoverAt = Date.distantPast
    private var clock: EyeClock { EyeClock.shared }

    var body: some View {
        // Only ticks while something is moving: a working bot, a glance, or easing to the pointer.
        let glancing = clock.calmPlaying
        let easing = Date().timeIntervalSince(hoverAt) < 0.35
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(working || glancing || easing))) { context in
            Canvas { g, canvas in
                draw(&g, canvas, pose(at: context.date))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { over in
            hovered = over
            hoverAt = Date()
        }
    }

    /// One frame, for checking the drawing against Grok Bot's.
    func still(_ p: BallPose) -> some View {
        Canvas { g, canvas in draw(&g, canvas, p) }.frame(width: size, height: size)
    }

    private func pose(at now: Date) -> BallPose {
        let base: BallPose
        if working {
            base = BallPose.at(now.timeIntervalSince(clock.epoch), in: BallPose.working, looping: true)
        } else if clock.calmPlaying {
            base = BallPose.at(now.timeIntervalSince(clock.calmAt), in: BallPose.glance, looping: false)
        } else {
            base = BallPose.rest
        }
        // Turning to the pointer, and back, eased rather than snapped.
        let k = min(1, now.timeIntervalSince(hoverAt) / 0.3)
        let eased = k * k * (3 - 2 * k)
        return hovered ? base.mixed(with: .facing, eased) : BallPose.facing.mixed(with: base, eased)
    }

    private func draw(_ g: inout GraphicsContext, _ canvas: CGSize, _ p: BallPose) {
        let radius = canvas.width / 2 * p.scale
        let center = CGPoint(x: canvas.width / 2 + p.dx * canvas.width, y: canvas.height / 2 + p.dy * canvas.height)
        let head = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        g.fill(head, with: .color(color))
        if outlined {
            g.stroke(head.strokedPath(.init(lineWidth: max(1.2, size * 0.07))).offsetBy(dx: 0, dy: 0), with: .color(.white.opacity(0.9)))
        }
        var inside = g
        inside.clip(to: head)
        for side in [-1.0, 1.0] {
            if let eye = eyePath(side: side, pose: p, center: center, radius: radius) {
                inside.fill(eye, with: .color(.white))
            }
        }
    }

    /// One eye: a rounded shape in the ball's surface, turned with the ball and projected flat.
    private func eyePath(side: Double, pose p: BallPose, center: CGPoint, radius: CGFloat) -> Path? {
        let lon = side * p.gap / 2
        // Where the eye sits and the two directions along the surface there.
        let m = SIMD3(sin(lon), 0, cos(lon))
        let east = SIMD3(cos(lon), 0, -sin(lon))
        let north = SIMD3<Double>(0, 1, 0)
        let blinkH = p.h * p.open
        var points: [CGPoint] = []
        var visible = false
        let steps = 32
        for i in 0..<steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            // A superellipse: round at 2, pill-like as it grows.
            let n = 2 + (1 - p.round) * 0.9
            let c = cos(t), s = sin(t)
            let a = p.w / 2 * copysign(pow(abs(c), 2 / n), c)
            let b = blinkH / 2 * copysign(pow(abs(s), 2 / n), s)
            var q = m + east * a + north * b
            q /= (q * q).sum().squareRoot()
            q = rotate(q, p)
            if q.z > 0 { visible = true }
            // Behind the ball: held on its rim, where the clip hides it.
            if q.z < 0 {
                let r = (q.x * q.x + q.y * q.y).squareRoot()
                if r > 0 { q.x /= r; q.y /= r }
            }
            let roll = p.roll * .pi / 180
            let x = q.x * cos(roll) - q.y * sin(roll), y = q.x * sin(roll) + q.y * cos(roll)
            points.append(CGPoint(x: center.x + x * radius, y: center.y - y * radius))
        }
        guard visible, blinkH > 0.004 else { return nil }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// Turns a point on the ball: yaw (positive looks right), then pitch (positive looks up).
    private func rotate(_ v: SIMD3<Double>, _ p: BallPose) -> SIMD3<Double> {
        let yaw = p.yaw * .pi / 180, pitch = p.pitch * .pi / 180
        let x1 = v.x * cos(yaw) + v.z * sin(yaw)
        let z1 = -v.x * sin(yaw) + v.z * cos(yaw)
        let y2 = v.y * cos(pitch) + z1 * sin(pitch)
        let z2 = -v.y * sin(pitch) + z1 * cos(pitch)
        return SIMD3(x1, y2, z2)
    }
}

/// How the ball is turned and how its eyes look at one moment. Angles in degrees, eye sizes in
/// radians of the ball's surface, head offsets as fractions of the face.
struct BallPose {
    var yaw: Double
    var pitch: Double
    var w: Double
    var h: Double
    var gap: Double = 0.56
    /// 0 for tall pills, 1 for plain ovals.
    var round: Double = 0
    var open: Double = 1
    var roll: Double = 0
    var dx: Double = 0
    var dy: Double = 0
    var scale: Double = 1

    static let pills = (w: 0.32, h: 0.64)

    static let rest = BallPose(yaw: 26, pitch: 30, w: pills.w, h: pills.h, roll: 18)
    static let facing = BallPose(yaw: 0, pitch: 3, w: pills.w, h: pills.h)

    func mixed(with o: BallPose, _ k: Double) -> BallPose {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
        return BallPose(yaw: m(yaw, o.yaw), pitch: m(pitch, o.pitch), w: m(w, o.w), h: m(h, o.h), gap: m(gap, o.gap),
                        round: m(round, o.round), open: m(open, o.open), roll: m(roll, o.roll),
                        dx: m(dx, o.dx), dy: m(dy, o.dy), scale: m(scale, o.scale))
    }

    /// The pose a moment into a run of keyframes, eased between them.
    static func at(_ t: Double, in frames: [(Double, BallPose)], looping: Bool) -> BallPose {
        guard let last = frames.last else { return rest }
        var time = t
        if looping { time = t.truncatingRemainder(dividingBy: last.0) }
        if time <= frames[0].0 { return frames[0].1 }
        if time >= last.0 { return last.1 }
        for i in 1..<frames.count where time <= frames[i].0 {
            let (t0, a) = frames[i - 1], (t1, b) = frames[i]
            let k = (time - t0) / max(0.0001, t1 - t0)
            return a.mixed(with: b, k * k * (3 - 2 * k))
        }
        return last.1
    }

    // MARK: Keyframes, read off a recording of Remmi in Grok Bot

    private static func pill(_ yaw: Double, _ pitch: Double, open: Double = 1, roll: Double = 0, dx: Double = 0, dy: Double = 0, scale: Double = 1) -> BallPose {
        BallPose(yaw: yaw, pitch: pitch, w: pills.w, h: pills.h, open: open, roll: roll, dx: dx, dy: dy, scale: scale)
    }
    private static func oval(_ yaw: Double, _ pitch: Double, dx: Double = 0, dy: Double = 0) -> BallPose {
        BallPose(yaw: yaw, pitch: pitch, w: 0.46, h: 0.31, gap: 0.62, round: 1, dx: dx, dy: dy)
    }
    private static func dots(_ yaw: Double, _ pitch: Double, small: Bool = false) -> BallPose {
        BallPose(yaw: yaw, pitch: pitch, w: small ? 0.18 : 0.25, h: small ? 0.36 : 0.25, gap: 0.5, round: small ? 0 : 1)
    }

    /// While working: look up and to the side, blink, turn to face out, roll over the top and
    /// back round, focus down to dots, then wander about with wide eyes. About 14 seconds.
    static let working: [(Double, BallPose)] = [
        (0.0, pill(-30, 32, roll: -22)),
        (1.2, pill(-30, 32, roll: -22)),
        (1.35, pill(-30, 32, open: 0.08, roll: -22)),
        (1.55, pill(-30, 32, roll: -22)),
        (2.9, pill(-12, 18, roll: -10, dx: -0.03)),
        (3.8, pill(0, 4)),
        (4.8, pill(0, -20, dy: -0.04)),
        (5.25, pill(0, 70, dy: -0.07, scale: 0.95)),
        (5.6, pill(0, 200, dy: -0.08, scale: 0.94)),
        (5.95, pill(0, 340, dy: -0.02)),
        (6.4, pill(0, 360, dy: 0.01)),
        (7.8, pill(0, 360)),
        (8.4, dots(0, 360, small: true)),
        (9.0, dots(0, 360)),
        (10.2, dots(18, 360)),
        (11.1, oval(32, 392, dx: 0.02)),
        (12.1, oval(-26, 335, dx: -0.02, dy: 0.02)),
        (12.9, oval(-18, 380)),
        (13.6, pill(-30, 392, roll: -22)),
        (14.2, pill(-30, 392, roll: -22)),
    ]

    /// Now and then while idle: glance across, lean in, blink, look about with wide eyes, face
    /// out for a moment and settle back. About 6 seconds.
    static let glance: [(Double, BallPose)] = [
        (0.0, rest),
        (0.5, pill(-30, 2)),
        (1.4, pill(-30, 2)),
        (1.8, BallPose(yaw: 15, pitch: 22, w: 0.33, h: 0.72)),
        (2.1, BallPose(yaw: 15, pitch: 22, w: 0.33, h: 0.72)),
        (2.25, BallPose(yaw: 15, pitch: 22, w: 0.33, h: 0.72, open: 0.08)),
        (2.4, BallPose(yaw: 15, pitch: 22, w: 0.33, h: 0.72)),
        (2.8, oval(-28, 5)),
        (3.4, oval(-22, -28)),
        (3.9, oval(-22, -28)),
        (4.3, facing),
        (5.3, facing),
        (5.9, rest),
    ]
}
