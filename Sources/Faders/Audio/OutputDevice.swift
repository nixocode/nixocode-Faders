import AudioToolbox
import CoreAudio

/// The speakers or headphones macOS is currently playing through
/// ("Output" in System Settings → Sound).
///
/// This powers the top "master" slider, the same one the volume keys move, and
/// the menu that switches between outputs.
struct OutputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    /// Asks Core Audio for the current default output device.
    static func current() -> OutputDevice? {
        guard
            let id = AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioDeviceID.unknown
            ),
            id.isValid,
            let uid = id.readString(kAudioDevicePropertyDeviceUID)
        else { return nil }

        let name = id.readString(kAudioObjectPropertyName) ?? "Output"
        return OutputDevice(id: id, name: name, uid: uid)
    }

    /// Every device macOS can play through, as System Settings → Sound lists
    /// them: speakers, headphones, AirPods, displays, AirPlay…
    static func all() -> [OutputDevice] {
        AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, defaultValue: AudioDeviceID.unknown)
            .compactMap { id -> OutputDevice? in
                guard let uid = id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
                let outputStreams = id.readArray(
                    kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, defaultValue: AudioStreamID(0)
                ).count
                let isHidden = (id.read(kAudioDevicePropertyIsHidden, defaultValue: UInt32(0)) ?? 0) != 0
                guard isListed(uid: uid, isHidden: isHidden, outputStreams: outputStreams) else { return nil }
                return OutputDevice(id: id, name: id.readString(kAudioObjectPropertyName) ?? "Output", uid: uid)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether a device belongs in the output menu: it can play sound, macOS
    /// shows it, and it isn't one of Faders' own (see `AppVolumeTap`).
    static func isListed(uid: String, isHidden: Bool, outputStreams: Int) -> Bool {
        outputStreams > 0 && !isHidden && !uid.hasPrefix(AppVolumeTap.aggregateUIDPrefix)
    }

    /// Makes macOS play through this device, as choosing it in Control Center
    /// does. The mixer hears about it through its default-device listener.
    func makeDefault() {
        AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: id)
    }

    // MARK: Icon

    /// An SF Symbol that looks like the device: AirPods, headphones, a MacBook…
    var symbolName: String {
        let lowercasedName = name.lowercased()
        let transport = id.read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0)) ?? 0

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lowercasedName.contains("airpods max") { return "airpodsmax" }
            if lowercasedName.contains("airpods pro") { return "airpodspro" }
            if lowercasedName.contains("airpods") { return "airpods" }
            if lowercasedName.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            if lowercasedName.contains("headphone") { return "headphones" }
            return lowercasedName.contains("macbook") ? "laptopcomputer" : "desktopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "hifispeaker.fill"
        }
    }

    // MARK: Volume

    /// Some outputs (many HDMI/DisplayPort monitors) have no software volume.
    var supportsVolume: Bool {
        id.hasProperty(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    /// Volume from 0.0 (silent) to 1.0 (full).
    var volume: Float {
        get {
            id.read(
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput,
                defaultValue: Float32(0)
            ) ?? 0
        }
        nonmutating set {
            id.write(
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput,
                value: Float32(min(max(newValue, 0), 1))
            )
        }
    }

    // MARK: Mute

    var isMuted: Bool {
        get {
            (id.read(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, defaultValue: UInt32(0)) ?? 0) != 0
        }
        nonmutating set {
            id.write(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, value: UInt32(newValue ? 1 : 0))
        }
    }

    // MARK: Change notifications

    /// Listeners that fire when this device's volume or mute changes — from the
    /// volume keys, Control Center or another app. Updates stop when they're released.
    func observeLevels(_ onChange: @escaping @MainActor () -> Void) -> [PropertyListener] {
        [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map { selector in
            PropertyListener(id, selector, scope: kAudioDevicePropertyScopeOutput, onChange: onChange)
        }
    }
}
