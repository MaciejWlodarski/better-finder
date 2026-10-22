import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct IconFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

public struct FilePaneView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ObservedObject var folderSizes = FolderSizeCache.shared
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var iconCache = FileIconCache.shared
    public let paneSide: PaneSide
    public let isFocusedPane: Bool

    @ViewState private var dragFrames: [String: CGRect] = [:]
    @ViewState private var dropTargetFolderPath: String? = nil
    @ViewState private var isPaneDropTargeted: Bool = false

    // Rubber-band / Marquee selection state in Icon view
    @ViewState private var marqueeStart: CGPoint? = nil
    @ViewState private var marqueeCurrent: CGPoint? = nil
    @ViewState private var iconFrames: [String: CGRect] = [:]

    public init(
        appState: AppState,
        pane: PaneTabState,
        paneSide: PaneSide,
        isFocusedPane: Bool
    ) {
        self.appState = appState
        self.pane = pane
        self.paneSide = paneSide
        self.isFocusedPane = isFocusedPane
    }

    public var body: some View {
        VStack(spacing: 0) {
            PathBreadcrumbBar(appState: appState, pane: pane)

            if pane.currentURL.path == "\(NSHomeDirectory())/.Trash" {
                trashActionBanner
            }

            ZStack {
                switch pane.viewMode {
                case .list:
                    listBrowserView
                case .icons:
                    iconGridBrowserView
                case .columns:
                    if pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        millerColumnsBrowserView
                    } else { listBrowserView }
                case .wiztree:
                    if pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        WizTreeAnalyzerView(appState: appState, pane: pane)
                    } else { listBrowserView }
                }

                if (pane.viewMode != .wiztree || !pane.searchQuery.isEmpty) && pane.displayedItems.isEmpty && !pane.isSearching {
                    emptyStatePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPaneDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    .padding(2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isPaneDropTargeted) { providers in
                handleDropProviders(providers: providers, into: pane.currentURL)
            }
            .contextMenu {
                paneBackgroundContextMenu
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    appState.isDualPane && isFocusedPane ? Color.accentColor.opacity(0.65) : Color.clear,
                    lineWidth: 2
                )
        )
        .coordinateSpace(name: "FilePaneSpace")
        .background(NativeFileDragSource(pane: pane, frames: dragFrames, isActive: isFocusedPane, activate: activatePane))
        .onPreferenceChange(FileDragFramesKey.self) { dragFrames = $0 }
        .simultaneousGesture(TapGesture().onEnded { activatePane() })
        .sheet(isPresented: Binding(
            get: { pane.renamingItemPath != nil },
            set: { if !$0 { pane.renamingItemPath = nil } }
        )) {
            if let item = pane.displayedItems.first(where: { $0.path == pane.renamingItemPath }) {
                RenameItemSheet(item: item, pane: pane)
            }
        }
    }

    // MARK: - 1. Native List View with Expandable Outline Tree (`▸`) & Drag/Drop

    private var listBrowserView: some View {
        GeometryReader { geometry in
            let showDate = geometry.size.width >= 480
            let showKind = geometry.size.width >= 700
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sortableHeaderButton(title: "Nazwa", field: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sortableHeaderButton(title: "Rozmiar", field: .size)
                        .frame(width: 85, alignment: .trailing)
                        .padding(.trailing, 14)
                    if showDate {
                        sortableHeaderButton(title: "Zmodyfikowano", field: .dateModified)
                            .frame(width: 145, alignment: .leading)
                    }
                    if showKind {
                        sortableHeaderButton(title: "Rodzaj", field: .kind)
                            .frame(width: 110, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(.bar)
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(pane.displayedItems.enumerated()), id: \.element.id) { index, item in
                                fileListRow(item: item, index: index, showDate: showDate, showKind: showKind)
                                    .id(item.path)
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: pane.selectionCursorPath) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
            }
        }
    }

    private func sortableHeaderButton(title: String, field: SortField) -> some View {
        Button {
            if pane.sortField == field {
                pane.sortAscending.toggle()
            } else {
                pane.sortField = field
                pane.sortAscending = (field == .name || field == .kind)
            }
            pane.applySortChange()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: pane.sortField == field ? .bold : .medium))
                    .foregroundStyle(pane.sortField == field ? .primary : .secondary)
                if pane.sortField == field {
                    Image(systemName: pane.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileListRow(item: FileItem, index: Int, showDate: Bool, showKind: Bool) -> some View {
        let isSelected = pane.selectedPaths.contains(item.path)
        let isCutItem = fileOps.isCut(item.path)
        let isFolderDropTarget = (dropTargetFolderPath == item.path)
        let showSubpath = !pane.searchQuery.isEmpty && pane.searchScope != .currentFolder

        return HStack(spacing: 0) {
            // Tree Indentation + Disclosure Triangle (`▸` / `▾`) + Icon + Name + Tags
            HStack(spacing: 6) {
                if item.treeDepth > 0 {
                    Spacer()
                        .frame(width: CGFloat(item.treeDepth) * 18)
                }

                // Outline disclosure triangle for folders when browsing directory
                if pane.searchQuery.isEmpty {
                    if item.isDirectory && item.fileExtension.lowercased() != "app" {
                        Button {
                            pane.toggleFolderExpansion(for: item)
                        } label: {
                            Image(systemName: pane.isExpanded(item.path) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer()
                            .frame(width: 14)
                    }
                }

                Image(nsImage: FileIconCache.shared.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .opacity(item.isHidden || isCutItem ? 0.5 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: item.isDirectory ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.white : (item.isHidden ? Color.secondary : Color.primary))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Native macOS Color Tag Dots
                        if !item.tags.isEmpty {
                            HStack(spacing: 3) {
                                ForEach(item.tags) { tag in
                                    Circle()
                                        .fill(tag.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                }
                            }
                        }

                        if item.isSymlink {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        }

                        if let git = item.gitStatus {
                            gitStatusBadge(git, isSelected: isSelected)
                        }
                    }

                    if showSubpath {
                        Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }

                    if let grep = item.grepMatch {
                        HStack(spacing: 5) {
                            Text("L\(grep.lineNumber):")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                            Text(grep.lineText)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color.white.opacity(0.15) : Color.accentColor.opacity(0.09))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Size Column
            Group {
                if item.isDirectory {
                    if let folderBytes = folderSizes.size(for: item.path) {
                        Text(FormatHelpers.formatBytes(folderBytes))
                    } else {
                        Text("—")
                            .onAppear {
                                folderSizes.requestSizeIfNeeded(for: item.path)
                            }
                    }
                } else {
                    Text(FormatHelpers.formatBytes(item.size))
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
            .frame(width: 85, alignment: .trailing)
            .padding(.trailing, 14)

            if showDate {
                Text(FormatHelpers.formatDate(item.modificationDate))
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 145, alignment: .leading)
            }
            if showKind {
                Text(item.kindDisplayString)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, showSubpath || item.grepMatch != nil ? 6 : 5)
        .opacity(isCutItem ? 0.5 : 1.0)
        .background(
            isSelected ? Color.accentColor : (isFolderDropTarget ? Color.accentColor.opacity(0.18)
                : (index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isFolderDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: FileDragFramesKey.self,
                    value: [item.path: geometry.frame(in: .named("FilePaneSpace"))])
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropTargetFolderPath == item.path },
            set: { targeted in dropTargetFolderPath = (targeted && item.isDirectory) ? item.path : nil }
        )) { providers in
            let targetDir = item.isDirectory ? item.url : pane.currentURL
            return handleDropProviders(providers: providers, into: targetDir)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                openOrEnterItem(item)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                handleSelectionClick(item: item)
            }
        )
        .contextMenu {
            itemContextMenu(for: item)
        }
    }

    // MARK: - 2. Native Icon Grid View with Rubber-Band Marquee Selection & Drag/Drop

    private var marqueeRect: CGRect? {
        guard let s = marqueeStart, let c = marqueeCurrent else { return nil }
        return CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
    }

    private var iconGridBrowserView: some View {
        let iconDim = CGFloat(appState.iconGridSize)
        let cellWidth = max(96, iconDim + 44)
        let columns = [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 24), spacing: 14)]
        return ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(pane.displayedItems) { item in
                        let isSelected = pane.selectedPaths.contains(item.path)
                        let isCutItem = fileOps.isCut(item.path)
                        let isFolderDropTarget = (dropTargetFolderPath == item.path)

                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: iconCache.icon(for: item, preferThumbnail: true))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: iconDim, height: iconDim)
                                    .clipShape(RoundedRectangle(cornerRadius: item.supportsRichThumbnail ? 6 : 0))
                                    .opacity(item.isHidden || isCutItem ? 0.5 : 1.0)

                                if let git = item.gitStatus {
                                    gitStatusBadge(git, isSelected: false)
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected || isFolderDropTarget ? Color.accentColor.opacity(0.22) : Color.clear)
                            )

                            HStack(spacing: 3) {
                                if !item.tags.isEmpty {
                                    ForEach(item.tags.prefix(3)) { tag in
                                        Circle()
                                            .fill(tag.swiftUIColor)
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                Text(item.name)
                                    .font(.system(size: 12, weight: item.isDirectory ? .medium : .regular))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )

                            Text(
                                item.isDirectory
                                ? (folderSizes.size(for: item.path).map(FormatHelpers.formatBytes) ?? "Folder")
                                : FormatHelpers.formatBytes(item.size)
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .onAppear {
                                if item.isDirectory {
                                    folderSizes.requestSizeIfNeeded(for: item.path)
                                }
                            }
                        }
                        .frame(width: cellWidth)
                        .padding(6)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: IconFramePreferenceKey.self,
                                    value: [item.path: geo.frame(in: .named("IconGridSpace"))]
                                )
                                .preference(key: FileDragFramesKey.self,
                                    value: [item.path: geo.frame(in: .named("FilePaneSpace"))])
                            }
                        )
                        .contentShape(Rectangle())
                        .onDrop(of: [.fileURL], isTargeted: Binding(
                            get: { dropTargetFolderPath == item.path },
                            set: { targeted in dropTargetFolderPath = (targeted && item.isDirectory) ? item.path : nil }
                        )) { providers in
                            let targetDir = item.isDirectory ? item.url : pane.currentURL
                            return handleDropProviders(providers: providers, into: targetDir)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                openOrEnterItem(item)
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                handleSelectionClick(item: item)
                            }
                        )
                        .contextMenu {
                            itemContextMenu(for: item)
                        }
                    }
                }
                .padding(16)

                // Rubber-band Marquee Selection Box Overlay
                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            Rectangle()
                                .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "IconGridSpace")
            .onPreferenceChange(IconFramePreferenceKey.self) { frames in
                iconFrames = frames
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("IconGridSpace"))
                    .onChanged { value in
                        if marqueeStart == nil {
                            activatePane()
                            pane.focusFilePaneTrigger &+= 1
                            marqueeStart = value.startLocation
                        }
                        marqueeCurrent = value.location
                        if let box = marqueeRect {
                            var selected = Set<String>()
                            for (path, frame) in iconFrames where box.intersects(frame) {
                                selected.insert(path)
                            }
                            pane.selectedPaths = selected
                        }
                    }
                    .onEnded { _ in
                        marqueeStart = nil
                        marqueeCurrent = nil
                    }
            )
        }
    }

    // MARK: - 3. Miller Columns View

    private var millerColumnsBrowserView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(pane.columnTrailURLs, id: \.path) { colURL in
                    MillerColumnSingleListView(
                        columnURL: colURL,
                        pane: pane,
                        onSelectDirectory: { selectedDirURL in
                            pane.navigate(to: selectedDirURL)
                        },
                        onSelectFile: { fileItem in
                            activatePane()
                            let parent = fileItem.url.deletingLastPathComponent()
                            if pane.currentURL.path != parent.path { pane.navigate(to: parent) }
                            pane.select(fileItem)
                        }
                    )
                    .frame(width: 245)
                    Divider()
                }
            }
        }
    }

    // MARK: - Trash Banner (`~/.Trash`)

    private var trashActionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Kosz systemowy (\(pane.displayedItems.count) elementów)")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if !pane.displayedItems.isEmpty {
                Button("Opróżnij Kosz...", role: .destructive) {
                    fileOps.emptySystemTrash()
                    pane.reloadDirectory()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Empty State

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: pane.searchQuery.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(pane.searchQuery.isEmpty ? "Ten folder jest pusty" : "Brak pasujących plików")
                .font(.system(size: 17, weight: .semibold))
            Text(pane.searchQuery.isEmpty ? "Przeciągnij tutaj pliki lub utwórz nowy folder."
                 : "Zmień zapytanie, usuń filtry lub poszerz zakres wyszukiwania.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if pane.searchQuery.isEmpty {
                Button("Nowy folder…") { activatePane(); appState.showNewFolderSheet = true }
            } else {
                Button("Wyczyść wyszukiwanie") { pane.clearSearch() }
            }
        }
        .padding(24)
    }

    // MARK: - Git Badge

    private func gitStatusBadge(_ git: GitFileStatus, isSelected: Bool) -> some View {
        let color: Color = {
            switch git {
            case .modified: return .orange
            case .staged: return .green
            case .untracked: return .blue
            case .deleted: return .red
            case .renamed: return .purple
            }
        }()
        return Text(git.rawValue)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.white.opacity(0.22) : color.opacity(0.15))
            )
            .help("Git: \(git.badgeDescription)")
    }

    // MARK: - Drag & Drop Handler

    private func handleDropProviders(providers: [NSItemProvider], into destinationURL: URL) -> Bool {
        guard FileDropLoader.accepts(providers) else { return false }
        activatePane()
        let copyInstead = NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            let urls = await FileDropLoader.urls(from: providers)
            fileOps.handleDropURLs(urls, into: destinationURL, copyInsteadOfMove: copyInstead)
        }
        return true
    }

    private func activatePane() {
        appState.activePaneSide = paneSide
    }

    private func handleSelectionClick(item: FileItem) {
        activatePane()
        let flags = NSEvent.modifierFlags
        pane.select(item, extending: flags.contains(.shift), toggling: flags.contains(.command))
    }

    private func openOrEnterItem(_ item: FileItem) {
        if item.isDirectory && item.fileExtension.lowercased() != "app" {
            pane.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Context Menus (Open With, Share, Color Tags, Extract Archive, etc.)

    @ViewBuilder
    private func itemContextMenu(for item: FileItem) -> some View {
        let targetItems: [FileItem] = pane.selectedPaths.contains(item.path) ? pane.selectedItems : [item]

        Button {
            openOrEnterItem(item)
        } label: {
            Label(item.isDirectory ? "Otwórz folder" : "Otwórz", systemImage: "arrow.up.forward.app")
        }

        if !item.isDirectory {
            OpenWithApplicationsMenu(item: item)
        }

        Button {
            activatePane()
            pane.select(item)
            appState.toggleQuickLook()
        } label: {
            Label("Quick Look (Spacja)", systemImage: "eye")
        }

        if !pane.searchQuery.isEmpty {
            Button {
                let parentURL = URL(fileURLWithPath: item.parentPath, isDirectory: true)
                pane.searchQuery = ""
                pane.navigate(to: parentURL)
                pane.selectedPaths = [item.path]
            } label: {
                Label("Pokaż w folderze nadrzędnym", systemImage: "folder.fill.badge.person.crop")
            }
        }

        Divider()

        // Native macOS Color Tags Menu
        Menu("Tagi macOS") {
            ForEach(FinderTagColor.allCases) { tagColor in
                let hasTag = item.tags.contains(tagColor)
                Button {
                    fileOps.toggleTag(tagColor, for: targetItems)
                    pane.reloadDirectory()
                } label: {
                    Label(
                        hasTag ? "✓ \(tagColor.displayName)" : tagColor.displayName,
                        systemImage: hasTag ? "checkmark.circle.fill" : "circle.fill"
                    )
                }
            }
            if !item.tags.isEmpty {
                Divider()
                Button("Usuń wszystkie tagi", role: .destructive) {
                    fileOps.clearTags(for: targetItems)
                    pane.reloadDirectory()
                }
            }
        }

        Button {
            fileOps.showShareSheet(for: targetItems)
        } label: {
            Label("Udostępnij (AirDrop, Wiadomości...)", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            fileOps.cutItems(targetItems)
        } label: {
            Label("Wytnij (Cmd+X)", systemImage: "scissors")
        }

        Button {
            fileOps.copyItems(targetItems)
        } label: {
            Label("Kopiuj (Cmd+C)", systemImage: "doc.on.doc")
        }

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Wklej tutaj (Cmd+V)", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            activatePane()
            pane.select(item)
            pane.renamingItemPath = item.path
        } label: {
            Label("Zmień nazwę...", systemImage: "pencil")
        }

        Button {
            _ = fileOps.duplicateItems(targetItems)
            pane.reloadDirectory()
        } label: {
            Label("Duplikuj (Cmd+D)", systemImage: "plus.square.on.square")
        }

        Button {
            fileOps.compressItems(targetItems, in: pane.currentURL)
        } label: {
            Label("Kompresuj do ZIP", systemImage: "doc.zipper")
        }

        if item.isExtractableArchive {
            Button {
                fileOps.extractArchive(item)
            } label: {
                Label("Rozpakuj archiwum tutaj", systemImage: "archivebox.fill")
            }
        }

        Divider()

        Button {
            fileOps.copyPaths(targetItems)
        } label: {
            Label("Kopiuj pełną ścieżkę (Cmd+Opt+C)", systemImage: "link")
        }

        Button {
            fileOps.openInTerminal(at: item.url)
        } label: {
            Label("Otwórz w Terminalu", systemImage: "terminal")
        }

        Button {
            fileOps.openInCodeEditor(at: item.url)
        } label: {
            Label("Otwórz w edytorze kodu", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        if item.isDirectory {
            Button {
                appState.addBookmark(for: item.url)
            } label: {
                Label("Przypnij do paska bocznego", systemImage: "bookmark")
            }
        }

        Button {
            fileOps.revealInAppleFinder(targetItems)
        } label: {
            Label("Pokaż w klasycznym Finderze", systemImage: "macwindow")
        }

        Divider()

        Button(role: .destructive) {
            fileOps.moveToTrash(targetItems)
            pane.reloadDirectory()
        } label: {
            Label("Przenieś do Kosza", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var paneBackgroundContextMenu: some View {
        Button {
            activatePane()
            appState.showNewFolderSheet = true
        } label: {
            Label("Nowy folder (Cmd+Shift+N)...", systemImage: "folder.badge.plus")
        }

        Button {
            activatePane()
            appState.showNewFileSheet = true
        } label: {
            Label("Nowy plik (Cmd+Opt+N)...", systemImage: "doc.badge.plus")
        }

        Divider()

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Wklej tutaj (Cmd+V)", systemImage: "doc.on.clipboard")
        }

        if fileOps.canUndo {
            Button {
                fileOps.undoLastOperation()
            } label: {
                Label("\(fileOps.undoLabel) (Cmd+Z)", systemImage: "arrow.uturn.backward")
            }
        }

        Button {
            pane.reloadDirectory()
        } label: {
            Label("Odśwież widok", systemImage: "arrow.clockwise")
        }

        Divider()

        Button {
            appState.showTerminalDrawer.toggle()
        } label: {
            Label("Wbudowany panel Terminala (Ctrl+`)", systemImage: "terminal.fill")
        }

        Button {
            fileOps.openInTerminal(at: pane.currentURL)
        } label: {
            Label("Otwórz bieżący folder w Terminalu", systemImage: "terminal")
        }
    }
}

private struct MillerColumnSingleListView: View {
    let columnURL: URL
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var iconCache = FileIconCache.shared
    let onSelectDirectory: (URL) -> Void
    let onSelectFile: (FileItem) -> Void

    @ViewState private var items: [FileItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(columnURL.lastPathComponent.isEmpty ? "/" : columnURL.lastPathComponent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        let isInTrail = pane.columnTrailURLs.contains(where: { $0.path == item.path }) ||
                                        pane.selectedPaths.contains(item.path)
                        HStack(spacing: 7) {
                            Image(nsImage: FileIconCache.shared.icon(for: item))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(item.name)
                                .font(.system(size: 12))
                                .foregroundStyle(isInTrail ? Color.white : Color.primary)
                                .lineLimit(1)
                            Spacer()
                            let tags = pane.cachedTags(for: item.path) ?? item.tags
                            if let firstTag = tags.first {
                                Circle()
                                    .fill(firstTag.swiftUIColor)
                                    .frame(width: 7, height: 7)
                            }
                            if item.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isInTrail ? Color.white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isInTrail ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onDrag {
                            NSItemProvider(object: item.url as NSURL)
                        }
                        .onTapGesture {
                            if item.isDirectory && item.fileExtension.lowercased() != "app" {
                                onSelectDirectory(item.url)
                            } else {
                                onSelectFile(item)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .onAppear {
            loadColumn()
        }
        .onChange(of: pane.showHiddenFiles) { _, _ in loadColumn() }
        .onChange(of: pane.directoryRevision) { _, _ in loadColumn() }
        .onChange(of: columnURL) { _, _ in loadColumn() }
    }

    private func loadColumn() {
        let entries = BulkCrawler.readDirectoryFast(at: columnURL.path, includeHidden: pane.showHiddenFiles)
        items = entries.map { $0.toFileItem(loadTags: false) }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        pane.loadTagMetadataIfNeeded(for: items)
    }
}
