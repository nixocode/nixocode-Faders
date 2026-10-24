import CoreAudio

/// Small helpers that make Core Audio's C-style property API readable from Swift.
///
/// Core Audio describes everything (devices, processes, taps) as an `AudioObjectID`
/// with "properties" you read and write by selector. Without helpers, every read takes
/// five lines of pointer juggling; with them it's one call:
///
///     let name = deviceID.readString(kAudioObjectPropertyName)
extension AudioObjectID {

    /// The global "system" object — the root used to find devices and processes.
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Core Audio's sentinel for "no object".
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    // MARK: Reading

    /// Reads a single fixed-size value (an integer, a float, an object ID…).
    /// For text, use `readString` instead.
    func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(selector, scope)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    /// Reads a list of values, such as "every audio process on the system".
    func readArray<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope)

        // First ask how many bytes the list takes, then read that many.
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }

        var items = [T](repeating: defaultValue, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        return status == noErr ? items : []
    }

    /// Reads a text property (names, unique IDs, bundle identifiers).
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(selector, scope)
        // Core Audio hands back a CFString we own, so take it with `takeRetainedValue`.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr, let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    /// Returns true if this object has the given property at all
    /// (e.g. HDMI outputs often have no volume control).
    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(selector, scope)
        return AudioObjectHasProperty(self, &address)
    }

    // MARK: Writing

    /// Writes a single fixed-size value. Returns false if the device refused it.
    @discardableResult
    func write<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(selector, scope)
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeBytes(of: value) { buffer in
            AudioObjectSetPropertyData(self, &address, 0, nil, size, buffer.baseAddress!)
        }
        return status == noErr
    }
}

extension AudioObjectPropertyAddress {
    /// Shorthand: every property we use lives on the "main" element.
    init(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
