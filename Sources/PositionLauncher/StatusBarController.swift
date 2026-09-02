import AppKit

final class StatusBarController: NSObject {
    private let item: NSStatusItem
    private let onOpen: () -> Void
    private let onSettings: () -> Void

    init(onOpen: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onSettings = onSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "GridNest")
            image?.isTemplate = true
            button.image = image
        }
        buildMenu()
    }

    deinit { NSStatusBar.system.removeStatusItem(item) }

    private func buildMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 GridNest", action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 GridNest", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func openLauncher() { onOpen() }
    @objc private func openSettings() { onSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
