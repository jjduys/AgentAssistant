import AppKit
import Carbon

/// Registers a system hot key without requiring accessibility/key-monitoring access.
final class ShelfHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let identifier: UInt32
    private(set) var registrationStatus: OSStatus = noErr
    var isRegistered: Bool { hotKey != nil }

    init(shortcut: KeyboardShortcut = .shelf, identifier: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.identifier = identifier
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        registrationStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let owner = Unmanaged<ShelfHotKey>.fromOpaque(context).takeUnretainedValue()
            guard result == noErr, identifier.signature == 0x54434E54, identifier.id == owner.identifier else { return OSStatus(eventNotHandledErr) }
            owner.action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard registrationStatus == noErr else { return }
        registrationStatus = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x54434E54, id: identifier), GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
