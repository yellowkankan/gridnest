import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let launcher = LauncherController()
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController!
    private var hotkey: HotkeyManager!

    private let defaults = UserDefaults.standard
    private let hotkeyEnabledKey = "hotkeyEnabled"
    private let hotkeyStyleKey = "hotkeyStyle"
    private let dockKey = "showDock"
    private let menuBarKey = "showMenuBar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: hotkeyEnabledKey) == nil { defaults.set(true, forKey: hotkeyEnabledKey) }
        if defaults.string(forKey: hotkeyStyleKey) == nil { defaults.set("controlOptionL", forKey: hotkeyStyleKey) }
        if defaults.object(forKey: dockKey) == nil { defaults.set(true, forKey: dockKey) }
        if defaults.object(forKey: menuBarKey) == nil { defaults.set(true, forKey: menuBarKey) }
        if defaults.integer(forKey: "swipeDirectionRevision") < 1 {
            defaults.set(true, forKey: "swipeReversed")
            defaults.set(1, forKey: "swipeDirectionRevision")
        }
        if defaults.object(forKey: "defaultPage") == nil { defaults.set(0, forKey: "defaultPage") }
        if defaults.object(forKey: "appearanceMode") == nil { defaults.set("system", forKey: "appearanceMode") }
        if defaults.object(forKey: "backgroundStyle") == nil { defaults.set("glass", forKey: "backgroundStyle") }
        if defaults.object(forKey: "backgroundStrength") == nil { defaults.set(0.68, forKey: "backgroundStrength") }
        if defaults.object(forKey: "showAppLabels") == nil { defaults.set(true, forKey: "showAppLabels") }
        if defaults.object(forKey: "labelFontSize") == nil { defaults.set(13.0, forKey: "labelFontSize") }
        if defaults.object(forKey: "labelWeight") == nil { defaults.set("medium", forKey: "labelWeight") }
        if defaults.object(forKey: "pageAnimationDuration") == nil { defaults.set(0.58, forKey: "pageAnimationDuration") }

        applyCustomAppIcon()

        applyActivationPolicy()
        hotkey = HotkeyManager { [weak self] in self?.launcher.toggle() }
        registerHotkeyIfNeeded()

        let actions = SettingsActions(
            setDock: { [weak self] in self?.setShowDock($0) },
            setMenuBar: { [weak self] in self?.setShowMenuBar($0) },
            setHotkey: { [weak self] in self?.setHotkeyEnabled($0) },
            setHotkeyStyle: { [weak self] in self?.setHotkeyStyle($0) },
            reloadLayout: { [weak self] in self?.launcher.applyLayoutSettings() },
            pageCount: { [weak self] in self?.launcher.pageCount ?? 1 },
            selectAppIcon: { [weak self] in self?.selectAppIcon() },
            resetAppIcon: { [weak self] in self?.resetAppIcon() }
        )
        settingsWindow = SettingsWindowController(actions: actions)
        settingsWindow.onClose = { [weak self] in self?.launcher.settingsDidClose() }
        launcher.onOpenSettings = { [weak self] in self?.openSettings() }
        if defaults.bool(forKey: menuBarKey) { showStatusItem() }
        launcher.prepare()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.toggle()
        return false
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(defaults.bool(forKey: dockKey) ? .regular : .accessory)
    }

    private func setShowDock(_ on: Bool) {
        defaults.set(on, forKey: dockKey)
        applyActivationPolicy()
        if !on && !defaults.bool(forKey: menuBarKey) { setShowMenuBar(true) }
    }

    private func setShowMenuBar(_ on: Bool) {
        defaults.set(on, forKey: menuBarKey)
        if on { showStatusItem() } else { statusBar = nil }
        if !on && !defaults.bool(forKey: dockKey) { setShowDock(true) }
    }

    private func showStatusItem() {
        guard statusBar == nil else { return }
        statusBar = StatusBarController(
            onOpen: { [weak self] in self?.launcher.show() },
            onSettings: { [weak self] in self?.openSettings() }
        )
    }

    private func openSettings() { settingsWindow.show() }

    private func hotkeyDefinition() -> (keyCode: UInt32, modifiers: UInt32) {
        if defaults.string(forKey: hotkeyStyleKey) == "f4" {
            return (UInt32(kVK_F4), 0)
        }
        return (UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey))
    }

    private func registerHotkeyIfNeeded() {
        guard defaults.bool(forKey: hotkeyEnabledKey) else { return }
        let definition = hotkeyDefinition()
        if !hotkey.register(keyCode: definition.keyCode, modifiers: definition.modifiers) {
            defaults.set(false, forKey: hotkeyEnabledKey)
        }
    }

    private func setHotkeyEnabled(_ enabled: Bool) {
        hotkey.unregister()
        defaults.set(enabled, forKey: hotkeyEnabledKey)
        registerHotkeyIfNeeded()
    }

    private func setHotkeyStyle(_ style: String) {
        hotkey.unregister()
        defaults.set(style, forKey: hotkeyStyleKey)
        registerHotkeyIfNeeded()
    }

    private func selectAppIcon() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择应用图标")
        panel.message = String(localized: "选择 PNG、ICNS 或 JPEG 图像")
        panel.allowedFileTypes = ["png", "icns", "jpg", "jpeg"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url,
              let image = NSImage(contentsOf: source), let destination = customIconURL(extension: source.pathExtension) else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            defaults.set(destination.path, forKey: "customAppIconPath")
            NSApp.applicationIconImage = image
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func resetAppIcon() {
        let previousPath = defaults.string(forKey: "customAppIconPath")
        defaults.removeObject(forKey: "customAppIconPath")
        if let previousPath { try? FileManager.default.removeItem(atPath: previousPath) }
        NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private func applyCustomAppIcon() {
        guard let path = defaults.string(forKey: "customAppIconPath"), let image = NSImage(contentsOfFile: path) else { return }
        NSApp.applicationIconImage = image
    }

    private func customIconURL(extension fileExtension: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("PositionLauncher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom-app-icon.\(fileExtension.lowercased())")
    }
}
