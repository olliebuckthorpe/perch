import AVFoundation
import Observation
import Speech

/// Speak a reply instead of typing it. Uses Apple's speech recognition, on device where
/// the Mac supports it, and writes straight into the reply draft as you talk.
@Observable
final class Dictation {
    static let shared = Dictation()

    private(set) var activeAgentID: String?
    var problem: String?

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func toggle(for agentID: String) {
        if activeAgentID != nil {
            stop()
            return
        }
        problem = nil
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.problem = "Allow Speech Recognition for Perch in System Settings"
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.problem = "Allow the microphone for Perch in System Settings"
                            return
                        }
                        self.begin(agentID)
                    }
                }
            }
        }
    }

    /// What has been said so far in earlier stretches of speech, and the stretch in progress.
    @ObservationIgnored private var committed = ""
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var existing = ""
    @ObservationIgnored private var failures = 0

    private func begin(_ agentID: String) {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition is not available right now"
            return
        }
        existing = NotchUI.shared.drafts[agentID] ?? ""
        committed = ""
        current = ""

        // After the sound device changes (headphones connecting, say) the old engine can report
        // a microphone with no format, and starting it then would bring Perch down. A fresh
        // engine picks up the current device; if there is still no microphone, say so instead.
        var format = engine.inputNode.outputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            engine.stop()
            engine = AVAudioEngine()
            format = engine.inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone is available right now"
            return
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // The microphone feeds whichever request is current, so listening carries on across pauses.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "Could not start the microphone"
            return
        }
        activeAgentID = agentID
        listen(recognizer, for: agentID)
    }

    /// One stretch of speech. The recogniser wraps a stretch up when the speaker pauses, and
    /// starts its text again from nothing. Each finished stretch is therefore kept, and a new
    /// one is started, so a pause never loses what came before it. It only stops when the
    /// microphone button is pressed again.
    private func listen(_ recognizer: SFSpeechRecognizer, for agentID: String) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let began = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.activeAgentID == agentID, self.request === request else { return }
                if let result {
                    self.failures = 0
                    let spoken = result.bestTranscription.formattedString
                    // Some versions restart the text mid-request after a pause: much shorter,
                    // and not a continuation of what was there. Keep the earlier part.
                    if self.current.count > 12, spoken.count < self.current.count / 2,
                       !self.current.hasPrefix(String(spoken.prefix(8))) {
                        self.committed = self.join(self.committed, self.current)
                    }
                    self.current = spoken
                    self.write(agentID)
                }
                if error != nil || result?.isFinal == true {
                    self.committed = self.join(self.committed, self.current)
                    self.current = ""
                    self.write(agentID)
                    self.task = nil
                    // A long silence can end a stretch with an error; that is not a reason to stop
                    // listening. Only many failures in a row with nothing heard means give up.
                    if error != nil, Date().timeIntervalSince(began) < 1 {
                        self.failures += 1
                        if self.failures > 8 {
                            self.problem = "Dictation stopped. Press the microphone to try again."
                            self.stop()
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                            guard let self, self.activeAgentID == agentID else { return }
                            self.listen(recognizer, for: agentID)
                        }
                        return
                    }
                    // Carry on listening for the next thing said.
                    self.listen(recognizer, for: agentID)
                }
            }
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : "\(a) \(b)"
    }

    private func write(_ agentID: String) {
        NotchUI.shared.drafts[agentID] = join(existing, join(committed, current))
    }

    func stop() {
        guard activeAgentID != nil else { return }
        activeAgentID = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}
