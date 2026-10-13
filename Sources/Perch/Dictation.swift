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

    @ObservationIgnored private let engine = AVAudioEngine()
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

    private func begin(_ agentID: String) {
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition is not available right now"
            return
        }
        let ui = NotchUI.shared
        let existing = ui.drafts[agentID] ?? ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "Could not start the microphone"
            return
        }
        self.request = request
        activeAgentID = agentID
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.activeAgentID == agentID else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    ui.drafts[agentID] = existing.isEmpty ? spoken : "\(existing) \(spoken)"
                }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }
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
