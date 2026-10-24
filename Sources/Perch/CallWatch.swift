import CoreAudio
import Foundation
import Observation

/// Knows when the user is on a call: some other app is using the microphone (Meet, Zoom, Slack
/// huddles and Teams all do while a call is live, screen sharing included). Perch stays quiet
/// then: no banners, no sounds, no opening by itself. Everything still lands in the sidebar.
///
/// It listens to Core Audio rather than polling: one callback when the default microphone
/// changes, and one when that microphone starts or stops being used anywhere.
@Observable
final class CallWatch {
    static let shared = CallWatch()

    /// The microphone is in use somewhere, and not by Perch itself.
    private(set) var onCall = false

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main) { [weak self] _, _ in
            self?.follow()
        }
        follow()
    }

    /// Watch whichever microphone is the default now.
    private func follow() {
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if device != kAudioObjectUnknown, let listener {
            AudioObjectRemovePropertyListenerBlock(device, &running, .main, listener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultInput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInput, 0, nil, &size, &id)
        device = id
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
        listener = block
        if id != kAudioObjectUnknown { AudioObjectAddPropertyListenerBlock(id, &running, .main, block) }
        check()
    }

    private func check() {
        var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard device != kAudioObjectUnknown,
              AudioObjectGetPropertyData(device, &running, 0, nil, &size, &value) == noErr else { return set(false) }
        // Perch's own dictation and voice notes use the microphone too; those are not calls.
        let perch = Dictation.shared.activeAgentID != nil || VoiceRecording.active
        set(value != 0 && !perch)
    }

    private func set(_ value: Bool) {
        if value != onCall { onCall = value }
    }
}
