import AppKit
import SwiftUI

extension View {
    /// Lets a two-finger swipe on the trackpad (or a mouse wheel) over this view
    /// change `value`, a level from 0 to 1.
    ///
    /// It goes the way pages scroll on this Mac. With natural scrolling on (the
    /// default; System Settings → Trackpad → Scroll & Zoom) the level follows
    /// your fingers: right or up is louder. With it off, it goes the other way.
    ///
    /// - Parameters:
    ///   - isEnabled: False leaves swipes alone (a muted row's slider is disabled too).
    ///   - allowsVertical: Whether up/down swipes change the level as well as
    ///     left/right ones. Pass false inside a scroll view, so up/down swipes
    ///     still scroll it.
    ///   - onEditingChanged: Told when a swipe starts (true) and ends (false),
    ///     like a slider's drag.
    func scrollToAdjust(
        _ value: Binding<Float>,
        isEnabled: Bool = true,
        allowsVertical: Bool = true,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(ScrollToAdjust(
            value: value, isEnabled: isEnabled,
            allowsVertical: allowsVertical, onEditingChanged: onEditingChanged
        ))
    }
}

/// How far one scroll event moves a level. Kept apart so it can be tested.
enum ScrollStep {
    /// Trackpads report points. About 250 of them cover the whole range: a bit
    /// more than the slider is wide, so a slow swipe can land on any value.
    static let perPoint: Float = 1 / 250
    /// Mouse wheels report lines. One click is 5%, the same as an arrow key.
    static let perLine: Float = 0.05

    /// The change to the level for one scroll event, along the swipe's axis.
    ///
    /// macOS has already applied the scroll direction setting to these deltas:
    /// positive x moves content right and positive y moves it down. The level
    /// treats the slider's thumb like content, so right is louder and so is up.
    static func change(along axis: Axis, deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> Float {
        let delta = Float(axis == .horizontal ? deltaX : -deltaY)
        return delta * (isPrecise ? perPoint : perLine)
    }
}

private struct ScrollToAdjust: ViewModifier {
    @Binding var value: Float
    let isEnabled: Bool
    let allowsVertical: Bool
    let onEditingChanged: (Bool) -> Void

    /// True exactly while the panel is open: it's the key window then.
    @Environment(\.appearsActive) private var isOpen
    @State private var isHovering = false
    @State private var watcher = ScrollWatcher()

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            // Listen only while the pointer is over this view in the open panel.
            // Not onDisappear: `MenuBarExtra` keeps the view alive while the
            // panel is closed, so it wouldn't fire.
            .onChange(of: isHovering && isOpen && isEnabled, initial: true) { _, listen in
                guard listen else { return watcher.stop() }
                let value = $value
                watcher.start(allowsVertical: allowsVertical, onEditingChanged: onEditingChanged) { change in
                    value.wrappedValue = min(max(value.wrappedValue + change, 0), 1)
                }
            }
    }
}

/// Watches the app's scroll events while the pointer is over one row.
///
/// A local event monitor rather than a view: SwiftUI has no scroll-wheel
/// modifier on macOS 14, and an AppKit view behind the row would never see the
/// events, because the slider in front of it takes them first.
@MainActor
private final class ScrollWatcher {
    private var monitor: Any?
    /// The axis of the current swipe, chosen by its first movement and kept
    /// until the fingers lift, so a slightly diagonal swipe doesn't wobble.
    private var axis: Axis?
    private var isEditing = false
    private var onEditingChanged: (Bool) -> Void = { _ in }
    private var pendingEnd: Task<Void, Never>?

    func start(allowsVertical: Bool, onEditingChanged: @escaping (Bool) -> Void, adjust: @escaping (Float) -> Void) {
        stop()
        self.onEditingChanged = onEditingChanged
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            let used = MainActor.assumeIsolated {
                self?.use(event, allowsVertical: allowsVertical, adjust: adjust) ?? false
            }
            return used ? nil : event   // nil: nothing behind the row scrolls too
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        axis = nil
        finishEditing()
    }

    /// Returns whether the row used the event.
    private func use(_ event: NSEvent, allowsVertical: Bool, adjust: (Float) -> Void) -> Bool {
        let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
        let isWheelClick = event.phase.isEmpty && event.momentumPhase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || isWheelClick {
            axis = nil
        }
        if axis == nil, dx != 0 || dy != 0 {
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        // An up/down swipe the row doesn't take goes on to the list behind it.
        if axis == .vertical, !allowsVertical { return false }
        // The glide after the fingers lift is swallowed: the level stops where
        // the fingers stop, as it does when you let go of a slider.
        guard event.momentumPhase.isEmpty else { return true }

        if let axis, dx != 0 || dy != 0 {
            if !isEditing {
                isEditing = true
                onEditingChanged(true)
            }
            adjust(ScrollStep.change(along: axis, deltaX: dx, deltaY: dy, isPrecise: event.hasPreciseScrollingDeltas))
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishEditing()
        } else if event.phase.isEmpty {
            // A mouse wheel never says it's done: call it done after a pause.
            pendingEnd?.cancel()
            pendingEnd = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { self?.finishEditing() }
            }
        }
        return true
    }

    private func finishEditing() {
        pendingEnd?.cancel()
        pendingEnd = nil
        guard isEditing else { return }
        isEditing = false
        onEditingChanged(false)
    }
}
