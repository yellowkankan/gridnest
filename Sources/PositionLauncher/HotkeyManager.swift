import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via the Carbon Hot Key API.
final class HotkeyManager {
    let action: () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static var shared: HotkeyManager?

    init(action: @escaping () -> Void) {
        self.action = action
        HotkeyManager.shared = self
    }

    /// Returns true only if the hotkey is now actually registered. If the
    /// combo is already taken by another app (or Carbon otherwise fails), this
    /// rolls back and returns false so callers can reflect the disabled state.
    @discardableResult
    func register(keyCode: UInt32,
                  modifiers: UInt32) -> Bool {
        guard hotKeyRef == nil else { return true }

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: OSType(kEventHotKeyPressed))
            let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                    hotkeyEventHandler, 1, &eventType,
                                                    nil, &handlerRef)
            guard installStatus == noErr else {
            NSLog("PositionLauncher: InstallEventHandler failed (\(installStatus))")
                handlerRef = nil
                return false
            }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x504C4159), id: 1) // 'PLAY'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else {
            NSLog("PositionLauncher: RegisterEventHotKey failed (\(status))")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

/// C callback invoked when the hotkey fires.
private func hotkeyEventHandler(_ next: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    HotkeyManager.shared?.action()
    return noErr
}
