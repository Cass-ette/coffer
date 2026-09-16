import AppKit
import Carbon.HIToolbox

final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var eventCallback: EventHandlerUPP?

    @discardableResult
    func register(keyCode: UInt32, modifiers: [AppSettings.HotkeyModifier]) -> Bool {
        unregister()
        var carbonMods: UInt32 = 0
        for m in modifiers {
            switch m {
            case .command: carbonMods |= UInt32(cmdKey)
            case .option: carbonMods |= UInt32(optionKey)
            case .control: carbonMods |= UInt32(controlKey)
            case .shift: carbonMods |= UInt32(shiftKey)
            }
        }
        let id = EventHotKeyID(signature: OSType(0x434F4646), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonMods, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        hotKeyRef = ref

        let callback: EventHandlerUPP = { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.signature == OSType(0x434F4646) else { return noErr }
            guard let userData else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.handler?()
            return noErr
        }
        self.eventCallback = callback

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        return installStatus == noErr
    }

    func unregister() {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        self.eventCallback = nil
    }
}
