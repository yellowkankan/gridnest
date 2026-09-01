import SwiftUI
import AppKit

// MARK: - Layout model

struct Folder: Identifiable, Hashable {
    let id: String
    var name: String
    var appPaths: [String]
}

/// A top-level grid slot.  Placeholders are persisted so a page keeps its
/// shape when an item is merged, hidden, or moved to another page.
enum LaunchItem: Identifiable, Hashable {
    case app(String)        // app bundle path
    case folder(Folder)
    case placeholder(String)

    var id: String {
        switch self {
        case .app(let path): return "app:" + path
        case .folder(let f): return "folder:" + f.id
        case .placeholder(let id): return "placeholder:" + id
        }
    }

    var isFolder: Bool { if case .folder = self { return true }; return false }
    var isPlaceholder: Bool { if case .placeholder = self { return true }; return false }
}

// MARK: - Model

final class LauncherModel: ObservableObject {
    @Published var items: [LaunchItem] = []     // top-level, ordered
    @Published var query: String = ""
    @Published var openFolderID: String? = nil
    @Published var currentPage = 0
    /// Signed, normalized live progress from a two-finger page swipe. This is
    /// only nonzero while the finger is down or the release is settling.
    @Published var pageSwipeProgress: CGFloat = 0
    /// Neighboring page retained until a cancelled gesture has physically
    /// moved it back beyond the viewport.
    @Published var pageSwipePreviewTarget: Int? = nil
    var lastPageDir = 1     // +1 = moved to a later page, -1 = earlier (slide direction)

    // Configurable grid layout (persisted in UserDefaults via Settings).
    @Published var columns = 7
    @Published var rows = 5
    @Published var iconSize: CGFloat = 92

    // Edges the Dock occupies on the current screen; the grid keeps clear of
    // them so icons never sit under the (visible, clickable) Dock.
    @Published var dockInsets = EdgeInsets()

    var pageSize: Int { Swift.max(1, columns * rows) }
    var pageCount: Int { Swift.max(1, (items.count + pageSize - 1) / pageSize) }

    init() {
        migrateInterfaceDefaults()
        applyLayoutSettings()
    }

    private func migrateInterfaceDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "interfaceRevision") < 4 else { return }
        if defaults.object(forKey: "iconSize") == nil || [74, 92, 104].contains(defaults.double(forKey: "iconSize")) {
            defaults.set(92, forKey: "iconSize")
        }
        defaults.set(4, forKey: "interfaceRevision")
    }

    func applyLayoutSettings() {
        let d = UserDefaults.standard
        columns = Swift.max(4, Swift.min(d.object(forKey: "columns") as? Int ?? 7, 10))
        rows = Swift.max(3, Swift.min(d.object(forKey: "rows") as? Int ?? 5, 8))
        let size = d.object(forKey: "iconSize") != nil ? CGFloat(d.double(forKey: "iconSize")) : 92
        iconSize = Swift.max(40, Swift.min(size, 120))
        if currentPage >= pageCount { currentPage = pageCount - 1 }
    }

    func changePage(_ delta: Int) { setPage(currentPage + delta) }

    func setPage(_ page: Int) {
        let next = Swift.max(0, Swift.min(page, pageCount - 1))
        guard next != currentPage else { return }
        lastPageDir = next > currentPage ? 1 : -1
        currentPage = next
    }

    private(set) var appsByPath: [String: AppInfo] = [:]
    private var nameOverrides = AppNameStore.load()
    private var lastUsed = LaunchHistoryStore.load()
    private var hiddenPaths = HiddenAppsStore.load()
    private var loaded = false
    private var hasStarted = false
    private var isScanning = false

    // Lookups -----------------------------------------------------------------

    func app(_ path: String) -> AppInfo? { appsByPath[path] }

    func folder(_ id: String) -> Folder? {
        for case .folder(let f) in items where f.id == id { return f }
        return nil
    }

    var searchResults: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return appsByPath.values
            .filter { displayName($0).localizedCaseInsensitiveContains(q) }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    /// Up to 9 icons for a folder's mini preview.
    func previewIcons(_ folder: Folder) -> [AppInfo] {
        folder.appPaths.prefix(9).compactMap { appsByPath[$0] }
    }

    var hiddenApps: [AppInfo] {
        hiddenPaths.compactMap { appsByPath[$0] }
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    func displayName(_ app: AppInfo) -> String {
        let override = nameOverrides[app.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? app.name : override
    }

    func renameApp(_ path: String, _ name: String) {
        guard appsByPath[path] != nil else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { nameOverrides.removeValue(forKey: path) }
        else { nameOverrides[path] = cleaned }
        AppNameStore.save(nameOverrides)
        objectWillChange.send()
    }

    func recordLaunch(_ path: String) {
        lastUsed[path] = Date()
        LaunchHistoryStore.save(lastUsed)
    }

    // Loading -----------------------------------------------------------------

    /// Presents the cached catalog immediately, then refreshes it off the UI path.
    func prepare() {
        guard !hasStarted else { return }
        hasStarted = true
        if let cached = AppCatalogStore.load() {
            apply(cached)
        }
        refreshInBackground()
    }

    func refreshInBackground() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppScanner.scan()
            DispatchQueue.main.async {
                AppCatalogStore.save(apps)
                self.apply(apps)
                self.isScanning = false
            }
        }
    }

    private func apply(_ apps: [AppInfo]) {
        appsByPath = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let installed = Set(apps.map { $0.id })
        if !loaded {
            if let saved = LayoutStore.loadFromDisk(installed: installed) {
                items = saved
                reconcile(installed: installed)
            } else {
                items = apps.map { .app($0.id) }
                save()
            }
            loaded = true
        } else {
            reconcile(installed: installed)
        }
    }

    /// Drop uninstalled apps and append newly installed ones.
    private func reconcile(installed: Set<String>) {
        hiddenPaths.formIntersection(installed)
        HiddenAppsStore.save(hiddenPaths)
        var present = Set<String>()
        var newItems: [LaunchItem] = []
        for item in items {
            switch item {
            case .app(let p):
                if installed.contains(p) {
                    newItems.append(.app(p)); present.insert(p)
                } else {
                    newItems.append(.placeholder(UUID().uuidString))
                }
            case .folder(var f):
                f.appPaths = f.appPaths.filter { installed.contains($0) }
                f.appPaths.forEach { present.insert($0) }
                newItems.append(.folder(f))
            case .placeholder(let id):
                newItems.append(.placeholder(id))
            }
        }
        present.formUnion(hiddenPaths)
        for p in installed.subtracting(present).sorted(by: {
            (appsByPath[$0]?.name ?? "").localizedCaseInsensitiveCompare(appsByPath[$1]?.name ?? "") == .orderedAscending
        }) {
            newItems.append(.app(p))
        }
        items = newItems
        cleanup()
        save()
    }

    // Mutations ---------------------------------------------------------------

    func renameFolder(_ id: String, _ name: String) {
        guard let i = items.firstIndex(where: { $0.id == "folder:" + id }),
              case .folder(var f) = items[i] else { return }
        f.name = name.isEmpty ? f.name : name
        items[i] = .folder(f)
        save()
    }

    func createFolder() {
        items.append(.folder(Folder(id: UUID().uuidString, name: String(localized: "新建文件夹"), appPaths: [])))
        save()
    }

    func removeApp(_ path: String) {
        var affectedPages = Set<Int>()
        for index in items.indices {
            let item = items[index]
            switch item {
            case .app(let itemPath):
                if itemPath == path {
                    items[index] = .placeholder(UUID().uuidString)
                    affectedPages.insert(index / pageSize)
                }
            case .folder(var folder):
                folder.appPaths.removeAll { $0 == path }
                items[index] = .folder(folder)
            case .placeholder:
                break
            }
        }
        nameOverrides.removeValue(forKey: path)
        lastUsed.removeValue(forKey: path)
        hiddenPaths.remove(path)
        AppNameStore.save(nameOverrides)
        LaunchHistoryStore.save(lastUsed)
        HiddenAppsStore.save(hiddenPaths)
        affectedPages.forEach { compactPage($0) }
        cleanup()
        save()
    }

    func hideApp(_ path: String) {
        guard appsByPath[path] != nil else { return }
        hiddenPaths.insert(path)
        var affectedPages = Set<Int>()
        for index in items.indices {
            let item = items[index]
            switch item {
            case .app(let itemPath):
                if itemPath == path {
                    items[index] = .placeholder(UUID().uuidString)
                    affectedPages.insert(index / pageSize)
                }
            case .folder(var folder):
                folder.appPaths.removeAll { $0 == path }
                items[index] = .folder(folder)
            case .placeholder:
                break
            }
        }
        HiddenAppsStore.save(hiddenPaths)
        affectedPages.forEach { compactPage($0) }
        cleanup()
        save()
    }

    func unhideApp(_ path: String, toPage page: Int) {
        guard hiddenPaths.remove(path) != nil, appsByPath[path] != nil else { return }
        let targetPage = Swift.max(0, Swift.min(page, pageCount - 1))
        if let empty = placeholderIndex(onPage: targetPage) {
            items[empty] = .app(path)
            compactPage(targetPage)
        } else {
            items.append(.app(path))
        }
        HiddenAppsStore.save(hiddenPaths)
        save()
    }

    func sortItems(_ mode: SortMode) {
        guard mode != .custom else { return }
        for page in 0..<pageCount {
            let range = pageRange(page)
            guard !range.isEmpty else { continue }
            let sorted = items[range].filter { !$0.isPlaceholder }.sorted { lhs, rhs in
                switch mode {
                case .nameAscending:
                    return itemName(lhs).localizedCaseInsensitiveCompare(itemName(rhs)) == .orderedAscending
                case .nameDescending:
                    return itemName(lhs).localizedCaseInsensitiveCompare(itemName(rhs)) == .orderedDescending
                case .dateAdded:
                    return itemDate(lhs) > itemDate(rhs)
                case .lastUsed:
                    return itemLastUsed(lhs) > itemLastUsed(rhs)
                case .custom:
                    return false
                }
            }
            let slots = Array(range)
            for (offset, slot) in slots.enumerated() {
                items[slot] = offset < sorted.count ? sorted[offset] : .placeholder(UUID().uuidString)
            }
        }
        save()
    }

    @discardableResult
    func moveCurrentPage(by delta: Int) -> Int {
        let allPages = Swift.stride(from: 0, to: items.count, by: pageSize).map {
            Array(items[$0..<Swift.min($0 + pageSize, items.count)])
        }
        guard allPages.indices.contains(currentPage) else { return currentPage }
        let destination = Swift.max(0, Swift.min(currentPage + delta, allPages.count - 1))
        guard destination != currentPage else { return currentPage }
        var pages = allPages
        let page = pages.remove(at: currentPage)
        pages.insert(page, at: destination)
        items = pages.flatMap { $0 }
        currentPage = destination
        save()
        return destination
    }

    func moveItem(_ id: String, toPage page: Int) {
        moveItem(id: id, toPage: page, slot: 0)
        save()
    }

    func setDefaultPage(_ page: Int) {
        UserDefaults.standard.set(Swift.max(0, Swift.min(page, pageCount - 1)), forKey: "defaultPage")
    }

    func openDefaultPage() {
        let requested = UserDefaults.standard.integer(forKey: "defaultPage")
        currentPage = Swift.max(0, Swift.min(requested, pageCount - 1))
    }

    func removeFromFolder(_ folderID: String, _ path: String) {
        guard let i = items.firstIndex(where: { $0.id == "folder:" + folderID }),
              case .folder(var f) = items[i] else { return }
        f.appPaths.removeAll { $0 == path }
        items[i] = .folder(f)
        let page = i / pageSize
        if let empty = placeholderIndex(onPage: page) {
            items[empty] = .app(path)
        } else {
            items.append(.app(path))
        }
        cleanup()
        if folder(folderID) == nil { openFolderID = nil }   // folder dissolved
        save()
    }

    /// Move an app within a folder to an absolute index among the remaining apps.
    func moveInFolder(_ folderID: String, move path: String, toIndex index: Int) {
        guard let i = items.firstIndex(where: { $0.id == "folder:" + folderID }),
              case .folder(var f) = items[i] else { return }
        f.appPaths.removeAll { $0 == path }
        let target = Swift.max(0, Swift.min(index, f.appPaths.count))
        f.appPaths.insert(path, at: target)
        items[i] = .folder(f)
        save()
    }

    // MARK: - Live custom drag (no disk writes until commitLayout)

    /// Move an item to a new absolute index.  The target is resolved to a
    /// fixed page slot so an operation cannot make another page refill itself.
    func moveItem(id: String, toIndex index: Int) {
        guard !items.isEmpty else { return }
        let target = max(0, min(index, items.count - 1))
        moveItem(id: id, toPage: target / pageSize, slot: target % pageSize)
    }

    /// Fixed-slot move used by the grid.  Cross-page drops use an empty slot
    /// when possible; on a full page they exchange with the item under the
    /// cursor.  This preserves each page's independent layout.
    func moveItem(id: String, toPage page: Int, slot: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }),
              page >= 0, page < pageCount else { return }
        let sourcePage = from / pageSize
        let range = pageRange(page)
        guard !range.isEmpty else { return }
        let target = Swift.max(range.lowerBound, Swift.min(range.lowerBound + slot, range.upperBound - 1))
        guard from != target else { return }

        if sourcePage == page {
            let moving = items[from]
            var pageItems = Array(items[range]).filter { !$0.isPlaceholder }
            pageItems.removeAll { $0.id == moving.id }
            let localTarget = Swift.min(target - range.lowerBound, pageItems.count)
            pageItems.insert(moving, at: localTarget)
            writePage(pageItems, page: page)
        } else if items[target].isPlaceholder {
            let moving = items[from]
            items[from] = .placeholder(UUID().uuidString)
            compactPage(sourcePage)
            var targetItems = Array(items[range]).filter { !$0.isPlaceholder }
            let localTarget = Swift.min(target - range.lowerBound, targetItems.count)
            targetItems.insert(moving, at: localTarget)
            writePage(targetItems, page: page)
        } else {
            items.swapAt(from, target)
            compactPage(sourcePage)
        }
    }

    /// Merge the dragged app into the target app (new folder) or folder (append).
    func makeOrJoinFolder(draggingID: String, targetID: String) {
        guard draggingID != targetID,
              let dragItem = items.first(where: { $0.id == draggingID }),
              case .app(let dragPath) = dragItem,
              let targetItem = items.first(where: { $0.id == targetID }) else {
            commitLayout(); return
        }
        guard let sourceIndex = items.firstIndex(where: { $0.id == draggingID }) else { return }
        items[sourceIndex] = .placeholder(UUID().uuidString)
        switch targetItem {
        case .folder(let f):
            if let i = items.firstIndex(where: { $0.id == "folder:" + f.id }),
               case .folder(var ff) = items[i] {
                if !ff.appPaths.contains(dragPath) { ff.appPaths.append(dragPath) }
                items[i] = .folder(ff)
            }
        case .app(let targetPath):
            if let i = items.firstIndex(where: { $0.id == "app:" + targetPath }) {
                items[i] = .folder(Folder(id: UUID().uuidString, name: String(localized: "Folder"),
                                          appPaths: [targetPath, dragPath]))
            }
        case .placeholder:
            break
        }
        compactPage(sourceIndex / pageSize)
        cleanup(); save()
    }

    /// Persist the current order once a drag finishes.
    func commitLayout() { cleanup(); save() }

    /// Single-item folders collapse back into an app; intentionally empty
    /// folders remain available as destinations for a newly created folder.
    private func cleanup() {
        var result: [LaunchItem] = []
        for item in items {
            if case .folder(let f) = item {
                if f.appPaths.count == 1 { result.append(.app(f.appPaths[0])); continue }
            }
            result.append(item)
        }
        items = result
    }

    private func save() { LayoutStore.save(items) }

    private func itemName(_ item: LaunchItem) -> String {
        switch item {
        case .app(let path): return appsByPath[path].map { displayName($0) } ?? ""
        case .folder(let folder): return folder.name
        case .placeholder: return ""
        }
    }

    private func itemDate(_ item: LaunchItem) -> Date {
        switch item {
        case .app(let path):
            return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        case .folder:
            return .distantPast
        case .placeholder:
            return .distantPast
        }
    }

    private func itemLastUsed(_ item: LaunchItem) -> Date {
        switch item {
        case .app(let path): return lastUsed[path] ?? .distantPast
        case .folder(let folder): return folder.appPaths.compactMap { lastUsed[$0] }.max() ?? .distantPast
        case .placeholder: return .distantPast
        }
    }

    func pageIndex(for id: String) -> Int? {
        items.firstIndex(where: { $0.id == id }).map { $0 / pageSize }
    }

    private func pageRange(_ page: Int) -> Range<Int> {
        let start = page * pageSize
        return start..<Swift.min(start + pageSize, items.count)
    }

    private func placeholderIndex(onPage page: Int) -> Int? {
        pageRange(page).first { items[$0].isPlaceholder }
    }

    /// Repack only this page and retain its exact number of slots.  The next
    /// page is deliberately never consulted or shifted.
    private func compactPage(_ page: Int) {
        writePage(Array(items[pageRange(page)]).filter { !$0.isPlaceholder }, page: page)
    }

    private func writePage(_ visibleItems: [LaunchItem], page: Int) {
        let range = pageRange(page)
        guard !range.isEmpty else { return }
        let kept = Array(visibleItems.prefix(range.count))
        let blanks = (0..<(range.count - kept.count)).map { _ in LaunchItem.placeholder(UUID().uuidString) }
        items.replaceSubrange(range, with: kept + blanks)
    }
}

enum SortMode: CaseIterable, Hashable {
    case custom, nameAscending, nameDescending, dateAdded, lastUsed

    var title: String {
        switch self {
        case .custom: return String(localized: "自定义")
        case .nameAscending: return String(localized: "名称 A–Z")
        case .nameDescending: return String(localized: "名称 Z–A")
        case .dateAdded: return String(localized: "添加日期")
        case .lastUsed: return String(localized: "上次使用")
        }
    }
}

private enum AppNameStore {
    private static var fileURL: URL? { AppSupportFiles.url(named: "app-names.json") }
    static func load() -> [String: String] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    static func save(_ names: [String: String]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private enum LaunchHistoryStore {
    private static var fileURL: URL? { AppSupportFiles.url(named: "last-used.json") }
    static func load() -> [String: Date] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }
    static func save(_ history: [String: Date]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private enum HiddenAppsStore {
    private static var fileURL: URL? { AppSupportFiles.url(named: "hidden-apps.json") }
    static func load() -> Set<String> {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }
    static func save(_ paths: Set<String>) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(paths.sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private enum AppSupportFiles {
    static func url(named fileName: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("PositionLauncher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
}

// MARK: - Persistence

enum LayoutStore {
    private struct Entry: Codable {
        var type: String         // "app" | "folder" | "placeholder"
        var path: String?
        var id: String?
        var name: String?
        var apps: [String]?
    }

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("PositionLauncher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    /// Returns the saved layout, or nil if no layout file exists yet.
    static func loadFromDisk(installed: Set<String>) -> [LaunchItem]? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return nil
        }
        var present = Set<String>()
        var items: [LaunchItem] = []
        for e in entries {
            if e.type == "folder", let id = e.id {
                let paths = (e.apps ?? []).filter { installed.contains($0) }
                paths.forEach { present.insert($0) }
                if paths.count == 1, let only = paths.first {
                    items.append(.app(only))
                } else {
                    items.append(.folder(Folder(id: id, name: e.name ?? String(localized: "Folder"), appPaths: paths)))
                }
            } else if e.type == "app", let p = e.path, installed.contains(p) {
                items.append(.app(p)); present.insert(p)
            } else if e.type == "placeholder", let id = e.id {
                items.append(.placeholder(id))
            }
        }
        // Newly installed apps are appended by the model's reconcile(), which
        // orders them by name and persists the result.
        return items
    }

    static func save(_ items: [LaunchItem]) {
        guard let url = fileURL else { return }
        let entries: [Entry] = items.map { item in
            switch item {
            case .app(let p): return Entry(type: "app", path: p, id: nil, name: nil, apps: nil)
            case .folder(let f): return Entry(type: "folder", path: nil, id: f.id, name: f.name, apps: f.appPaths)
            case .placeholder(let id): return Entry(type: "placeholder", path: nil, id: id, name: nil, apps: nil)
            }
        }
        do {
            // Atomic, so a crash mid-write can't leave a truncated file that
            // the next launch would misread as "no layout" and overwrite.
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            // A full disk would otherwise silently discard every reorder.
            NSLog("PositionLauncher: failed to save layout: \(error)")
            warnSaveFailedOnce()
        }
    }

    private static var warnedSaveFailure = false
    private static func warnSaveFailedOnce() {
        guard !warnedSaveFailure else { return }
        warnedSaveFailure = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("Could not save the layout", comment: "")
            alert.informativeText = NSLocalizedString(
                "Your icon layout could not be written to disk. Check the available disk space.", comment: "")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

enum AppCatalogStore {
    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("PositionLauncher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    static func load() -> [AppInfo]? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let apps = try? JSONDecoder().decode([AppInfo].self, from: data), !apps.isEmpty else {
            return nil
        }
        return apps
    }

    static func save(_ apps: [AppInfo]) {
        guard let fileURL, let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
