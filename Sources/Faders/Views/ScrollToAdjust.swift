import AppKit
import Combine
import SwiftUI

extension View {
    /// Lets a two-finger left/right swipe on the trackpad over this view change
    /// `value`, a level from 0 to 1. Up/down swipes are left alone, so a list
    /// of rows still scrolls the way every Mac list does.
    ///
    /// It goes the way pages scroll on this Mac. With natural scrolling on (the
    /// default; System Settings → Trackpad → Scroll & Zoom) the level follows
    /// your fingers: right is louder. With it off, it goes the other way.
    ///
    /// - Parameters:
    ///   - isEnabled: False leaves swipes alone (a muted row's slider is disabled too).
    ///   - onEditingChanged: Told when a swipe starts (true) and ends (false),
    ///     like a slider's drag.
    func scrollToAdjust(
        _ value: Binding<Float>,
        isEnabled: Bool = true,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(ScrollToAdjust(value: value, isEnabled: isEnabled, onEditingChanged: onEditingChanged))
    }
}

/// How far one scroll event moves a level. Kept apart so it can be tested.
enum ScrollStep {
    /// Trackpads report points. About 250 of them cover the whole range: a bit
    /// more than the slider is wide, so a slow swipe can land on any value.
    static let perPoint: Float = 1 / 250
    /// Mouse wheels report lines (a sideways wheel, or Shift + wheel). One
    /// click is 5%, the same as an arrow key.
    static let perLine: Float = 0.05

    /// The change to the level for one sideways scroll event.
    ///
    /// macOS has already applied the scroll direction setting to `deltaX`:
    /// positive moves content right. The level treats the slider's thumb like
    /// content, so right is louder.
    static func change(deltaX: CGFloat, isPrecise: Bool) -> Float {
        Float(deltaX) * (isPrecise ? perPoint : perLine)
    }
}

private struct ScrollToAdjust: ViewModifier {
    @Binding var value: Float
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void

    /// True exactly while the panel is open: it's the key window then.
    @Environment(\.appearsActive) private var isOpen
    // Not `@State`: in the macOS 27 SDK it's a macro whose plugin ships only
    // with Xcode, and Faders builds with just the Command Line Tools.
    @StateObject private var watcher = ScrollWatcher()

    func body(content: Content) -> some View {
        content
            .onHover { isOver in
                watcher.pointerIsOver = isOver
                update()
            }
            // Not onDisappear: `MenuBarExtra` keeps the view alive while the
            // panel is closed, so it wouldn't fire.
            .onChange(of: isOpen && isEnabled, initial: true) { _, allowed in
                watcher.isAllowed = allowed
                update()
            }
    }

    /// Listens only while the pointer is over this view in the open panel.
    private func update() {
        let value = $value
        watcher.update(onEditingChanged: onEditingChanged) { change in
            value.wrappedValue = min(max(value.wrappedValue + change, 0), 1)
        }
    }
}

/// Watches the app's scroll events while the pointer is over one row.
///
/// A local event monitor rather than a view: SwiftUI has no scroll-wheel
/// modifier on macOS 14, and an AppKit view behind the row would never see the
/// events, because the slider in front of it takes them first.
@MainActor
private final class ScrollWatcher: ObservableObject {
    var pointerIsOver = false
    var isAllowed = false

    private var monitor: Any?
    /// Whether the current swipe belongs to this row: it started here and went
    /// sideways. Decided by its first movement and kept until the fingers lift.
    private var swipe: Swipe = .none
    private enum Swipe { case none, undecided, sideways, notOurs }
    private var isEditing = false
    private var onEditingChanged: (Bool) -> Void = { _ in }
    private var adjust: (Float) -> Void = { _ in }
    private var pendingEnd: Task<Void, Never>?

    func update(onEditingChanged: @escaping (Bool) -> Void, adjust: @escaping (Float) -> Void) {
        guard pointerIsOver && isAllowed else { return stop() }
        self.onEditingChanged = onEditingChanged
        self.adjust = adjust
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            let used = MainActor.assumeIsolated { self?.use(event) ?? false }
            return used ? nil : event   // nil: nothing behind the row scrolls too
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        swipe = .none
        finishEditing()
    }

    /// Returns whether the row used the event.
    private func use(_ event: NSEvent) -> Bool {
        let (dx, dy) = (event.scrollingDeltaX, event.scrollingDeltaY)
        let isWheelClick = event.phase.isEmpty && event.momentumPhase.isEmpty

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || isWheelClick {
            swipe = .undecided
        } else if swipe == .none {
            // The pointer arrived here mid-swipe (scrolling the list moves rows
            // under it): that swipe isn't ours.
            swipe = .notOurs
        }
        if swipe == .undecided, dx != 0 || dy != 0 {
            swipe = abs(dx) > abs(dy) ? .sideways : .notOurs
        }

        // (The decision stands after the fingers lift, for the glide that follows.)
        guard swipe == .sideways else { return false }
        // The glide is swallowed: the level stops where the fingers stop, as it
        // does when you let go of a slider.
        guard event.momentumPhase.isEmpty else { return true }

        if dx != 0 {
            if !isEditing {
                isEditing = true
                onEditingChanged(true)
            }
            adjust(ScrollStep.change(deltaX: dx, isPrecise: event.hasPreciseScrollingDeltas))
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishEditing()
        } else if isWheelClick {
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
