import AppKit

/// Follows the shift/option/control keys while they should pick a portal set:
/// while the portal window is key (local `flagsChanged` monitor), while the hotkey
/// chord that just opened the window is still held, and while a file drag hovers the
/// portal (both polled, since the app is not active then). Reports the held set
/// modifiers through `onChange`; an empty set means "back to the base set".
final class ModifierSetTracker {
    var onChange: (Set<PortalSetModifier>) -> Void = { _ in }

    private var windowKey = false
    private var dragHover = false
    /// Modifiers of the hotkey chord, ignored until the chord is let go.
    private var chordMask: Set<PortalSetModifier> = []
    private var monitor: Any?
    private var timer: Timer?
    private var releaseWork: DispatchWorkItem?

    /// Delay before falling back to the base set once tracking stops, so a drop that
    /// ends a drag hover still lands on the set it was aimed at.
    static let releaseDelay: TimeInterval = 0.2

    static func modifiers(in flags: NSEvent.ModifierFlags) -> Set<PortalSetModifier> {
        var held = Set<PortalSetModifier>()
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        return held
    }

    /// The set modifiers that count, and the chord mask to keep: the mask stays until
    /// none of its modifiers is held any more.
    static func resolve(flags: NSEvent.ModifierFlags, mask: Set<PortalSetModifier>)
        -> (held: Set<PortalSetModifier>, mask: Set<PortalSetModifier>) {
        let raw = modifiers(in: flags)
        let keptMask = mask.isDisjoint(with: raw) ? [] : mask
        return (raw.subtracting(keptMask), keptMask)
    }

    private var isTracking: Bool { windowKey || dragHover || !chordMask.isEmpty }
    private var needsPolling: Bool { dragHover || !chordMask.isEmpty }

    func setWindowKey(_ key: Bool) {
        guard key != windowKey else { return }
        windowKey = key
        if key {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.evaluate(event.modifierFlags)
                return event
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        refresh()
    }

    func setDragHover(_ hovering: Bool) {
        guard hovering != dragHover else { return }
        dragHover = hovering
        refresh()
    }

    func beginHotKeyChord(masking chord: Set<PortalSetModifier>) {
        chordMask = chord
        refresh()
    }

    private func refresh() {
        evaluate(NSEvent.modifierFlags)
        if needsPolling {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.evaluate(NSEvent.modifierFlags)
                    if !self.needsPolling { self.stopTimer() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate(_ flags: NSEvent.ModifierFlags) {
        let (held, mask) = Self.resolve(flags: flags, mask: chordMask)
        chordMask = mask
        if isTracking {
            releaseWork?.cancel()
            releaseWork = nil
            onChange(held)
        } else if releaseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.releaseWork = nil
                if !self.isTracking { self.onChange([]) }
            }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
        }
    }
}
