import Carbon.HIToolbox

/// Globale Tastenkürzel über `RegisterEventHotKey`. Das braucht anders als ein
/// globaler NSEvent-Monitor keine Bedienungshilfen-Freigabe.
@MainActor
final class HotKeyCenter {
    private var handlerRef: EventHandlerRef?
    private var hotKeys: [UInt32: (ref: EventHotKeyRef, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x5344_494D // "SDIM"

    /// Liefert `false`, wenn das Kürzel schon von einer anderen App belegt ist.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) -> Bool {
        guard installHandlerIfNeeded() else { return false }
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        nextID += 1
        hotKeys[id] = (ref, action)
        return true
    }

    func unregisterAll() {
        for hotKey in hotKeys.values {
            UnregisterEventHotKey(hotKey.ref)
        }
        hotKeys.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        hotKeys[id]?.action()
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }
}

/// Carbon ruft Handler der Application-Event-Target auf dem Main Thread auf.
private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
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
    let center = UInt(bitPattern: userData)
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: center) else { return }
        Unmanaged<HotKeyCenter>.fromOpaque(pointer).takeUnretainedValue().fire(id)
    }
    return noErr
}
