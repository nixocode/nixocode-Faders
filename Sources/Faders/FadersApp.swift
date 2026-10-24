import SwiftUI

/// App entry point.
///
/// Faders lives only in the menu bar (no Dock icon — see `LSUIElement` in
/// Info.plist). Clicking the icon opens the mixer panel.
@main
struct FadersApp: App {
    @State private var mixer = MixerModel()

    var body: some Scene {
        MenuBarExtra("Faders", systemImage: "slider.vertical.3") {
            MixerView()
                .environment(mixer)
        }
        // `.window` gives us a real panel (like Control Center modules)
        // instead of a plain dropdown menu.
        .menuBarExtraStyle(.window)
        // Let the panel grow and shrink with its content.
        .windowResizability(.contentSize)
    }
}
