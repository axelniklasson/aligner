import Carbon

/// Global hotkeys via Carbon's RegisterEventHotKey, which works without any
/// Accessibility permission and while the app is in the background.
final class HotKeyCenter {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x414C_4E52  // 'ALNR'

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.handlers[hotKeyID.id]?()
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Debug.log("failed to register hotkey \(keyCode): \(status)")
            return
        }
        hotKeyRefs.append(ref)
        handlers[id.id] = handler
    }
}
