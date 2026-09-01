import SwiftUI
import AppKit

/// Full-screen application grid with drag sorting, folders, paging, and search.
struct LauncherView: View {
    private struct DropSettlement: Equatable {
        let id: String
        let page: Int
        var point: CGPoint
        let destination: CGPoint
    }

    @ObservedObject var model: LauncherModel
    let onLaunch: (AppInfo) -> Void
    let onClose: () -> Void
    let onMoveToTrash: (AppInfo) -> Void
    let onOpenSettings: () -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("backgroundStyle") private var backgroundStyle = "glass"
    @AppStorage("backgroundStrength") private var backgroundStrength = 0.68
    @AppStorage("showAppLabels") private var showAppLabels = true
    @AppStorage("labelFontSize") private var labelFontSize = 13.0
    @AppStorage("labelWeight") private var labelWeight = "medium"

    // Drag state
    @State private var dragID: String?          // item being dragged
    @State private var dragOriginPage: Int?     // keeps cross-page previews stable
    @State private var dragOriginSlot: Int?
    @State private var dragPoint: CGPoint = .zero
    @State private var dropSettlement: DropSettlement?
    @State private var folderTargetID: String?  // icon highlighted to form a folder
    @State private var pressItemID: String?     // item under the initial press
    @State private var pressClassified = false
    @State private var gapSlot: Int = 0         // page slot the dragged item will drop into
    @State private var lastHoverSlot: Int = 0
    @State private var hoverItemID: String?     // icon currently under the cursor
    @State private var dwellTimer: Timer?
    @State private var edgeTimer: Timer?
    @State private var hoverID: String?
    @State private var renameRequest: RenameRequest?

    // Drag handed off from an open folder (classic: dragging past the folder
    // edge closes it and the drag continues over the page). The app stays in
    // the folder until the drop so the overlay never unmounts mid-gesture.
    @State private var extDragPath: String?
    @State private var gridFrame: CGRect = .zero   // pagedGrid frame, global coords

    private func flowItems() -> [LaunchItem] {
        currentPageItems.filter { !$0.isPlaceholder && $0.id != dragID }
    }

    /// Highlight behind a hovered icon so it's clear the icon is the click
    /// target (launches the app), versus empty space (closes the launcher).
    private func hoverHighlight(_ hovering: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.primary.opacity(hovering ? (colorScheme == .dark ? 0.14 : 0.09) : 0))
            .padding(4)
    }

    private func setHover(_ id: String, _ hovering: Bool) {
        if hovering { hoverID = id }
        else if hoverID == id { hoverID = nil }
    }

    private var columns: Int { model.columns }
    private var rows: Int { model.rows }
    private var pageSize: Int { model.pageSize }
    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // The page transition needs a viewport that reaches the actual screen
    // edges.  Keep the visible icon margins as data inside that full-width
    // viewport instead of padding the entire grid container; otherwise its
    // clipping edge sits inboard and exposes a sliver of the departing page.
    private func gridHorizontalInsets(_ size: CGSize) -> (leading: CGFloat, trailing: CGFloat) {
        (90 + model.dockInsets.leading, 90 + model.dockInsets.trailing)
    }

    private func cellW(_ size: CGSize) -> CGFloat {
        let insets = gridHorizontalInsets(size)
        return max(1, size.width - insets.leading - insets.trailing) / CGFloat(columns)
    }
    private func gridMetrics(_ size: CGSize) -> (icon: CGFloat, row: CGFloat, hitWidth: CGFloat, hitHeight: CGFloat) {
        let row = max(1, size.height / CGFloat(rows))
        let icon = min(model.iconSize, max(48, row - 38))
        return (icon, row, icon + 44, min(row, icon + 42))
    }

    // Compact hover/click target around the icon (not the whole wide cell), so
    // the gaps between icons close the launcher rather than launching an app.
    private var searchHitWidth: CGFloat { model.iconSize + 44 }
    private var searchHitHeight: CGFloat { model.iconSize + 42 }
    private func gridOrigin(_ size: CGSize) -> CGPoint {
        CGPoint(x: gridHorizontalInsets(size).leading, y: 0)
    }

    private func slotCenter(_ slot: Int, size: CGSize) -> CGPoint {
        let origin = gridOrigin(size)
        let metrics = gridMetrics(size)
        let col = slot % columns
        let row = slot / columns
        return CGPoint(x: origin.x + cellW(size) * (CGFloat(col) + 0.5),
                       y: origin.y + metrics.row * (CGFloat(row) + 0.5))
    }

    private var pages: [[LaunchItem]] { paginate(model.items) }
    private var currentPageItems: [LaunchItem] {
        let p = pages
        return p.indices.contains(model.currentPage) ? p[model.currentPage] : []
    }

    var body: some View {
        ZStack {
            LaunchpadGlassTint(style: backgroundStyle, strength: backgroundStrength)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if dragID == nil { onClose() } }

            VStack(spacing: 22) {
                searchBar
                if model.query.isEmpty {
                    pagedGrid
                    pageDots(count: pages.count)
                } else {
                    searchGrid(model.searchResults)
                }
            }
            .padding(.top, 54 + model.dockInsets.top)
            .padding(.bottom, max(104, model.dockInsets.bottom + 20))

            if let id = model.openFolderID {
                FolderOverlay(model: model, folderID: id, onLaunch: {
                                  model.recordLaunch($0.id)
                                  onLaunch($0)
                              },
                              onDragOut: { path, global in beginFolderDragOut(path, at: global) },
                              onDragOutMoved: { global in
                                  dragPoint = toGrid(global)
                                  handleDragMove(dragPoint, size: gridFrame.size)
                              },
                              onDragOutEnded: { endFolderDragOut(folderID: id) },
                              onMoveToTrash: onMoveToTrash)
            }
        }
        .background(NativeGlassBackground(mode: appearanceMode).ignoresSafeArea())
        .preferredColorScheme(preferredColorScheme)
        .onAppear { searchFocused = true }
        .onChange(of: model.query) {
            // Typing swaps the grid for search results, tearing the drag
            // gesture down without onEnded — drop any in-flight drag state.
            resetDragState()
            model.currentPage = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Re-opening after ⌘-Tab (window closes mid-drag): clear leftovers.
            resetDragState()
        }
        .onKeyPress(.escape) {
            resetDragState()
            if model.openFolderID != nil { model.openFolderID = nil }
            else if !model.query.isEmpty { model.query = "" }
            else { onClose() }
            return .handled
        }
        .onKeyPress(.return) {
            if let first = model.searchResults.first {
                model.recordLaunch(first.id)
                onLaunch(first)
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard model.query.isEmpty, model.openFolderID == nil else { return .ignored }
            changePage(-1); return .handled
        }
        .onKeyPress(.rightArrow) {
            guard model.query.isEmpty, model.openFolderID == nil else { return .ignored }
            changePage(+1); return .handled
        }
        .sheet(item: $renameRequest) { request in
            RenameSheet(title: request.title, initialName: request.initialName) { name in
                switch request.target {
                case .app(let path): model.renameApp(path, name)
                case .folder(let id): model.renameFolder(id, name)
                }
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 16)
            .frame(width: 280, height: 44)

            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: 1, height: 22)

            Button(action: onOpenSettings) {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().fill(LinearGradient(
                        colors: [.white.opacity(0.20), .white.opacity(0.04), .clear],
                        startPoint: .top, endPoint: .bottom))
                }
        }
        .overlay(Capsule().stroke(.white.opacity(0.38), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Paged grid (custom drag)

    private var pagedGrid: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Keep the current page mounted for the entire trackpad
                // interaction. Replacing it with a different conditional
                // branch at progress = 0 would accidentally trigger a second
                // transition when a short swipe returns to the same page.
                pageGridView(currentPageItems, pageIndex: model.currentPage, size: geo.size)
                    .id(model.currentPage)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.lastPageDir >= 0 ? .trailing : .leading),
                        removal: .move(edge: model.lastPageDir >= 0 ? .leading : .trailing)))
                    .offset(x: -model.pageSwipeProgress * geo.size.width)

                if let target = interactivePageTarget {
                    previewPageView(target: target, size: geo.size)
                        // The preview leaves by its horizontal offset. SwiftUI's
                        // default conditional transition is an opacity fade,
                        // which makes a cancelled swipe look like a broken page.
                        .transition(.identity)
                }

                // Floating dragged icon follows the cursor.
                if let id = dragID, let item = model.items.first(where: { $0.id == id }) {
                    cellView(item, iconSize: gridMetrics(geo.size).icon)
                        .frame(width: cellW(geo.size), height: gridMetrics(geo.size).row)
                        .scaleEffect(1.18)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        .position(dragPoint)
                        .allowsHitTesting(false)
                }

                // A cross-page drop remains visible after release and glides
                // into its target slot instead of abruptly appearing there.
                if let settlement = dropSettlement,
                   let item = model.items.first(where: { $0.id == settlement.id }) {
                    cellView(item, iconSize: gridMetrics(geo.size).icon)
                        .frame(width: cellW(geo.size), height: gridMetrics(geo.size).row)
                        .scaleEffect(1.18)
                        .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
                        .position(settlement.point)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .contextMenu { pageContextMenu }
            .coordinateSpace(name: "gridRoot")
            .gesture(gridGesture(size: geo.size))
            .background(GeometryReader { g -> Color in
                let f = g.frame(in: .global)
                if gridFrame != f { DispatchQueue.main.async { gridFrame = f } }
                return Color.clear
            })
        }
    }

    private var interactivePageTarget: Int? {
        guard let target = model.pageSwipePreviewTarget,
              target != model.currentPage,
              pages.indices.contains(target) else { return nil }
        return target
    }

    private func previewPageView(target: Int, size: CGSize) -> some View {
        let progress = model.pageSwipeProgress
        let direction: CGFloat = target > model.currentPage ? 1 : -1
        let width = size.width
        return pageGridView(pages[target], pageIndex: target, size: size)
            .offset(x: direction * width - progress * width)
    }

    private func pageGridView(_ pageItems: [LaunchItem], pageIndex: Int, size: CGSize) -> some View {
        let origin = gridOrigin(size)
        let cw = cellW(size)
        let metrics = gridMetrics(size)
        let isCurrentPage = pageIndex == model.currentPage
        let isSamePageSource = dragID != nil && dragOriginPage == pageIndex && isCurrentPage
        let isCrossPageTarget = dragID != nil && dragOriginPage != pageIndex && isCurrentPage
        let visibleItems = pageItems.filter { !$0.isPlaceholder }
        let visibleCount = visibleItems.count
        // Same-page sorting always has one free slot because its source icon
        // is floating.  A cross-page insert can make a gap only when the
        // target page already has an empty slot; a full page is a swap.
        let showsInsertionGap = folderTargetID == nil &&
            (isSamePageSource || (isCrossPageTarget && visibleCount < pageItems.count))
        let displayItems: [LaunchItem] = showsInsertionGap
            ? visibleItems.filter { $0.id != dragID }
            : pageItems
        let previewSlot = Swift.min(gapSlot, displayItems.count)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { idx, item in
                let slot = showsInsertionGap && idx >= previewSlot ? idx + 1 : idx
                let col = slot % columns, row = slot / columns
                let hovering = hoverID == item.id && dragID == nil
                let settlingHere = dropSettlement?.id == item.id && dropSettlement?.page == pageIndex
                if !item.isPlaceholder && item.id != dragID && !settlingHere {
                    cellView(item, iconSize: metrics.icon)
                        .contextMenu { itemContextMenu(item) }
                        .frame(width: metrics.hitWidth, height: metrics.hitHeight)
                        .background(hoverHighlight(hovering))
                        .scaleEffect(item.id == folderTargetID ? 1.14 : (hovering ? 1.06 : 1))
                        .onHover { setHover(item.id, $0) }
                        .frame(width: cw, height: metrics.row)
                        .position(x: origin.x + cw * (CGFloat(col) + 0.5),
                                  y: origin.y + metrics.row * (CGFloat(row) + 0.5))
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: previewSlot)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                }
            }

            if showsInsertionGap {
                let preview = slotCenter(previewSlot, size: size)
                if let id = dragID, let item = model.items.first(where: { $0.id == id }) {
                    cellView(item, iconSize: metrics.icon)
                        .frame(width: cw, height: metrics.row)
                        .scaleEffect(0.90)
                        .opacity(0.42)
                        .position(preview)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: previewSlot)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.13))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1))
                        .frame(width: metrics.hitWidth, height: metrics.hitHeight)
                        .position(preview)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: previewSlot)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(_ item: LaunchItem, iconSize: CGFloat) -> some View {
        switch item {
        case .app(let path):
            if let app = model.app(path) { appIcon(app, size: iconSize) }
        case .folder(let folder):
            folderIcon(folder, size: iconSize)
        case .placeholder:
            EmptyView()
        }
    }

    // MARK: - Drag gesture

    private func gridGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("gridRoot"))
            .onChanged { value in
                if !pressClassified {
                    pressClassified = true
                    pressItemID = hitTest(value.startLocation, size: size)
                }
                guard let item = pressItemID else { return }   // background drag
                let moved = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                if dragID == nil && moved {
                    dragID = item
                    let slot = currentPageItems.firstIndex(where: { $0.id == item }) ?? 0
                    dragOriginPage = model.currentPage
                    dragOriginSlot = slot
                    gapSlot = slot
                    lastHoverSlot = slot
                    hoverItemID = nil
                }
                if dragID != nil {
                    dragPoint = value.location
                    handleDragMove(value.location, size: size)
                }
            }
            .onEnded { value in
                defer { pressItemID = nil; pressClassified = false }
                if let item = pressItemID {
                    if dragID != nil {
                        handleDragEnd()
                    } else {
                        // Launch only on a clean click — any movement (even a
                        // fast flick onChanged didn't latch as a drag) is not a tap.
                        let moved = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                        if !moved { tap(item) }
                    }
                } else {
                    let tx = value.translation.width
                    if abs(tx) < 10 && abs(value.translation.height) < 10 { onClose() }
                    else if tx <= -40 { changePage(+1) }
                    else if tx >= 40 { changePage(-1) }
                }
            }
    }

    private func hitTest(_ point: CGPoint, size: CGSize) -> String? {
        let origin = gridOrigin(size)
        let cw = cellW(size)
        let metrics = gridMetrics(size)
        let lx = point.x - origin.x, ly = point.y - origin.y
        guard lx >= 0, ly >= 0,
              lx <= CGFloat(columns) * cw, ly <= CGFloat(rows) * metrics.row else { return nil }
        let col = min(max(Int(lx / cw), 0), columns - 1)
        let row = min(max(Int(ly / metrics.row), 0), rows - 1)
        let idx = row * columns + col
        let items = currentPageItems
        guard idx < items.count, !items[idx].isPlaceholder else { return nil }
        // Only count presses on the compact icon target, so the gaps between
        // icons still close the launcher.
        let cx = cw * (CGFloat(col) + 0.5), cy = metrics.row * (CGFloat(row) + 0.5)
        guard abs(lx - cx) < metrics.hitWidth / 2, abs(ly - cy) < metrics.hitHeight / 2 else { return nil }
        return items[idx].id
    }

    private func tap(_ id: String) {
        guard let item = model.items.first(where: { $0.id == id }) else { return }
        switch item {
        case .app(let path):
            if let app = model.app(path) {
                model.recordLaunch(path)
                onLaunch(app)
            }
        case .folder(let folder): model.openFolderID = folder.id
        case .placeholder: break
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private var pageContextMenu: some View {
        Button("新建文件夹") { model.createFolder() }

        Menu("隐藏的应用") {
            if model.hiddenApps.isEmpty {
                Text("没有隐藏的应用")
            } else {
                ForEach(model.hiddenApps) { app in
                    Button {
                        model.unhideApp(app.id, toPage: model.currentPage)
                    } label: {
                        HStack(spacing: 7) {
                            CachedAppIcon(path: app.id, size: 18)
                            Text(model.displayName(app))
                        }
                    }
                }
            }
        }

        Divider()

        Menu("排序方式") {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Button(mode.title) { model.sortItems(mode) }
            }
        }

        Menu("页面") {
            Button("设为默认打开页") { model.setDefaultPage(model.currentPage) }
            if model.currentPage > 0 {
                Button("当前页前移") { _ = model.moveCurrentPage(by: -1) }
            }
            if model.currentPage + 1 < pages.count {
                Button("当前页后移") { _ = model.moveCurrentPage(by: 1) }
            }
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: LaunchItem) -> some View {
        switch item {
        case .app(let path):
            if let app = model.app(path) {
                Button("打开") {
                    model.recordLaunch(path)
                    onLaunch(app)
                }
                Button("重命名…") {
                    renameRequest = RenameRequest(target: .app(path), title: "重命名应用", initialName: model.displayName(app))
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
                Button("隐藏图标") { model.hideApp(path) }

                Menu("移动到页面") {
                    ForEach(pages.indices, id: \.self) { page in
                        Button("第 \(page + 1) 页") { model.moveItem(item.id, toPage: page) }
                            .disabled(page == model.currentPage)
                    }
                }

                Divider()

                Button("移到废纸篓…", role: .destructive) { onMoveToTrash(app) }
            }
        case .folder(let folder):
            Button("打开文件夹") { model.openFolderID = folder.id }
            Button("重命名…") {
                renameRequest = RenameRequest(target: .folder(folder.id), title: "重命名文件夹", initialName: folder.name)
            }
            Menu("移动到页面") {
                ForEach(pages.indices, id: \.self) { page in
                    Button("第 \(page + 1) 页") { model.moveItem(item.id, toPage: page) }
                        .disabled(page == model.currentPage)
                }
            }
        case .placeholder:
            EmptyView()
        }
    }

    private func handleDragMove(_ point: CGPoint, size: CGSize) {
        guard let dragID else { return }
        let origin = gridOrigin(size)
        let cw = cellW(size)
        let metrics = gridMetrics(size)
        let lx = point.x - origin.x, ly = point.y - origin.y

        // Edge → flip page.
        let edge: CGFloat = 64
        if point.x < edge { startEdgeFlip(forward: false) }
        else if point.x > size.width - edge { startEdgeFlip(forward: true) }
        else { stopEdgeFlip() }

        let col = min(max(Int(lx / cw), 0), columns - 1)
        let row = min(max(Int(ly / metrics.row), 0), rows - 1)
        let slot = min(max(row * columns + col, 0), pageSize - 1)
        let isSamePageSource = dragOriginPage == model.currentPage
        let insertionSlot: Int
        if isSamePageSource, let sourceSlot = dragOriginSlot {
            insertionSlot = slot > sourceSlot ? slot - 1 : slot
        } else {
            insertionSlot = slot
        }
        let maxInsertion = isSamePageSource ? flowItems().count : currentPageItems.filter { !$0.isPlaceholder }.count
        gapSlot = Swift.min(Swift.max(insertionSlot, 0), maxInsertion)
        guard slot < currentPageItems.count else { hoverItemID = nil; cancelDwell(); return }
        let hover = currentPageItems[slot]
        guard !hover.isPlaceholder, hover.id != dragID else { hoverItemID = nil; cancelDwell(); return }
        guard hover.id != hoverItemID else { return }   // same icon — keep dwelling

        lastHoverSlot = slot
        hoverItemID = hover.id
        folderTargetID = nil
        if dragID.hasPrefix("app:") { scheduleDwell(hover.id) }   // only apps form folders
    }

    private func handleDragEnd() {
        stopEdgeFlip()
        dwellTimer?.invalidate(); dwellTimer = nil
        if let target = folderTargetID, let src = dragID {
            withAnimation { model.makeOrJoinFolder(draggingID: src, targetID: target) }
        } else if let src = dragID {
            let isCrossPage = dragOriginPage != nil && dragOriginPage != model.currentPage
            if isCrossPage {
                model.moveItem(id: src, toPage: model.currentPage, slot: gapSlot)
                let settledSlot = model.items.firstIndex(where: { $0.id == src }).map { $0 % pageSize } ?? gapSlot
                beginDropSettlement(id: src, page: model.currentPage, slot: settledSlot, size: gridFrame.size)
            } else {
                withAnimation { model.moveItem(id: src, toPage: model.currentPage, slot: gapSlot) }
            }
            model.commitLayout()
        }
        dragID = nil
        dragOriginPage = nil
        dragOriginSlot = nil
        folderTargetID = nil
        hoverItemID = nil
    }

    private func beginDropSettlement(id: String, page: Int, slot: Int, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let destination = slotCenter(slot, size: size)
        let settlement = DropSettlement(id: id, page: page, point: dragPoint, destination: destination)
        dropSettlement = settlement
        DispatchQueue.main.async {
            guard self.dropSettlement?.id == id else { return }
            withAnimation(.easeOut(duration: 0.28)) {
                self.dropSettlement?.point = destination
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) {
            guard self.dropSettlement?.id == id else { return }
            self.dropSettlement = nil
        }
    }

    /// Clear all drag state. Needed when the drag is orphaned mid-flight (the
    /// gesture's view is torn down without onEnded): Escape, typing into
    /// search, or the window closing under the drag. Without this, the stale
    /// dragID makes the next click move the old item instead of launching.
    private func resetDragState() {
        guard dragID != nil || extDragPath != nil || pressItemID != nil else { return }
        stopEdgeFlip()
        dwellTimer?.invalidate(); dwellTimer = nil
        dragID = nil
        dragOriginPage = nil
        dragOriginSlot = nil
        dropSettlement = nil
        extDragPath = nil
        folderTargetID = nil
        hoverItemID = nil
        pressItemID = nil
        pressClassified = false
    }

    // MARK: - Drag handed off from an open folder

    private func toGrid(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - gridFrame.minX, y: global.y - gridFrame.minY)
    }

    /// The drag crossed the folder edge: take over gap/reflow/edge-flip on the
    /// page. The model is not touched yet — the app leaves its folder on drop.
    private func beginFolderDragOut(_ path: String, at global: CGPoint) {
        extDragPath = path
        dragID = "app:" + path
        dragOriginPage = nil
        dragOriginSlot = nil
        gapSlot = min(currentPageItems.count, pageSize - 1)
        lastHoverSlot = gapSlot
        hoverItemID = nil
        folderTargetID = nil
        dragPoint = toGrid(global)
        handleDragMove(dragPoint, size: gridFrame.size)
    }

    private func endFolderDragOut(folderID: String) {
        guard let path = extDragPath else { return }
        stopEdgeFlip()
        dwellTimer?.invalidate(); dwellTimer = nil
        model.removeFromFolder(folderID, path)   // puts the app back on the grid
        let id = "app:" + path
        if let target = folderTargetID {
            withAnimation { model.makeOrJoinFolder(draggingID: id, targetID: target) }
        } else {
            withAnimation { model.moveItem(id: id, toPage: model.currentPage, slot: gapSlot) }
            model.commitLayout()
        }
        dragID = nil; dragOriginPage = nil; dragOriginSlot = nil; folderTargetID = nil; hoverItemID = nil; extDragPath = nil
        model.openFolderID = nil
    }

    private func scheduleDwell(_ id: String) {
        dwellTimer?.invalidate()
        // .common mode so it fires while the mouse is held (event-tracking mode).
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            if hoverItemID == id { withAnimation { folderTargetID = id } }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func cancelDwell() {
        dwellTimer?.invalidate(); dwellTimer = nil
        if folderTargetID != nil { withAnimation { folderTargetID = nil } }
    }

    private func startEdgeFlip(forward: Bool) {
        guard dragID != nil, edgeTimer == nil else { return }
        // .common mode so it fires during the drag (event-tracking run loop).
        let timer = Timer(timeInterval: 0.7, repeats: true) { _ in
            flipDuringDrag(forward: forward)
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeTimer = timer
    }

    private func stopEdgeFlip() {
        edgeTimer?.invalidate(); edgeTimer = nil
    }

    private func flipDuringDrag(forward: Bool) {
        let next = model.currentPage + (forward ? 1 : -1)
        guard next >= 0, next < pages.count, dragID != nil else { return }
        withAnimation(LauncherMotion.page) { model.setPage(next) }
        // Keep a stable target slot on the new page; no rows reflow while the
        // pointer travels across it.
        gapSlot = 0; lastHoverSlot = 0; hoverItemID = nil; folderTargetID = nil
    }

    // MARK: - Search results

    private func searchGrid(_ results: [AppInfo]) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns),
                      spacing: 26) {
                ForEach(results) { app in
                    let hovering = hoverID == app.id
                    appIcon(app, size: model.iconSize)
                        .frame(width: searchHitWidth, height: searchHitHeight)
                        .background(hoverHighlight(hovering))
                        .scaleEffect(hovering ? 1.06 : 1)
                        .contentShape(Rectangle())
                        .onHover { setHover(app.id, $0) }
                        .animation(.easeOut(duration: 0.12), value: hovering)
                    .contextMenu { itemContextMenu(.app(app.id)) }
                    .onTapGesture {
                        model.recordLaunch(app.id)
                        onLaunch(app)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 90 + model.dockInsets.leading)
            .padding(.trailing, 90 + model.dockInsets.trailing)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }

    // MARK: - Icon views

    private func appIcon(_ app: AppInfo, size: CGFloat) -> some View {
        VStack(spacing: 7) {
            CachedAppIcon(path: app.id, size: size)
            if showAppLabels { label(model.displayName(app)) }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func folderIcon(_ folder: Folder, size: CGFloat) -> some View {
        VStack(spacing: 7) {
            // Preview icons fill from the top-left,
            // not vertically centered.
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                          spacing: 4) {
                    ForEach(model.previewIcons(folder)) { app in
                        CachedAppIcon(path: app.id, size: (size - 20) / 3)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .padding(10)
            }
            .frame(width: size, height: size)
            if showAppLabels { label(folder.name) }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(labelFontSize), weight: resolvedLabelWeight))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            // White-on-wallpaper needs the shadow; black text in light mode doesn't.
            .shadow(color: colorScheme == .dark ? .black.opacity(0.33) : .clear, radius: 2)
    }

    private var resolvedLabelWeight: Font.Weight {
        switch labelWeight {
        case "regular": return .regular
        case "semibold": return .semibold
        default: return .medium
        }
    }

    // MARK: - Pages / dots

    private func paginate(_ items: [LaunchItem]) -> [[LaunchItem]] {
        guard !items.isEmpty else { return [[]] }
        return Swift.stride(from: 0, to: items.count, by: pageSize).map {
            Array(items[$0..<Swift.min($0 + pageSize, items.count)])
        }
    }

    private func pageDots(count: Int) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<Swift.max(count, 1), id: \.self) { i in
                Circle()
                    .fill(Color.primary.opacity(i == model.currentPage ? 0.9 : 0.32))
                    .frame(width: 7, height: 7)
                    .onTapGesture { withAnimation(LauncherMotion.page) { model.setPage(i) } }
            }
        }
        .frame(height: 12)
    }

    private func changePage(_ delta: Int) {
        withAnimation(LauncherMotion.page) { model.changePage(delta) }
    }
}

private struct RenameRequest: Identifiable {
    enum Target {
        case app(String)
        case folder(String)
    }

    let id = UUID()
    let target: Target
    let title: String
    let initialName: String
}

private struct RenameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.weight(.semibold))
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("完成", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}

private struct LaunchpadGlassTint: View {
    let style: String
    let strength: Double

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(style == "glass" ? 0.10 : 0.18), location: 0),
                    .init(color: Color(red: 0.02, green: 0.10, blue: 0.24).opacity(strength), location: 0.32),
                    .init(color: Color.black.opacity(style == "glass" ? strength : Swift.min(0.88, strength + 0.15)), location: 0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [
                    Color(red: 0.52, green: 0.32, blue: 0.02).opacity(style == "glass" ? strength * 0.7 : strength * 0.45),
                    .clear
                ],
                center: UnitPoint(x: 0.50, y: 0.77),
                startRadius: 18,
                endRadius: 660
            )
        }
    }
}

private struct NativeGlassBackground: NSViewRepresentable {
    let mode: String

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        applyAppearance(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { applyAppearance(nsView) }

    private func applyAppearance(_ view: NSVisualEffectView) {
        switch mode {
        case "light": view.appearance = NSAppearance(named: .aqua)
        case "dark": view.appearance = NSAppearance(named: .darkAqua)
        default: view.appearance = nil
        }
    }
}

// MARK: - Folder overlay

private struct FolderOverlay: View {
    @ObservedObject var model: LauncherModel
    let folderID: String
    let onLaunch: (AppInfo) -> Void
    // Classic drag-out: crossing the folder edge closes the folder and hands
    // the drag to the page grid. Locations are in global coordinates.
    let onDragOut: (String, CGPoint) -> Void
    let onDragOutMoved: (CGPoint) -> Void
    let onDragOutEnded: () -> Void
    let onMoveToTrash: (AppInfo) -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var dragPath: String?
    @State private var dragPoint: CGPoint = .zero
    @State private var panelFrame: CGRect = .zero
    @State private var gridFrame: CGRect = .zero
    @State private var rootOrigin: CGPoint = .zero   // folderRoot origin, global
    @State private var draggedOut = false
    @State private var gapSlot = 0
    @State private var lastHoverSlot = 0
    @State private var hoverPath: String?
    @State private var pressPath: String?
    @State private var pressClassified = false
    @State private var hoverHL: String?
    @State private var renameRequest: RenameRequest?

    private let columns = 6
    private let cellW: CGFloat = 115
    private let cellH: CGFloat = 106

    var body: some View {
        ZStack {
            // Kept mounted (faded out) during a drag-out so the active drag
            // gesture — which dies with its view — survives until the drop.
            Color.black.opacity(draggedOut ? 0 : (colorScheme == .dark ? 0.45 : 0.25))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if dragPath == nil { model.openFolderID = nil } }

            if let folder = model.folder(folderID) {
                VStack(spacing: 18) {
                    TextField("Folder Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .focused($nameFocused)
                        .frame(maxWidth: 320)
                        .onSubmit { commitName() }
                        .onChange(of: nameFocused) { if !nameFocused { commitName() } }

                    folderGrid(folder)
                }
                .padding(34)
                .frame(maxWidth: 760)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                .background(GeometryReader { g -> Color in
                    let f = g.frame(in: .named("folderRoot"))
                    DispatchQueue.main.async { panelFrame = f }
                    return Color.clear
                })
                .opacity(draggedOut ? 0 : 1)
                .scaleEffect(draggedOut ? 0.9 : 1)
                .onAppear { name = folder.name }
                // Escape / tapping the dim background closes the overlay before
                // any focus change fires — commit the typed name on teardown.
                .onDisappear { commitName() }
            }

            // Floating dragged icon (page-sized once it has left the folder).
            if let path = dragPath, let app = model.app(path) {
                let side: CGFloat = draggedOut ? model.iconSize : 70
                CachedAppIcon(path: app.id, size: side)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    .position(dragPoint)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "folderRoot")
        .background(GeometryReader { g -> Color in
            let o = g.frame(in: .global).origin
            if rootOrigin != o { DispatchQueue.main.async { rootOrigin = o } }
            return Color.clear
        })
        .sheet(item: $renameRequest) { request in
            RenameSheet(title: request.title, initialName: request.initialName) { name in
                if case .app(let path) = request.target { model.renameApp(path, name) }
            }
        }
    }

    private func toGlobal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + rootOrigin.x, y: p.y + rootOrigin.y)
    }

    private func folderGrid(_ folder: Folder) -> some View {
        let all = folder.appPaths
        let rows = max(1, (all.count + columns - 1) / columns)
        let dragging = dragPath != nil
        let display = dragging ? all.filter { $0 != dragPath } : all
        let gap = dragging ? gapSlot : -1
        return ZStack(alignment: .topLeading) {
            ForEach(Array(display.enumerated()), id: \.element) { idx, path in
                let slot = (gap >= 0 && idx >= gap) ? idx + 1 : idx
                let col = slot % columns, row = slot / columns
                if let app = model.app(path) {
                    let hovering = hoverHL == path && dragPath == nil
                    folderIcon(app, path: path)
                        .frame(width: 98, height: 98)
                        .background(RoundedRectangle(cornerRadius: 18)
                            .fill(Color.primary.opacity(hovering ? (colorScheme == .dark ? 0.14 : 0.09) : 0)).padding(4))
                        .scaleEffect(hovering ? 1.06 : 1)
                        .onHover { if $0 { hoverHL = path } else if hoverHL == path { hoverHL = nil } }
                        .frame(width: cellW, height: cellH)
                        .position(x: cellW * (CGFloat(col) + 0.5), y: cellH * (CGFloat(row) + 0.5))
                        .animation(.easeOut(duration: 0.14), value: slot)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                }
            }
        }
        .frame(width: CGFloat(columns) * cellW, height: CGFloat(rows) * cellH)
        .background(GeometryReader { g -> Color in
            let f = g.frame(in: .named("folderRoot"))
            DispatchQueue.main.async { gridFrame = f }
            return Color.clear
        })
        .contentShape(Rectangle())
        .gesture(folderDrag(folder))
    }

    private func folderIcon(_ app: AppInfo, path: String) -> some View {
        VStack(spacing: 7) {
            CachedAppIcon(path: app.id, size: 70)
            Text(model.displayName(app)).font(.system(size: 12)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
        }
        .contextMenu {
            Button("重命名…") {
                renameRequest = RenameRequest(target: .app(path), title: "重命名应用", initialName: model.displayName(app))
            }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button("隐藏图标") { model.hideApp(path) }
            Button("移到废纸篓…", role: .destructive) { onMoveToTrash(app) }
            Divider()
            Button("Remove from Folder") { model.removeFromFolder(folderID, path) }
        }
    }

    private func folderDrag(_ folder: Folder) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("folderRoot"))
            .onChanged { value in
                if !pressClassified {
                    pressClassified = true
                    pressPath = hitFolder(value.startLocation, folder: folder)
                }
                guard let path = pressPath else { return }
                let moved = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                if dragPath == nil && moved {
                    dragPath = path
                    let slot = folder.appPaths.firstIndex(of: path) ?? 0
                    gapSlot = slot; lastHoverSlot = slot; hoverPath = nil
                }
                if dragPath != nil {
                    dragPoint = value.location
                    if draggedOut {
                        onDragOutMoved(toGlobal(value.location))
                    } else if !panelFrame.contains(value.location) {
                        // Crossed the folder edge: close the folder and hand
                        // the drag to the page grid.
                        withAnimation(.easeOut(duration: 0.18)) { draggedOut = true }
                        onDragOut(path, toGlobal(value.location))
                    } else {
                        folderMove(value.location, folder: folder)
                    }
                }
            }
            .onEnded { value in
                defer { pressPath = nil; pressClassified = false; draggedOut = false }
                guard let path = pressPath else { return }
                if dragPath == nil {
                    let moved = abs(value.translation.width) > 6 || abs(value.translation.height) > 6
                    if !moved, let app = model.app(path) { onLaunch(app) }
                } else if draggedOut {
                    onDragOutEnded()                         // page grid finalizes the drop
                } else if !panelFrame.contains(value.location) {
                    model.removeFromFolder(folderID, path)   // dropped outside → leave folder
                    model.openFolderID = nil
                } else {
                    model.moveInFolder(folderID, move: path, toIndex: gapSlot)
                }
                dragPath = nil; hoverPath = nil
            }
    }

    private func hitFolder(_ point: CGPoint, folder: Folder) -> String? {
        let lx = point.x - gridFrame.minX, ly = point.y - gridFrame.minY
        guard lx >= 0, ly >= 0 else { return nil }
        let col = min(max(Int(lx / cellW), 0), columns - 1)
        let row = max(Int(ly / cellH), 0)
        let idx = row * columns + col
        guard idx < folder.appPaths.count else { return nil }
        let cx = cellW * (CGFloat(col) + 0.5), cy = cellH * (CGFloat(row) + 0.5)
        guard abs(lx - cx) < 49, abs(ly - cy) < 49 else { return nil }   // compact icon target
        return folder.appPaths[idx]
    }

    private func folderMove(_ point: CGPoint, folder: Folder) {
        let lx = point.x - gridFrame.minX, ly = point.y - gridFrame.minY
        let flow = folder.appPaths.filter { $0 != dragPath }
        let col = min(max(Int(lx / cellW), 0), columns - 1)
        let row = max(Int(ly / cellH), 0)
        let s = min(max(row * columns + col, 0), flow.count)
        if s == gapSlot { hoverPath = nil; return }
        if s >= flow.count {                   // trailing empty area → drop at the end
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { gapSlot = flow.count }
            lastHoverSlot = flow.count; hoverPath = nil; return
        }
        let flowIdx = s < gapSlot ? s : s - 1
        guard flowIdx >= 0, flowIdx < flow.count else { hoverPath = nil; return }
        let hover = flow[flowIdx]
        guard hover != hoverPath else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { gapSlot = lastHoverSlot }
        lastHoverSlot = s
        hoverPath = hover
    }

    private func commitName() {
        model.renameFolder(folderID, name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
