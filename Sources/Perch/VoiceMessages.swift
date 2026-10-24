import AVFoundation
import Observation
import SwiftUI

@Observable
final class VoicePlayback: NSObject, AVAudioPlayerDelegate {
    var playing = false
    var loading = false
    var problem: String?
    var duration: TimeInterval = 0
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ file: SlackFile) {
        if let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
            return
        }
        guard !loading, let url = file.url else { return }
        loading = true
        problem = nil
        SlackSource.shared.fetch(url, workspace: file.workspace) { [weak self] data in
            guard let self else { return }
            guard let data else { self.fail("Could not download. Tap to retry."); return }
            if let audio = try? AVAudioPlayer(data: data) { self.start(audio); return }
            // WhatsApp uses Ogg Opus, which AVAudioPlayer cannot decode on all Macs.
            guard let ffmpeg = Shell.find("ffmpeg") else {
                self.fail("Opus playback needs ffmpeg on this Mac."); return
            }
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let input = base.appendingPathExtension("ogg"), output = base.appendingPathExtension("wav")
            do { try data.write(to: input) } catch { self.fail("Could not prepare audio."); return }
            Shell.run(ffmpeg, ["-nostdin", "-v", "error", "-i", input.path, output.path]) { [weak self] code, _ in
                defer {
                    try? FileManager.default.removeItem(at: input)
                    try? FileManager.default.removeItem(at: output)
                }
                guard let self else { return }
                guard code == 0, let decoded = try? Data(contentsOf: output),
                      let audio = try? AVAudioPlayer(data: decoded) else {
                    self.fail("Could not play audio. Tap to retry."); return
                }
                self.start(audio)
            }
        }
    }

    private func start(_ audio: AVAudioPlayer) {
        player = audio
        audio.delegate = self
        duration = audio.duration
        loading = false
        playing = audio.play()
        if !playing { problem = "Could not play audio." }
    }
    private func fail(_ message: String) { loading = false; problem = message }
    func stop() { player?.stop(); player = nil; playing = false }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
        player.currentTime = 0
    }
}

struct VoiceMessageView: View {
    let file: SlackFile
    @State private var playback = VoicePlayback()
    var body: some View {
        HStack(spacing: 10) {
            Button { playback.toggle(file) } label: {
                if playback.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: playback.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 27)) }
            }
            .buttonStyle(.plain).disabled(playback.loading)
            VStack(alignment: .leading, spacing: 4) {
                Label("Voice message", systemImage: "waveform").font(.system(size: 12, weight: .medium))
                Text(playback.problem ?? (playback.duration > 0 ? String(format: "%d:%02d", Int(playback.duration) / 60, Int(playback.duration) % 60) : "Tap to play"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white).padding(10).frame(width: 250)
        .onDisappear { playback.stop() }
    }
}

@Observable
final class VoiceRecording {
    /// Any voice message being recorded right now, so the microphone in use is not taken for a call.
    static var active: Bool { live > 0 }
    @ObservationIgnored private static var live = 0
    var recording = false {
        didSet { if recording != oldValue { Self.live += recording ? 1 : -1 } }
    }
    var preparing = false
    var problem: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var pending = false

    func start() {
        guard !pending, !recording, !preparing else { return }
        pending = true
        problem = nil
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.pending else { return }
                self.pending = false
                guard granted else { self.problem = "Allow Perch’s microphone in System Settings."; return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voice-\(UUID().uuidString).m4a")
                do {
                    let audio = try AVAudioRecorder(url: url, settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                        AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ])
                    guard audio.record() else { self.problem = "Could not start recording."; return }
                    self.recorder = audio
                    self.recording = true
                } catch { self.problem = error.localizedDescription }
            }
        }
    }

    func finish(_ done: @escaping (URL) -> Void) {
        guard let recorder else { return }
        let input = recorder.url
        recorder.stop()
        self.recorder = nil
        recording = false
        guard let ffmpeg = Shell.find("ffmpeg") else { done(input); return }
        preparing = true
        let output = input.deletingPathExtension().appendingPathExtension("ogg")
        Shell.run(ffmpeg, ["-nostdin", "-v", "error", "-i", input.path, "-c:a", "libopus", "-b:a", "32k", output.path]) { [weak self] code, _ in
            self?.preparing = false
            if code == 0 {
                try? FileManager.default.removeItem(at: input)
                done(output)
            } else { done(input) }
        }
    }

    func cancel() {
        pending = false
        if let recorder { recorder.stop(); try? FileManager.default.removeItem(at: recorder.url) }
        recorder = nil
        recording = false
    }
}
