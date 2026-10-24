import AudioToolbox
import CoreAudio

/// The speakers or headphones macOS is currently playing through
/// ("Output" in System Settings → Sound).
///
/// This powers the top "master" slider, the same one the volume keys move.
struct OutputDevice: Equatable {
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
}
