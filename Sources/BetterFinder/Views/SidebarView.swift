import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @StateObject private var dropLoad = FileDropLoadController()
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewState private var dropTargetedPath: String? = nil
    @ViewState private var isPinDropTargeted = false
    @ViewState private var isFavoriteEndTargeted = false
    @ViewState private var expandedServers: Set<String> = []
    @ViewState private var draggedFavoriteID: String? = nil
    @ViewState private var favoriteDragNonce: UUID? = nil
    @ViewState private var renamingFavorite: SidebarLocationItem? = nil
    @ViewState private var favoriteTitle = ""
    @ViewState private var favoriteOpenNotice: String?
    private let favoriteDragType = UTType(importedAs: "com.betterfinder.favorite-order")

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: FinderUI.sidebarSectionGap) {
                    favoritesSection

                    VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
                        sidebarSectionHeader("Tagi")
                        ForEach(FinderTagColor.allCases) { tagColor in
                            tagRow(tagColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
                        sidebarSectionHeader("Miejsca")
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
                            ForEach(appState.localMountedVolumes) { volume in
                                volumeRow(volume)
                            }
                            ForEach(appState.networkServerGroups) { server in
                                if server.isServerKnown {
                                    networkServerRow(server)
                                } else {
                                    ForEach(server.volumes) { volume in
                                        volumeRow(volume)
                                            .help("Udział sieciowy. Nie udało się ustalić serwera.")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, FinderUI.sidebarInset)
                .padding(.top, FinderUI.chromeInset)
                .padding(.bottom, FinderUI.panelInset)
            }

            FileDropLoadingStatusView(controller: dropLoad)
            Divider()
            indexFooter
        }
        .font(FinderUI.bodyFont)
        .background(FinderUI.sidebarSurface)
        .accessibilityLabel("Pasek boczny")
        .onDisappear { dropLoad.cancel(); draggedFavoriteID = nil; favoriteDragNonce = nil }
        .alert("Nazwa w ulubionych", isPresented: Binding(
            get: { renamingFavorite != nil },
            set: { if !$0 { renamingFavorite = nil } }
        )) {
            TextField("Nazwa", text: $favoriteTitle)
            Button("Anuluj", role: .cancel) { renamingFavorite = nil }
            Button("Zapisz") {
                if let item = renamingFavorite { appState.renameFavorite(item, title: favoriteTitle) }
                renamingFavorite = nil
            }
            .disabled(favoriteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Zmienia tylko nazwę na pasku bocznym, nie nazwę folderu na dysku.")
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.compactSpacing) {
                sidebarSectionHeader("Ulubione")
                Spacer(minLength: 0)
                Menu {
                    Button("Dodaj bieżący folder", systemImage: "folder.badge.plus") {
                        appState.addBookmark(for: activeTab.currentURL)
                    }
                    .disabled(appState.favorites.contains { $0.url.path == activeTab.currentURL.path })
                    Button("Wybierz folder…", systemImage: "folder") { chooseFavoriteFolder() }
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(appState.pinnedFolderNotice != nil)
                .help("Dodaj folder do ulubionych")
                .accessibilityLabel("Dodaj folder do ulubionych")
            }
            if let notice = appState.pinnedFolderNotice {
                Text(notice)
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FinderUI.sidebarRowInset)
            }
            if let notice = favoriteOpenNotice {
                Text(notice)
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FinderUI.sidebarRowInset)
            }
            ForEach(appState.favorites) { item in sidebarLocationRow(item) }
            if !appState.favorites.isEmpty {
                Rectangle()
                    .fill(isFavoriteEndTargeted ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .onDrop(of: [favoriteDragType], isTargeted: $isFavoriteEndTargeted) { providers in
                        reorderFavorite(providers: providers, beforeID: nil)
                    }
            }
            if appState.favorites.isEmpty && appState.pinnedFolderNotice == nil {
                Button(action: chooseFavoriteFolder) {
                    Label("Dodaj folder…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, FinderUI.sidebarRowInset)
                        .frame(maxWidth: .infinity, minHeight: FinderUI.sidebarRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: false, isDropTarget: isPinDropTargeted))
        .onDrop(of: [.fileURL], isTargeted: $isPinDropTargeted) { providers in
            handlePinFolderDrop(providers: providers)
        }
    }

    private func reorderFavorite(providers: [NSItemProvider], beforeID: String?) -> Bool {
        guard providers.count == 1,
              providers[0].hasItemConformingToTypeIdentifier(favoriteDragType.identifier),
              let sourceID = draggedFavoriteID, let nonce = favoriteDragNonce,
              sourceID != beforeID, appState.pinnedFolderNotice == nil else { return false }
        // Consume the local drag session before asynchronous loading. A foreign
        // advertised type alone can never reorder a row left from a cancelled drag.
        draggedFavoriteID = nil
        favoriteDragNonce = nil
        let expected = Data("\(nonce.uuidString)\n\(sourceID)".utf8)
        providers[0].loadDataRepresentation(forTypeIdentifier: favoriteDragType.identifier) { data, error in
            guard error == nil, let data, data.count == expected.count, data == expected else { return }
            Task { @MainActor in
                guard appState.pinnedFolderNotice == nil,
                      appState.favorites.contains(where: { $0.id == sourceID }),
                      beforeID == nil || appState.favorites.contains(where: { $0.id == beforeID }) else { return }
                appState.moveFavorite(id: sourceID, beforeID: beforeID)
            }
        }
        return true
    }

    private func chooseFavoriteFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Dodaj do ulubionych"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in appState.addBookmark(for: url) }
        }
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
                    .frame(width: FinderUI.sidebarIconWidth)
                    .accessibilityHidden(true)
                Text(tagColor.displayName)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, FinderUI.sidebarRowInset)
            .frame(minHeight: FinderUI.sidebarRowHeight)
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
        let isTrash = SystemTrashNavigation.isSystemTrash(item.url, systemTrashURL: appState.systemTrashURL)
        let isSelected = !isTrash && isLocationSelected(item.url)
        let isDropTarget = dropTargetedPath == item.url.path

        return Button {
            openFavorite(item.url)
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Image(systemName: locationIcon(for: item))
                    .foregroundStyle(isSelected ? selectedTextColor : Color.accentColor)
                    .frame(width: FinderUI.sidebarIconWidth)
                    .accessibilityHidden(true)
                Text(item.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, FinderUI.sidebarRowInset)
            .frame(minHeight: FinderUI.sidebarRowHeight)
            .background(rowBackground(isSelected: isSelected, isDropTarget: isDropTarget && favoriteDragNonce == nil))
            .overlay(alignment: .top) {
                if isDropTarget && favoriteDragNonce != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isTrash ? "Otwórz Kosz w Finderze" : item.url.path)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "Bieżący folder: \(item.url.path)" : item.url.path)
        .accessibilityHint(isTrash ? "Otwórz Kosz w Finderze. Menu kontekstowe pozwala zmienić kolejność lub usunąć z ulubionych." : "Otwiera folder. Menu kontekstowe pozwala zmienić kolejność lub usunąć z ulubionych. Przeciągnięcie plików przenosi je do folderu; Option kopiuje.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Przesuń wyżej")) { appState.moveFavorite(item, by: -1) }
        .accessibilityAction(named: Text("Przesuń niżej")) { appState.moveFavorite(item, by: 1) }
        .accessibilityAction(named: Text("Usuń z ulubionych")) { appState.removeBookmark(item) }
        .contextMenu {
            if !isTrash {
                Button {
                    appState.addNewTab(at: item.url)
                } label: {
                    Label("Otwórz w nowej karcie", systemImage: "plus.square.on.square")
                }
            }
            Button {
                if isTrash { openFavorite(item.url) }
                else { NSWorkspace.shared.open(item.url) }
            } label: {
                Label(isTrash ? "Otwórz Kosz w Finderze" : "Otwórz w Finderze", systemImage: isTrash ? "trash" : "folder")
            }
            Button {
                FileOperationsManager.shared.copyPathString(item.url.path)
            } label: {
                Label("Kopiuj ścieżkę", systemImage: "doc.on.doc")
            }
            Divider()
            Button("Zmień nazwę w ulubionych…", systemImage: "pencil") {
                favoriteTitle = item.title
                renamingFavorite = item
            }
            .disabled(appState.pinnedFolderNotice != nil)
            Button("Przesuń wyżej", systemImage: "arrow.up") {
                appState.moveFavorite(item, by: -1)
            }
            .disabled(appState.pinnedFolderNotice != nil || appState.favorites.first?.id == item.id)
            Button("Przesuń niżej", systemImage: "arrow.down") {
                appState.moveFavorite(item, by: 1)
            }
            .disabled(appState.pinnedFolderNotice != nil || appState.favorites.last?.id == item.id)
            Button("Usuń z ulubionych", systemImage: "minus.circle") {
                appState.removeBookmark(item)
            }
            .disabled(appState.pinnedFolderNotice != nil)
        }
        .onDrag {
            let nonce = UUID()
            draggedFavoriteID = appState.pinnedFolderNotice == nil ? item.id : nil
            favoriteDragNonce = appState.pinnedFolderNotice == nil ? nonce : nil
            let data = Data("\(nonce.uuidString)\n\(item.id)".utf8)
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: favoriteDragType.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.fileURL, favoriteDragType], isTargeted: Binding(
            get: { dropTargetedPath == item.url.path },
            set: { targeted in
                if targeted {
                    dropTargetedPath = item.url.path
                } else if dropTargetedPath == item.url.path {
                    dropTargetedPath = nil
                }
            }
        )) { providers in
            if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(favoriteDragType.identifier) }) {
                return reorderFavorite(providers: providers, beforeID: item.id)
            }
            guard !isTrash else { return false }
            return handleDropFiles(providers: providers, into: item.url)
        }
    }

    private func networkServerRow(_ server: NetworkVolumeGroup) -> some View {
        let expanded = expandedServers.contains(server.id)
        return VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            Button {
                if expanded { expandedServers.remove(server.id) }
                else { expandedServers.insert(server.id) }
            } label: {
                HStack(spacing: FinderUI.rowSpacing) {
                    Image(systemName: "server.rack")
                        .frame(width: FinderUI.sidebarIconWidth)
                        .foregroundStyle(.secondary)
                    Text(server.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(FinderUI.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, FinderUI.sidebarRowInset)
                .frame(minHeight: FinderUI.sidebarRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(server.title) · zamontowane udziały: \(server.volumes.count)")
            .accessibilityLabel("Serwer \(server.title), \(server.volumes.count) udziałów")
            .accessibilityValue(expanded ? "Rozwinięty" : "Zwinięty")
            .accessibilityHint("Pokaż lub ukryj zamontowane udziały tego serwera")
            if expanded {
                ForEach(server.volumes) { volume in volumeRow(volume) }
                    .padding(.leading, FinderUI.panelInset)
            }
        }
    }

    private func volumeRow(_ volume: VolumeInfoItem) -> some View {
        let isSelected = isLocationSelected(volume.url)

        return VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.sidebarRowGap) {
                Button {
                    navigate(to: volume.url)
                } label: {
                    HStack(spacing: FinderUI.rowSpacing) {
                        Image(systemName: volume.isNetwork ? "folder" : (volume.isRemovable ? "externaldrive" : "internaldrive"))
                            .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                            .frame(width: FinderUI.sidebarIconWidth)
                            .accessibilityHidden(true)
                        Text(volume.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
                    .padding(.leading, FinderUI.sidebarRowInset)
                    .frame(minHeight: FinderUI.sidebarRowHeight)
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

            if !volume.isNetwork, let totalBytes = volume.totalBytes, let freeBytes = volume.freeBytes,
               let usedFraction = volume.usedFraction {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(FormatHelpers.formatBytes(freeBytes)) wolne")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: usedFraction)
                        .progressViewStyle(.linear)
                        .tint(usedFraction > 0.85 ? Color.orange : Color.accentColor)
                        .accessibilityLabel("Zajęte miejsce na \(volume.name)")
                        .accessibilityValue("\(Int(usedFraction * 100)) procent")
                }
                .padding(.leading, FinderUI.sidebarRowInset + FinderUI.sidebarIconWidth + FinderUI.rowSpacing)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
                .help("\(FormatHelpers.formatBytes(freeBytes)) wolne z \(FormatHelpers.formatBytes(totalBytes))")
            }
        }
    }

    private func sidebarSectionHeader(_ text: String) -> some View {
        Text(text)
            .font(FinderUI.captionFont.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, FinderUI.sidebarRowInset)
            .frame(height: 24, alignment: .leading)
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

    private func openFavorite(_ url: URL) {
        favoriteOpenNotice = nil
        let outcome = SystemTrashNavigation.open(url, systemTrashURL: appState.systemTrashURL,
            openInFinder: { NSWorkspace.shared.open($0) }, navigate: { navigate(to: $0) })
        if outcome == .failedToOpenFinder {
            favoriteOpenNotice = "Nie udało się otworzyć Kosza w Finderze. Otwórz go z Docka. Bieżący folder nie został zmieniony."
        }
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
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.sidebarRowGap) {
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
        .padding(.leading, FinderUI.sidebarInset + FinderUI.sidebarRowInset)
        .padding(.trailing, FinderUI.sidebarInset)
        .padding(.vertical, FinderUI.chromeInset)
    }
}
