import AppKit

/// The keys while marking, read without taking the focus from the app below (as the
/// Mac's own ⌘⇧4 does): its menu stays open, its selection stays blue. An event tap
/// sees each key first; the handler says whether Aki keeps it or the app gets it.
/// Needs Accessibility (marking already does); nil without it.
final class KeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate let handler: (NSEvent) -> Bool

    /// `handler` returns true for a key Aki takes (the app below never sees it).
    init?(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
            // Too slow once, or switched off by the system: back on, the key goes through.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let key = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            // Added to the main run loop: this runs on the main thread.
            let taken = MainActor.assumeIsolated { me.handler(key) }
            return taken ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}

/// While marking, the pointer's moves stop reaching the app in front (below the overlay):
/// it would still follow them and put up its own pointer (a link's hand) at every move,
/// the pin blinking back each time. Aki's own windows get theirs as before. Needs
/// Accessibility, as `KeyTap`; nil without it.
final class MoveTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// While true (⇧ held: clicks go to the app below), the moves go there too.
    fileprivate let passes: () -> Bool

    init?(passes: @escaping () -> Bool) {
        self.passes = passes
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MoveTap>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            guard target != 0, target != getpid() else { return Unmanaged.passUnretained(event) }
            // Posted by Aki itself (a ⇧-click passed to the app below): it goes through.
            if pid_t(event.getIntegerValueField(.eventSourceUnixProcessID)) == getpid() { return Unmanaged.passUnretained(event) }
            // Added to the main run loop: this runs on the main thread.
            return MainActor.assumeIsolated { me.passes() } ? Unmanaged.passUnretained(event) : nil
        }
        // The annotated tap: by then each move knows which app it goes to.
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}

/// From the shortcut until the marking screen is up (the screens are captured first,
/// about a tenth of a second): a click or a drag begun meanwhile is kept from the app
/// below (it would select its text) and handed to the marking screen once it's there.
/// Needs Accessibility, as `KeyTap`; nil without it.
final class ClickHold {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Where the button went down (global, top-left origin), and whether it's up again.
    fileprivate var down: CGPoint?
    fileprivate var up = false

    init?() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ClickHold>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Posted by Aki itself: it goes through.
            if pid_t(event.getIntegerValueField(.eventSourceUnixProcessID)) == getpid() { return Unmanaged.passUnretained(event) }
            // Only a click begun now is held: the end of the one that opened marking
            // (a ring in the sidebar, a menu) goes where it was going.
            let held: Bool = MainActor.assumeIsolated {
                switch type {
                case .leftMouseDown:
                    if me.down == nil { me.down = event.location }
                    return true
                case .leftMouseUp where me.down != nil:
                    me.up = true
                    return true
                default:
                    return me.down != nil
                }
            }
            return held ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The marking screen is up: clicks reach it again, and the one caught meanwhile is
    /// given to it — pressed where it began, moved to where the pointer is now, and let
    /// go if it already was (a drag still going on carries on by itself).
    func release() {
        stop()
        guard let down else { return }
        let now = CGEvent(source: nil)?.location ?? down
        let source = CGEventSource(stateID: .privateState)
        var steps: [(CGEventType, CGPoint)] = [(.leftMouseDown, down)]
        if hypot(now.x - down.x, now.y - down.y) > 1 { steps.append((.leftMouseDragged, now)) }
        if up { steps.append((.leftMouseUp, now)) }
        for (type, point) in steps {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []
            if type != .leftMouseDragged { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
            event?.post(tap: .cghidEventTap)
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}
