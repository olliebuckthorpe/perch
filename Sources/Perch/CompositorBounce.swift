import AppKit
import SwiftUI
import QuartzCore

/// SwiftUI owns the face and its interactions; Core Animation owns the repeating movement.
/// Unlike a phase animator, this does not ask SwiftUI to update layout every display frame.
struct CompositorBounce<Content: View>: NSViewRepresentable {
    let content: Content
    let size: CGFloat
    let active: Bool
    let height: CGFloat
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> BounceHost<AnyView> {
        BounceHost(rootView: AnyView(content.environment(\.self, environment)))
    }

    func updateNSView(_ view: BounceHost<AnyView>, context: Context) {
        view.host.rootView = AnyView(content.environment(\.self, environment))
        view.configure(active: active, height: height)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BounceHost<AnyView>, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func dismantleNSView(_ view: BounceHost<AnyView>, coordinator: ()) {
        view.configure(active: false, height: 0)
    }
}

final class BounceHost<Content: View>: NSView {
    let host: FirstClickHostingView<Content>
    private var active = false
    private var height: CGFloat = 0
    static var animationKey: String { "perch.attention-bounce" }

    init(rootView: Content) {
        host = FirstClickHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    func configure(active: Bool, height: CGFloat) {
        guard self.active != active || self.height != height else { return }
        self.active = active
        self.height = height
        host.layer?.removeAnimation(forKey: Self.animationKey)
        updateAnimation()
    }

    private func updateAnimation() {
        guard active, window != nil else {
            host.layer?.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard host.layer?.animation(forKey: Self.animationKey) == nil else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, -height, 0, 0]
        bounce.keyTimes = [0, NSNumber(value: 0.2 / 0.92), NSNumber(value: 0.44 / 0.92), 1]
        bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                  CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear)]
        bounce.duration = 0.92
        bounce.repeatCount = .infinity
        host.layer?.add(bounce, forKey: Self.animationKey)
    }
}
