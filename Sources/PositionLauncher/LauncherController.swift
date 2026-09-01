import AppKit
import SwiftUI

enum LauncherMotion {
    static var pageDuration: Double {
        let value = UserDefaults.standard.object(forKey: "pageAnimationDuration") as? Double ?? 0.58
        return Swift.max(0.18, Swift.min(value, 1.2))
    }

    static var page: Animation { .linear(duration: pageDuration) }
}

/// Borderless window that can still take keyboard focus (for the search field).
final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Content of the menu-bar cover; clicking it closes the overlay, matching a
/// click on any other empty part of the background.
private final class MenuBarCoverView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Owns the full-screen overlay window and its show/hide lifecycle.
final class LauncherController: NSObject, NSWindowDelegate {
    private var window: LauncherWindow?
    private var menuBarCover: NSWindow?
    private let model = LauncherModel()

    // Trackpad swipes are interactive: movement previews the neighboring page,
    // then the release either completes it or springs back.
    private var scrollAccum: CGFloat = 0
    private var interactiveScrollSettling = false
    private var scrollMonitor: Any?
    // The preview is intentionally capped well before a full page. The actual
    // finger travel still decides whether a release commits, so a long swipe
    // has resistance instead of visually crossing multiple pages.
    private let pageSwipePreviewLimit: CGFloat = 0.26
    private let pageSwipeResistanceDistance: CGFloat = 170
    private let pageSwipeCommitDistance: CGFloat = 110

    // Bumped on every show()/close() so a close's fade-out completion can tell
    // whether a show() happened during the fade (and must not order out).
    private var showGeneration = 0
    private var presentationOptionsBeforeOverlay: NSApplication.PresentationOptions?
    private var settingsVisible = false

    /// Called when the user taps the "more" button in the search row.
    var onOpenSettings: (() -> Void)?

    var isOpen: Bool { window?.isVisible ?? false }
    var pageCount: Int { model.pageCount }

    func toggle() { isOpen ? close() : show() }

    func prepare() { model.prepare() }

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        showGeneration += 1
        enterPresentationMode()

        // Always open to a clean state.
        model.query = ""
        model.openFolderID = nil
        model.pageSwipeProgress = 0
        model.pageSwipePreviewTarget = nil
        model.applyLayoutSettings()
        model.openDefaultPage()
        model.prepare()

        // Show on whichever screen the cursor is on. The main window tiles
        // with the menu-bar cover (it stops where the strip begins) instead of
        // extending under it — the strip's blur must sample the wallpaper
        // directly, not our already-blurred output, to come out the same shade.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            window.setFrame(screen.frame, display: true)
            model.dockInsets = Self.dockInsets(of: screen)
        }

        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    func close() {
        guard let window, window.isVisible else { return }
        showGeneration += 1
        let gen = showGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            window.animator().alphaValue = 0
            menuBarCover?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Skip if a show() re-opened the window during the fade.
            if self?.showGeneration == gen {
                window.orderOut(nil)
                self?.menuBarCover?.orderOut(nil)
                self?.leavePresentationMode()
            }
        })
    }

    private func enterPresentationMode() {
        guard presentationOptionsBeforeOverlay == nil else { return }
        presentationOptionsBeforeOverlay = NSApp.presentationOptions
        var options = NSApp.presentationOptions
        options.subtract([.hideMenuBar, .autoHideMenuBar, .hideDock, .autoHideDock])
        options.formUnion([.autoHideMenuBar, .autoHideDock])
        NSApp.presentationOptions = options
    }

    private func leavePresentationMode() {
        guard let options = presentationOptionsBeforeOverlay else { return }
        NSApp.presentationOptions = options
        presentationOptionsBeforeOverlay = nil
    }

    // MARK: - Building

    private func buildWindow() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = LauncherWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self

        let root = LauncherView(
            model: model,
            onLaunch: { [weak self] in self?.launch($0) },
            onClose: { [weak self] in self?.close() },
            onMoveToTrash: { [weak self] in self?.moveToTrash($0) },
            onOpenSettings: { [weak self] in
                self?.settingsVisible = true
                self?.onOpenSettings?()
            }
        )
        // Host the SwiftUI content as the window's contentViewController so it
        // sits properly in the responder chain for keyboard and drag events.
        w.contentViewController = NSHostingController(rootView: root)
        window = w
        setupScrollMonitor()

        // Track display changes (resolution, monitor plug/unplug) while open.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window, window.isVisible else { return }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let screen {
                window.setFrame(screen.frame, display: true)
                self.model.dockInsets = Self.dockInsets(of: screen)
                if let cover = self.menuBarCover, cover.isVisible {
                    cover.setFrame(Self.menuBarRect(of: screen), display: true)
                }
            }
        }
    }

    /// Edges of `screen` the Dock occupies (`visibleFrame` excludes it). The
    /// top is ignored — the menu bar is covered by `menuBarCover` while the
    /// overlay is up. With Dock auto-hide on, `visibleFrame` reaches the
    /// screen edge and the insets come out zero, which is what we want.
    private static func dockInsets(of screen: NSScreen) -> EdgeInsets {
        let f = screen.frame, v = screen.visibleFrame
        return EdgeInsets(top: 0,
                          leading: max(0, v.minX - f.minX),
                          bottom: max(0, v.minY - f.minY),
                          trailing: max(0, f.maxX - v.maxX))
    }

    // MARK: - Menu bar cover

    /// The menu bar sits above the Dock, so it needs its own overlay strip.
    private static func menuBarRect(of screen: NSScreen) -> NSRect {
        let f = screen.frame
        var h = f.maxY - screen.visibleFrame.maxY   // the Dock is never at the top
        if h <= 0 {
            // Menu bar set to auto-hide: visibleFrame reports no top inset,
            // but hovering the top edge would still slide the system menu bar
            // in *above* the overlay — keep a strip tall enough to cover it.
            // (NSMenu().menuBarHeight is 0 for a menu that isn't the main
            // menu bar, so it can't be the fallback; +2 covers the tallest
            // observed bar, e.g. 33pt vs a 32pt notch safe-area.)
            h = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 2
        }
        return NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
    }

    private func showMenuBarCover(on screen: NSScreen) {
        let rect = Self.menuBarRect(of: screen)
        if menuBarCover == nil { buildMenuBarCover() }
        guard let cover = menuBarCover else { return }
        cover.setFrame(rect, display: true)
        cover.alphaValue = 0
        cover.orderFront(nil)
    }

    private func buildMenuBarCover() {
        let cover = NSWindow(contentRect: .zero, styleMask: .borderless,
                             backing: .buffered, defer: false)
        cover.level = .screenSaver
        cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.appearance = NSAppearance(named: .darkAqua)

        let root = MenuBarCoverView()
        root.onClick = { [weak self] in self?.close() }
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.frame = root.bounds
        tint.autoresizingMask = [.width, .height]
        root.addSubview(tint)
        cover.contentView = root
        menuBarCover = cover
    }

    private func setupScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    /// A mouse wheel remains a discrete page command. A two-finger trackpad
    /// gesture instead follows the fingers and only commits after they lift.
    private func handleScroll(_ event: NSEvent) {
        guard let window, window.isVisible, window.isKeyWindow,
              model.openFolderID == nil, model.query.isEmpty else { return }
        if event.momentumPhase != [] { return }              // ignore inertia
        let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let sign = UserDefaults.standard.bool(forKey: "swipeReversed") ? -1 : 1

        if event.phase == [] {                               // discrete mouse wheel
            guard !interactiveScrollSettling else { return }
            scrollAccum += dx
            if abs(scrollAccum) > 8 {
                let delta = (scrollAccum > 0 ? 1 : -1) * sign
                scrollAccum = 0
                withAnimation(LauncherMotion.page) { self.model.changePage(delta) }
            }
            return
        }
        guard !interactiveScrollSettling else { return }
        if event.phase == .began {
            scrollAccum = 0
            model.pageSwipeProgress = 0
            model.pageSwipePreviewTarget = nil
        }
        if event.phase == .began || event.phase == .changed {
            scrollAccum += dx * CGFloat(sign)
            let direction: CGFloat = scrollAccum >= 0 ? 1 : -1
            let distance = abs(scrollAccum)
            // An asymptotic resistance curve: a full-width touchpad movement
            // can preview only a quarter page, rather than racing to a full
            // page while the user's fingers are still down.
            let progress = direction * pageSwipePreviewLimit
                * (1 - exp(-distance / pageSwipeResistanceDistance))
            let delta = progress >= 0 ? 1 : -1
            let target = model.currentPage + delta
            // At the first or last page there is no neighboring page to reveal.
            if target >= 0 && target < model.pageCount {
                model.pageSwipePreviewTarget = target
                model.pageSwipeProgress = progress
            } else {
                model.pageSwipePreviewTarget = nil
                model.pageSwipeProgress = 0
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            finishInteractiveScroll(cancelled: event.phase == .cancelled)
        }
    }

    private func finishInteractiveScroll(cancelled: Bool) {
        let progress = model.pageSwipeProgress
        let travel = abs(scrollAccum)
        scrollAccum = 0
        // At the first/last page the live preview is deliberately held at
        // zero. A long outward swipe must end there rather than treating zero
        // as a negative direction and incorrectly paging back inward.
        guard model.pageSwipePreviewTarget != nil, abs(progress) > 0.0001 else { return }
        guard !cancelled, travel >= pageSwipeCommitDistance else {
            settlePreviewBack()
            return
        }

        let delta = progress > 0 ? 1 : -1
        let target = model.currentPage + delta
        guard target >= 0, target < model.pageCount else {
            settlePreviewBack()
            return
        }

        interactiveScrollSettling = true
        withAnimation(LauncherMotion.page) {
            model.pageSwipeProgress = CGFloat(delta)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + LauncherMotion.pageDuration) { [weak self] in
            guard let self, self.interactiveScrollSettling else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                self.model.setPage(target)
                self.model.pageSwipeProgress = 0
                self.model.pageSwipePreviewTarget = nil
            }
            self.interactiveScrollSettling = false
        }
    }

    private func settlePreviewBack() {
        interactiveScrollSettling = true
        withAnimation(LauncherMotion.page) { model.pageSwipeProgress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + LauncherMotion.pageDuration) { [weak self] in
            guard let self, self.interactiveScrollSettling else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                self.model.pageSwipePreviewTarget = nil
            }
            self.interactiveScrollSettling = false
        }
    }

    func applyLayoutSettings() { model.applyLayoutSettings() }

    func settingsDidClose() {
        settingsVisible = false
        if isOpen { window?.makeKeyAndOrderFront(nil) }
    }

    private func launch(_ app: AppInfo) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            guard let error else { return }
            // A damaged/translocated app would otherwise just close the
            // overlay with no feedback at all.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(
                    format: NSLocalizedString("Could not open “%@”", comment: ""), app.name)
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        close()
    }

    private func moveToTrash(_ app: AppInfo) {
        guard !app.id.hasPrefix("/System/") else {
            presentMoveError(String(localized: "系统应用不能移到废纸篓。"))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "将“%@”移到废纸篓？"), model.displayName(app))
        alert.informativeText = String(localized: "该应用会被移到废纸篓，可在废纸篓中恢复。")
        alert.addButton(withTitle: String(localized: "移到废纸篓"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
                self.model.removeApp(app.id)
            } catch {
                self.presentMoveError(error.localizedDescription)
            }
        }
    }

    private func presentMoveError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "无法移到废纸篓")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if !settingsVisible { close() }
    }
}
