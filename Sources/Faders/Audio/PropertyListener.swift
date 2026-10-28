import CoreAudio
import Foundation

/// Runs a closure on the main thread whenever a Core Audio property changes.
///
/// This is how the mixer hears about volume keys, mute, a new output device or an
/// app starting to play — the moment it happens, without polling.
///
/// The listener is removed when this object is released (or `cancel()` is
/// called), so keeping it in a property ties it to its owner's lifetime.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.object = object
        address = AudioObjectPropertyAddress(selector, scope)

        // Core Audio calls this on the queue we pass (main), so it's safe to touch the UI.
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            self.block = block
        }
    }

    deinit { cancel() }

    func cancel() {
        // Removing needs the very same block object that was added.
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        self.block = nil
    }
}
