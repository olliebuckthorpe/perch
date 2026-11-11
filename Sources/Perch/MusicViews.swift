import SwiftUI

/// The cover of what is playing, or a quiet note when there is none.
struct AlbumArt: View {
    let size: CGFloat
    var radius: CGFloat = 6
    private var music: NowPlaying { NowPlaying.shared }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image = music.artwork {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                shape.fill(.white.opacity(0.08))
                Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // Fades between covers when the track changes, rather than snapping.
        .animation(.easeOut(duration: 0.25), value: music.artwork)
    }
}

/// Bars that bounce while music plays and settle low when it stops. Not the real sound: a new
/// height for each bar a few times a second, eased between, in the cover's colour.
struct MusicBars: View {
    var count = 4
    var width: CGFloat = 3
    var spacing: CGFloat = 2
    var height: CGFloat = 14
    private var music: NowPlaying { NowPlaying.shared }
    private static let step = 0.24

    var body: some View {
        // Ticks only while playing, a handful of times a second, so a paused track costs nothing.
        TimelineView(.animation(minimumInterval: Self.step, paused: !music.playing)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.step)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { bar in
                    Capsule()
                        .fill(music.accent)
                        .frame(width: width, height: max(width, height * level(bar, tick)))
                }
            }
            .frame(height: height)
            .animation(.easeInOut(duration: Self.step), value: tick)
            .animation(.easeOut(duration: 0.3), value: music.playing)
        }
    }

    /// 0.2 to 1 for a playing bar, from a cheap hash so each bar moves on its own. Low when paused.
    private func level(_ bar: Int, _ tick: Int) -> CGFloat {
        guard music.playing else { return 0.2 }
        var x = UInt64(truncatingIfNeeded: tick &* 31 &+ bar &* 977)
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33
        // The middle bars run a little taller, as on a real meter.
        let lift: CGFloat = (bar == 0 || bar == count - 1) ? 0.75 : 1
        return (0.2 + CGFloat(x % 1000) / 1000 * 0.8) * lift
    }
}

/// The closed notch's far left while music plays: the cover, with the bars just inside it.
/// A click on either opens the Music tab.
struct MusicCoverEar: View {
    @Environment(NotchUI.self) private var ui
    static let width: CGFloat = 32

    var body: some View {
        AlbumArt(size: 20, radius: 5)
            .frame(width: Self.width)
            .contentShape(Rectangle())
            .onTapGesture { ui.showMusic() }
            .help(NowPlaying.shared.title ?? "Music")
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

/// The bars beside the cover in the closed notch.
struct MusicBarsEar: View {
    @Environment(NotchUI.self) private var ui
    static let width: CGFloat = 24

    var body: some View {
        MusicBars(count: 4, width: 3, spacing: 2, height: 14)
            .frame(width: Self.width)
            .contentShape(Rectangle())
            .onTapGesture { ui.showMusic() }
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

/// The Music tab: the cover large, what is playing, where it is up to, and the controls.
struct MusicView: View {
    private var music: NowPlaying { NowPlaying.shared }

    var body: some View {
        Group {
            if music.active {
                HStack(alignment: .center, spacing: 26) {
                    Button { music.openPlayer() } label: {
                        AlbumArt(size: 260, radius: 14)
                            .shadow(color: music.accent.opacity(0.28), radius: 24, y: 8)
                    }
                    .buttonStyle(Press(reach: 0))
                    .help("Open \(music.appName ?? "the player")")

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            MusicBars(count: 5, width: 3.5, spacing: 2.5, height: 16)
                            if let app = music.appName {
                                Text(app.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(1.4)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .padding(.bottom, 14)
                        Text(music.title ?? "").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(2)
                        Text([music.artist, music.album].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).padding(.top, 4)
                        MusicProgress().padding(.top, 26)
                        MusicControls().padding(.top, 18)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 22)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.3))
                    Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Text("Play something in Spotify, Music or a browser and it shows here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
    }
}

/// Elapsed and total time, with a bar that can be dragged to move through the track.
private struct MusicProgress: View {
    @State private var dragging: Double?
    @State private var hovered = false
    private var music: NowPlaying { NowPlaying.shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let total = music.duration ?? 0
            let at = dragging ?? music.elapsed(at: context.date)
            let part = total > 0 ? min(1, at / total) : 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let thick: CGFloat = hovered || dragging != nil ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(music.accent).frame(width: max(thick, geo.size.width * part))
                    }
                    .frame(height: thick)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard total > 0 else { return }
                            dragging = max(0, min(1, v.location.x / geo.size.width)) * total
                        }
                        .onEnded { _ in
                            if let dragging { music.seek(to: dragging) }
                            dragging = nil
                        })
                    .animation(.easeOut(duration: 0.12), value: thick)
                }
                .frame(height: 14)
                .onHover { hovered = $0 }
                .opacity(total > 0 ? 1 : 0.4)
                HStack {
                    Text(Self.clock(at)).monospacedDigit()
                    Spacer()
                    Text(total > 0 ? "-" + Self.clock(max(0, total - at)) : "Live").monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct MusicControls: View {
    private var music: NowPlaying { NowPlaying.shared }

    var body: some View {
        HStack(spacing: 18) {
            SkipButton(forward: false) { music.previous() }
            PlayButton()
            SkipButton(forward: true) { music.next() }
        }
    }
}

/// Previous and next. Hovered, a soft circle comes up behind; pressed, the button sinks; let go,
/// it springs back and the arrows dart the way it skips.
private struct SkipButton: View {
    let forward: Bool
    let action: () -> Void
    @State private var nudge: CGFloat = 0

    var body: some View {
        Button {
            action()
            // Out the way it skips, then back with a bounce.
            withAnimation(.easeOut(duration: 0.09)) { nudge = forward ? 7 : -7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { nudge = 0 }
            }
        } label: {
            Image(systemName: forward ? "forward.fill" : "backward.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .offset(x: nudge)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(MusicButtonStyle())
        .help(forward ? "Next" : "Previous")
    }
}

/// Play and pause: the white disc. Pressed, it sinks; let go, it springs back past its size, the
/// icon morphs between play and pause, and a ring ripples out in the cover's colour.
private struct PlayButton: View {
    @State private var ripples: [UUID] = []
    private var music: NowPlaying { NowPlaying.shared }

    var body: some View {
        Button {
            music.togglePlay()
            let id = UUID()
            ripples.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ripples.removeAll { $0 == id } }
        } label: {
            Image(systemName: music.playing ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.black)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 50, height: 50)
                .background(.white, in: Circle())
        }
        .buttonStyle(MusicButtonStyle(disc: true))
        .background {
            ZStack {
                ForEach(ripples, id: \.self) { _ in Ripple(color: music.accent) }
            }
        }
        .help(music.playing ? "Pause" : "Play")
    }
}

/// One ring growing out from the play button and fading as it goes.
private struct Ripple: View {
    let color: Color
    @State private var out = false

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: out ? 1 : 3)
            .frame(width: 50, height: 50)
            .scaleEffect(out ? 1.7 : 1)
            .opacity(out ? 0 : 0.85)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { out = true } }
            .allowsHitTesting(false)
    }
}

/// The controls' own press: hover lights a circle behind (or brightens the disc), a press sinks
/// the button well down, and letting go overshoots back with a spring.
private struct MusicButtonStyle: ButtonStyle {
    var disc = false

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, disc: disc)
    }

    private struct Look: View {
        let configuration: Configuration
        let disc: Bool
        @State private var hovered = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background {
                    if !disc {
                        Circle().fill(.white.opacity(pressed ? 0.2 : hovered ? 0.1 : 0))
                    }
                }
                .brightness(disc && hovered && !pressed ? -0.06 : 0)
                .scaleEffect(pressed ? 0.82 : hovered ? 1.06 : 1)
                .contentShape(Circle())
                .animation(pressed ? .easeOut(duration: 0.07) : .spring(response: 0.3, dampingFraction: 0.45), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}
