import AppKit
import CoreAudio
import IOBluetooth
import Observation

/// Moves the headphones to this Mac in one go: connects them over Bluetooth if they are not
/// already, then makes them the Mac's speaker and microphone so a call picks them up.
///
/// The Mac cannot tell the phone to let go. With the headphones' dual device mode on, they stay
/// connected to both and this simply switches the Mac's sound to them. Without it, connecting
/// works when the phone has released them (or the headphones agree to swap).
@Observable
final class Headphones {
    static let shared = Headphones()

    /// The paired headphones, by the name the Mac shows for them.
    var name = UserDefaults.standard.string(forKey: "headphonesName") ?? "1MORE HQ51"
    private(set) var connected = false
    private(set) var busy = false
    private(set) var note: String?

    private var device: IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { $0.name == name }
    }

    func refresh() { connected = device?.isConnected() ?? false }

    /// The Mac's built-in microphone is always the one used, for calls and for dictation. A
    /// Bluetooth headset's microphone is poor, does not work well with two devices connected, and
    /// using it drops the headphones' sound to phone-call quality. macOS switches to the headset's
    /// microphone whenever it connects, so Perch switches straight back.
    func keepMacMicrophone() {
        Self.useMacMicrophone()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            Self.useMacMicrophone()
        }
        // A newly connected device can also take over without the default changing first.
        address.mSelector = kAudioHardwarePropertyDevices
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.useMacMicrophone() }
        }
    }

    private static func useMacMicrophone() {
        guard let builtIn = devices().first(where: { transport($0) == kAudioDeviceTransportTypeBuiltIn
            && channels($0, scope: kAudioDevicePropertyScopeInput) > 0 }) else { return }
        if currentDefault(kAudioHardwarePropertyDefaultInputDevice) != builtIn {
            setDefault(kAudioHardwarePropertyDefaultInputDevice, builtIn)
        }
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func currentDefault(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        return value
    }

    /// Headphones button: bring them over, or if they are already here, hand them back.
    func toggle() {
        refresh()
        connected ? release() : bring()
    }

    func bring() {
        guard !busy else { return }
        guard let device else { return say("\(name) is not paired with this Mac") }
        busy = true
        say("Connecting…", keep: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = device.isConnected() ? kIOReturnSuccess : device.openConnection()
            // The Mac only offers them as a speaker a moment after the link comes up.
            var routed = false
            if result == kIOReturnSuccess {
                for _ in 0..<30 where !routed {
                    routed = Self.route(to: self.name)
                    if !routed { Thread.sleep(forTimeInterval: 0.25) }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if result != kIOReturnSuccess {
                    self.say("Could not connect. Let go of them on your phone, or turn on dual device mode.")
                } else if routed {
                    self.say("Using \(self.name)")
                } else {
                    self.say("Connected, but the Mac has not offered them as a speaker yet")
                }
            }
        }
    }

    /// Lets go of them on this Mac, so the phone can have them back.
    func release() {
        guard let device else { return }
        device.closeConnection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.refresh()
            self.say(self.connected ? "Still connected" : "Handed back")
        }
    }

    private func say(_ text: String, keep: Bool = false) {
        note = text
        // Used from a shortcut with nothing on screen, so the outcome is a sound: a soft tick when
        // it worked, the system's "no" when it did not.
        if !keep { NSSound(named: text.hasPrefix("Could not") || text.contains("not paired") ? "Basso" : "Tink")?.play() }
        guard !keep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if self.note == text { self.note = nil } }
    }

    // MARK: Sound routing

    /// Makes the named device the default speaker and microphone. True once both are set.
    private static func route(to name: String) -> Bool {
        let ids = devices()
        var output: AudioDeviceID?, input: AudioDeviceID?
        for id in ids where deviceName(id)?.localizedCaseInsensitiveContains(name) == true {
            if channels(id, scope: kAudioDevicePropertyScopeOutput) > 0 { output = id }
            if channels(id, scope: kAudioDevicePropertyScopeInput) > 0 { input = id }
        }
        _ = input
        guard let output else { return false }
        setDefault(kAudioHardwarePropertyDefaultOutputDevice, output)
        setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, output)
        // The microphone stays the Mac's own: see `keepMacMicrophone`.
        Self.useMacMicrophone()
        return true
    }

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }
}
