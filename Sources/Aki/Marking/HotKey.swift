import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's RegisterEventHotKey: works while any app
/// is in front, and needs no Accessibility permission.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let action: () -> Void
    /// False when another app already holds this shortcut.
    private(set) var registered = false
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]

    /// ⇧⌘A unless given: `keyCode` is a `kVK_*` code, `modifiers` Carbon flags.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_A), modifiers: UInt32 = UInt32(shiftKey | cmdKey), action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKey.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, &handlerReference)

        let hotKeyID = EventHotKeyID(signature: OSType(0x414B_4921), id: id)  // "AKI!"
        registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference) == noErr
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }
}
