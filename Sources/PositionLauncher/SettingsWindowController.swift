import AppKit
import SwiftUI

/// A standard titled window hosting the SwiftUI settings panel.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let actions: SettingsActions
    var onClose: (() -> Void)?

    init(actions: SettingsActions) { self.actions = actions }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(actions: actions))
            let w = NSWindow(contentViewController: host)
            w.title = "GridNest 设置"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
