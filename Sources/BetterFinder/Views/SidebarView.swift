import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SmartSearchPreset: Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let color: Color
    public let query: String
}

public struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @StateObject private var dropLoad = FileDropLoadController()
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewState private var dropTargetedPath: String? = nil
    @ViewState private var isPinDropTargeted = false

    private let smartPresets: [SmartSearchPreset] = [
        SmartSearchPreset(id: "recent", title: "Ostatnie 24 godziny", icon: "clock", color: .accentColor, query: "mtime:<24h"),
        SmartSearchPreset(id: "code", title: "Kod źródłowy", icon: "chevron.left.forwardslash.chevron.right", color: .accentColor, query: "type:code"),
        SmartSearchPreset(id: "gitmod", title: "Zmienione w Git", icon: "arrow.triangle.branch", color: .accentColor, query: "git:modified"),
        SmartSearchPreset(id: "large", title: "Pliki powyżej 50 MB", icon: "doc", color: .accentColor, query: "size:>50mb"),
        SmartSearchPreset(id: "docs", title: "Dokumenty i Markdown", icon: "doc.text", color: .accentColor, query: "ext:md,pdf,txt"),
        SmartSearchPreset(id: "images", title: "Obrazy i grafika", icon: "photo", color: .accentColor, query: "type:image"),
        SmartSearchPreset(id: "todo", title: "TODO w kodzie", icon: "text.magnifyingglass", color: .accentColor, query: "type:code grep:TODO")
    ]

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
                    VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                        sidebarSectionHeader("Ulubione")
                        ForEach(appState.favorites) { item in
                            sidebarLocationRow(item)
                        }
                    }

                    bookmarksSection
                    smartFoldersSection

                    VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                        sidebarSectionHeader("Tagi")
                        ForEach(FinderTagColor.allCases) { tagColor in
                            tagRow(tagColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                        sidebarSectionHeader("Dyski i woluminy")
                        if let notice = appState.volumeInventory.notice {
                            Text(notice)
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, FinderUI.rowSpacing)
                        }
                        if appState.volumeInventory.canShowEmpty {
                            Text("Brak dostępnych woluminów")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, FinderUI.rowSpacing)
                        } else {
                            ForEach(appState.mountedVolumes) { volume in
                                volumeRow(volume)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }

            FileDropLoadingStatusView(controller: dropLoad)
            Divider()
            indexFooter
        }
        .font(FinderUI.bodyFont)
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
        .accessibilityLabel("Pasek boczny")
        .onDisappear { dropLoad.cancel() }
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            HStack(spacing: FinderUI.compactSpacing) {
                sidebarSectionHeader("Przypięte foldery")
                Spacer(minLength: 0)
                sidebarActionButton(icon: "plus", label: "Przypnij bieżący folder") {
                    appState.addBookmark(for: activeTab.currentURL)
                }
                .disabled(appState.pinnedFolderNotice != nil || appState.customBookmarks.contains { $0.url.path == activeTab.currentURL.path })
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                if let notice = appState.pinnedFolderNotice {
                    Text(notice)
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, FinderUI.rowSpacing)
                }
                if appState.customBookmarks.isEmpty && appState.pinnedFolderNotice == nil {
                    Button {
                        appState.addBookmark(for: activeTab.currentURL)
                    } label: {
                        Label("Przypnij bieżący folder", systemImage: "pin")
                            .font(FinderUI.detailFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, FinderUI.rowSpacing)
                            .padding(.vertical, FinderUI.compactSpacing)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Możesz też przeciągnąć tutaj folder")
                } else {
                    ForEach(appState.customBookmarks) { item in
                        sidebarLocationRow(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isSelected: false, isDropTarget: isPinDropTargeted))
            .onDrop(of: [.fileURL], isTargeted: $isPinDropTargeted) { providers in
                handlePinFolderDrop(providers: providers)
            }
        }
    }

    private var smartFoldersSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            HStack(spacing: FinderUI.compactSpacing) {
                sidebarSectionHeader("Inteligentne foldery")
                Spacer(minLength: 0)
                if !activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sidebarActionButton(icon: "plus", label: "Zapisz bieżące wyszukiwanie") {
                        appState.saveSmartFolder(from: activeTab)
                    }
                    .disabled(activeTab.isActivatingSavedSearch || appState.isCurrentSearchSaved(in: activeTab))
                }
            }
            ForEach(smartPresets) { preset in
                smartPresetRow(title: preset.title, icon: preset.icon, color: preset.color, query: preset.query)
            }
            ForEach(appState.savedSmartFolders) { folder in
                smartPresetRow(title: folder.title, icon: "folder.badge.gearshape", color: .accentColor, query: folder.query, savedFolder: folder)
                    .contextMenu {
                        Button(role: .destructive) {
                            appState.removeSmartFolder(folder)
                        } label: {
                            Label("Usuń inteligentny folder", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private func smartPresetRow(title: String, icon: String, color: Color, query: String, savedFolder: SavedSmartFolderItem? = nil) -> some View {
        let isSelected = savedFolder.map { $0.matches(activeTab) } ?? isSearchSelected(query)

        return Button {
            if let savedFolder { appState.openSmartFolder(savedFolder) }
            else { runSearch(query) }
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? selectedTextColor : color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let savedFolder {
                        Text(savedFolder.scopeDescription)
                            .font(FinderUI.captionFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) · \(savedFolder?.scopeDescription ?? "Cały indeks") · \(query)")
        .accessibilityLabel(savedFolder.map { "\(title), \($0.scopeDescription)" } ?? title)
        .accessibilityHint("\(savedFolder?.scopeDescription ?? "Cały indeks"). Zapytanie: \(query)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tagRow(_ tagColor: FinderTagColor) -> some View {
        let query = "tag:\(tagColor.rawValue)"
        let isSelected = isSearchSelected(query)

        return Button {
            runSearch(query)
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Circle()
                    .fill(tagColor.swiftUIColor)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 10, height: 10)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(tagColor.displayName)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pokaż pliki z tagiem: \(tagColor.displayName)")
        .accessibilityLabel("Tag: \(tagColor.displayName)")
        .accessibilityHint("Wyszukuje pliki z tym tagiem w całym indeksie")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sidebarLocationRow(_ item: SidebarLocationItem) -> some View {
        let isSelected = isLocationSelected(item.url)
        let isDropTarget = dropTargetedPath == item.url.path

        return Button {
            navigate(to: item.url)
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Image(systemName: locationIcon(for: item))
                    .foregroundStyle(isSelected ? selectedTextColor : Color.accentColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(rowBackground(isSelected: isSelected, isDropTarget: isDropTarget))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.url.path)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "Bieżący folder: \(item.url.path)" : item.url.path)
        .accessibilityHint("Otwiera folder. Można tu przeciągnąć pliki; Option kopiuje zamiast przenosić.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button {
                appState.addNewTab(at: item.url)
            } label: {
                Label("Otwórz w nowej karcie", systemImage: "plus.square.on.square")
            }
            Button {
                NSWorkspace.shared.open(item.url)
            } label: {
                Label("Otwórz w Finderze", systemImage: "folder")
            }
            Button {
                FileOperationsManager.shared.copyPathString(item.url.path)
            } label: {
                Label("Kopiuj ścieżkę", systemImage: "doc.on.doc")
            }
            if item.isCustomBookmark {
                Divider()
                Button {
                    appState.removeBookmark(item)
                } label: {
                    Label("Usuń z przypiętych", systemImage: "pin.slash")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropTargetedPath == item.url.path },
            set: { targeted in
                if targeted {
                    dropTargetedPath = item.url.path
                } else if dropTargetedPath == item.url.path {
                    dropTargetedPath = nil
                }
            }
        )) { providers in
            handleDropFiles(providers: providers, into: item.url)
        }
    }

    private func volumeRow(_ volume: VolumeInfoItem) -> some View {
        let isSelected = isLocationSelected(volume.url)
        let usedFraction = min(max(volume.usedFraction, 0), 1)

        return VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            HStack(spacing: FinderUI.compactSpacing) {
                Button {
                    navigate(to: volume.url)
                } label: {
                    HStack(spacing: FinderUI.rowSpacing) {
                        Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                            .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(volume.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
                    .padding(.leading, 8)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(volume.url.path)
                .accessibilityLabel(volume.name)
                .accessibilityValue(isSelected ? "Bieżący folder: \(volume.url.path)" : volume.url.path)
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                if volume.isRemovable {
                    sidebarActionButton(icon: "eject", label: "Wysuń wolumin \(volume.name)") {
                        appState.ejectVolume(volume)
                    }
                    .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                }
            }
            .padding(.trailing, 4)
            .background(rowBackground(isSelected: isSelected))

            if volume.totalBytes > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(FormatHelpers.formatBytes(volume.freeBytes)) wolne")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: usedFraction)
                        .progressViewStyle(.linear)
                        .tint(usedFraction > 0.85 ? Color.orange : Color.accentColor)
                        .accessibilityLabel("Zajęte miejsce na \(volume.name)")
                        .accessibilityValue("\(Int(usedFraction * 100)) procent")
                }
                .padding(.leading, 34)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
                .help("\(FormatHelpers.formatBytes(volume.freeBytes)) wolne z \(FormatHelpers.formatBytes(volume.totalBytes))")
            }
        }
    }

    private func sidebarSectionHeader(_ text: String) -> some View {
        Text(text)
            .font(FinderUI.detailFont.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var selectedTextColor: Color {
        Color(nsColor: controlActiveState == .inactive ? .unemphasizedSelectedTextColor : .alternateSelectedControlTextColor)
    }

    private func rowBackground(isSelected: Bool, isDropTarget: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
            .fill(isSelected
                ? Color(nsColor: controlActiveState == .inactive ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor)
                : (isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                    .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
            }
    }

    private func locationIcon(for item: SidebarLocationItem) -> String {
        switch item.iconName {
        case "menubar.dock.rectangle": return "desktopcomputer"
        case "sparkles.rectangle.stack.fill", "bookmark.fill": return "folder"
        case "app.badge.fill": return "app"
        default: return item.iconName.replacingOccurrences(of: ".fill", with: "")
        }
    }

    private func isLocationSelected(_ url: URL) -> Bool {
        activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeTab.currentURL.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func isSearchSelected(_ query: String) -> Bool {
        activeTab.searchScope == .wholeIndex
            && activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    private func navigate(to url: URL) {
        activeTab.navigate(to: url, clearSearch: true)
    }

    private func runSearch(_ query: String) {
        if activeTab.viewMode == .wiztree {
            activeTab.viewMode = .list
        }
        activeTab.searchScope = .wholeIndex
        activeTab.searchQuery = query
        activeTab.triggerSearch()
    }

    private func handleDropFiles(providers: [NSItemProvider], into destinationURL: URL) -> Bool {
        guard FileDropLoader.accepts(providers) else { return false }
        let copyInstead = NSEvent.modifierFlags.contains(.option)
        dropLoad.begin(providers: providers, destination: destinationURL) { urls in
            FileOperationsManager.shared.handleDropURLs(urls, into: destinationURL, copyInsteadOfMove: copyInstead)
        }
        return true
    }

    private func handlePinFolderDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    appState.addBookmark(for: url)
                }
            }
        }
        return true
    }

    private var indexFooter: some View {
        VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            HStack(spacing: FinderUI.compactSpacing) {
                Text("Indeks plików")
                    .font(FinderUI.detailFont.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                sidebarActionButton(icon: "gearshape", label: "Ustawienia wyszukiwania i aplikacji") {
                    appState.showSettingsSheet = true
                }
                sidebarActionButton(icon: "arrow.clockwise", label: "Przebuduj indeks wyszukiwania") {
                    FSearchIndex.shared.startIndexing()
                }
                .disabled(appState.isIndexing)
            }
            if appState.isIndexing {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Indeksowanie…")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Indeksowanie plików")
            }
            Text("\(appState.indexedFileCount.formatted()) plików w indeksie")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(appState.indexBuildDurationMs > 0
                    ? "Ostatnie indeksowanie: \(FormatHelpers.formatLatency(appState.indexBuildDurationMs))"
                    : "Liczba plików dostępnych do wyszukiwania")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
