import Foundation
import AppKit
import QuickLookUI

public enum PaneSide: String, Sendable {
    case left
    case right
}

public struct SidebarLocationItem: Identifiable, Hashable {
    public var id: String { url.path }
    public let title: String
    public let iconName: String
    public let url: URL
    public let isCustomBookmark: Bool
}

public struct VolumeInfoItem: Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isRemovable: Bool

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // A test executable must never restore or write the user's real preferences,
    // enumerate their home, or automatically start the indexer.
    private static let preferences: UserDefaults = {
        #if BETTERFINDER_TESTING
        guard let suite = UserDefaults(suiteName: "com.betterfinder.tests.\(UUID().uuidString)") else {
            fatalError("Could not create isolated test preferences")
        }
        return suite
        #else
        return UserDefaults.standard
        #endif
    }()

    private static var homeDirectoryURL: URL {
        #if BETTERFINDER_TESTING
        guard let root = ProcessInfo.processInfo.environment["BETTERFINDER_TEST_ROOT"],
              root.hasPrefix("/"), FileManager.default.fileExists(atPath: root) else {
            fatalError("BETTERFINDER_TEST_ROOT must identify an isolated test directory")
        }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    @Published public var tabs: [PaneTabState] = []
    @Published public var activeTabId: UUID

    // Dual-pane mode
    @Published public var isDualPane: Bool = false {
        didSet {
            Self.preferences.set(isDualPane, forKey: "bf.isDualPane")
            if !isDualPane { rightPane.cancelPendingSavedSearches() }
        }
    }
    @Published public var rightPane: PaneTabState
    @Published public var activePaneSide: PaneSide = .left

    // UI Panels & Modals
    @Published public var showSidebar: Bool = true {
        didSet { Self.preferences.set(showSidebar, forKey: "bf.showSidebar") }
    }
    @Published public private(set) var recentlyClosedTabs: [PaneTabState] = []
    @Published public var showInspector: Bool = false {
        didSet { Self.preferences.set(showInspector, forKey: "bf.showInspector") }
    }
    @Published public var iconGridSize: Double = 64.0 {
        didSet { Self.preferences.set(iconGridSize, forKey: "bf.iconGridSize") }
    }
    @Published public var showTerminalDrawer: Bool = false
    @Published public var showQuickFSearchModal: Bool = false
    @Published public var showNewFileSheet: Bool = false
    @Published public var showNewFolderSheet: Bool = false
    @Published public var showCompareSheet: Bool = false
    @Published public var showSettingsSheet: Bool = false
    @Published public var showFSearchHelpPopover: Bool = false
    @Published public var focusSearchFieldTrigger: Int = 0

    // Index Status
    @Published public var indexedFileCount: Int = 0
    @Published public var indexBuildDurationMs: Double = 0
    @Published public var isIndexing: Bool = true

    // Sidebar Locations & Smart Folders
    @Published public var favorites: [SidebarLocationItem] = []
    @Published public var customBookmarks: [SidebarLocationItem] = []
    @Published public var savedSmartFolders: [SavedSmartFolderItem] = []
    private var savedSearchArchive: SavedSearchArchive? = SavedSearchArchive()
    private var savedSearchLaunchSerials: [UUID: UInt64] = [:]
    @Published public var mountedVolumes: [VolumeInfoItem] = []

    public var activeTab: PaneTabState {
        if isDualPane && activePaneSide == .right {
            return rightPane
        }
        return tabs.first(where: { $0.id == activeTabId }) ?? tabs[0]
    }

    public var leftTab: PaneTabState {
        tabs.first(where: { $0.id == activeTabId }) ?? tabs[0]
    }

    private init() {
        let defaults = Self.preferences
        let homeURL = Self.homeDirectoryURL
        let devLabPath = homeURL.appendingPathComponent("dev").path
        let defaultStartURL = FileManager.default.fileExists(atPath: devLabPath)
            ? URL(fileURLWithPath: devLabPath, isDirectory: true)
            : homeURL

        // Restore persisted tabs or create default
        var restoredTabs: [PaneTabState] = []
        if let savedPaths = defaults.stringArray(forKey: "bf.openTabPaths") {
            for p in savedPaths where FileManager.default.fileExists(atPath: p) {
                restoredTabs.append(PaneTabState(initialURL: URL(fileURLWithPath: p, isDirectory: true)))
            }
        }
        if restoredTabs.isEmpty {
            restoredTabs = [PaneTabState(initialURL: defaultStartURL)]
        }

        let secondPane = PaneTabState(initialURL: homeURL)
        self.tabs = restoredTabs
        self.activeTabId = restoredTabs[0].id
        self.rightPane = secondPane

        if defaults.object(forKey: "bf.showSidebar") != nil {
            self.showSidebar = defaults.bool(forKey: "bf.showSidebar")
        }
        let restoredActiveIndex = defaults.integer(forKey: "bf.activeTabIndex")
        if restoredTabs.indices.contains(restoredActiveIndex) {
            self.activeTabId = restoredTabs[restoredActiveIndex].id
        }
        if defaults.object(forKey: "bf.showInspector") != nil {
            self.showInspector = defaults.bool(forKey: "bf.showInspector")
        }
        if defaults.object(forKey: "bf.isDualPane") != nil {
            self.isDualPane = defaults.bool(forKey: "bf.isDualPane")
        }
        let savedIconSize = defaults.double(forKey: "bf.iconGridSize")
        if savedIconSize >= 40 && savedIconSize <= 140 {
            self.iconGridSize = savedIconSize
        }

        setupSidebarLocations()
        loadPersistedBookmarksAndSmartFolders()
        #if !BETTERFINDER_TESTING
        refreshMountedVolumes()
        #endif
        setupIndexCallbacks()
    }

    private func setupIndexCallbacks() {
        FSearchIndex.shared.onIndexUpdated = { count, durationMs in
            Task { @MainActor in
                self.indexedFileCount = count
                self.indexBuildDurationMs = durationMs
                self.isIndexing = false
                for tab in self.tabs + [self.rightPane] where !tab.searchQuery.isEmpty {
                    tab.triggerSearch()
                }
            }
        }
        FSearchIndex.shared.onDirectoryChangedOnDisk = { changedDirs in
            Task { @MainActor in
                self.handleDirectoryChanges(changedDirs)
            }
        }
        #if !BETTERFINDER_TESTING
        FSearchIndex.shared.startIndexing()
        #else
        isIndexing = false
        #endif
    }

    public func handleDirectoryChanges(_ changedDirs: Set<String>) {
        // Invalidate shared caches even when no current pane displays the folder.
        for path in changedDirs {
            FolderSizeCache.shared.invalidate(containing: path)
            FileIconCache.shared.invalidate(containing: path)
        }
        for tab in tabs + [rightPane] where tab.isAffectedByDirectoryChanges(changedDirs) {
            tab.refresh()
        }
    }

    public func setupSidebarLocations() {
        let home = Self.homeDirectoryURL.path
        let iCloudPath = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        let trashPath = "\(home)/.Trash"

        var candidates: [(String, String, String)] = [
            ("Dom", "house.fill", home),
            ("Biurko", "menubar.dock.rectangle", "\(home)/Desktop"),
            ("Dokumenty", "doc.fill", "\(home)/Documents"),
            ("Pobrane", "arrow.down.circle.fill", "\(home)/Downloads")
        ]
        if FileManager.default.fileExists(atPath: iCloudPath) {
            candidates.append(("iCloud Drive", "icloud.fill", iCloudPath))
        }
        candidates.append(contentsOf: [
            ("Projekty", "hammer.fill", "\(home)/dev"),
            ("Kosz", "trash.fill", trashPath)
        ])
        #if !BETTERFINDER_TESTING
        candidates.append(("Aplikacje", "app.badge.fill", "/Applications"))
        #endif

        var favs: [SidebarLocationItem] = []
        for (title, icon, path) in candidates {
            if FileManager.default.fileExists(atPath: path) {
                favs.append(SidebarLocationItem(
                    title: title,
                    iconName: icon,
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isCustomBookmark: false
                ))
            }
        }
        self.favorites = favs
    }

    // MARK: - UserDefaults Persistence for Bookmarks, Smart Folders & Tabs

    private func loadPersistedBookmarksAndSmartFolders() {
        let defaults = Self.preferences
        if let paths = defaults.stringArray(forKey: "bf.customBookmarks") {
            customBookmarks = paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                let url = URL(fileURLWithPath: path, isDirectory: true)
                return SidebarLocationItem(title: url.lastPathComponent, iconName: "bookmark.fill", url: url, isCustomBookmark: true)
            }
        }
        if let data = defaults.data(forKey: "bf.savedSmartFolders") {
            savedSearchArchive = try? SavedSearchArchive(data: data)
            savedSmartFolders = savedSearchArchive?.items ?? []
        }
    }

    public func persistTabsState() {
        let paths = tabs.map { $0.currentURL.path }
        Self.preferences.set(paths, forKey: "bf.openTabPaths")
        Self.preferences.set(tabs.firstIndex(where: { $0.id == activeTabId }) ?? 0, forKey: "bf.activeTabIndex")
    }

    public func addBookmark(for url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        guard !customBookmarks.contains(where: { $0.url.path == url.path }) else { return }
        customBookmarks.append(SidebarLocationItem(
            title: url.lastPathComponent,
            iconName: "bookmark.fill",
            url: url,
            isCustomBookmark: true
        ))
        Self.preferences.set(customBookmarks.map { $0.url.path }, forKey: "bf.customBookmarks")
    }

    public func removeBookmark(_ item: SidebarLocationItem) {
        customBookmarks.removeAll { $0.id == item.id }
        Self.preferences.set(customBookmarks.map { $0.url.path }, forKey: "bf.customBookmarks")
    }

    public func isCurrentSearchSaved(in pane: PaneTabState) -> Bool {
        let candidate = SavedSmartFolderItem.capture(from: pane)
        return savedSmartFolders.contains { $0.hasSameSearch(as: candidate) }
    }

    public func saveSmartFolder(from pane: PaneTabState, title: String? = nil) {
        let item = SavedSmartFolderItem.capture(from: pane, title: title)
        guard !item.query.isEmpty else { return }
        guard !savedSmartFolders.contains(where: { $0.hasSameSearch(as: item) }) else { return }
        guard persistSmartFolders(savedSmartFolders + [item]) else { return }
        FileOperationsManager.shared.lastStatusMessage = "Zapisano inteligentny folder: \(item.title)"
    }

    public func openSmartFolder(_ item: SavedSmartFolderItem) {
        let pane = activeTab
        pane.cancelPendingSavedSearches()
        let serial = (savedSearchLaunchSerials[pane.id] ?? 0) &+ 1
        savedSearchLaunchSerials[pane.id] = serial
        let context = pane.savedSearchActivationContext
        Task { @MainActor in
            guard self.savedSearchLaunchSerials[pane.id] == serial,
                  pane.savedSearchActivationContext == context else { return }
            do {
                guard try await pane.applySavedSearch(item, shouldApply: { [weak self, weak pane] in
                    guard let self, let pane else { return false }
                    return self.savedSearchLaunchSerials[pane.id] == serial &&
                        (self.tabs.contains { $0.id == pane.id } || (self.isDualPane && self.rightPane.id == pane.id))
                }) else { return }
                guard self.activeTab.id == pane.id else { return }
                FileOperationsManager.shared.lastStatusMessage = "Wyszukiwanie: \(item.title) · \(item.scopeDescription)"
            } catch {
                guard self.activeTab.id == pane.id else { return }
                FileOperationsManager.shared.lastStatusMessage = error.localizedDescription
            }
        }
    }

    public func removeSmartFolder(_ item: SavedSmartFolderItem) {
        _ = persistSmartFolders(savedSmartFolders.filter { $0.id != item.id }, removingID: item.id)
    }

    private func persistSmartFolders(_ items: [SavedSmartFolderItem], removingID: String? = nil) -> Bool {
        guard let archive = savedSearchArchive,
              let data = try? archive.encoded(replacingItems: items, removingID: removingID) else {
            FileOperationsManager.shared.lastStatusMessage = "Nie zapisano zmiany: dane inteligentnych folderów są uszkodzone lub nieobsługiwane. Oryginalny zapis pozostał nietknięty."
            return false
        }
        Self.preferences.set(data, forKey: "bf.savedSmartFolders")
        savedSmartFolders = items
        savedSearchArchive = try? SavedSearchArchive(data: data)
        return true
    }

    // MARK: - Volumes & Eject (`⏏`)

    public func refreshMountedVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return
        }
        var vols: [VolumeInfoItem] = []
        for url in urls {
            if let vals = try? url.resourceValues(forKeys: Set(keys)) {
                let name = vals.volumeName ?? url.lastPathComponent
                let total = Int64(vals.volumeTotalCapacity ?? 0)
                let avail = vals.volumeAvailableCapacityForImportantUsage ?? 0
                let isRemovable = (vals.volumeIsRemovable == true) ||
                                  (vals.volumeIsEjectable == true) ||
                                  (vals.volumeIsInternal == false && url.path != "/")
                vols.append(VolumeInfoItem(
                    name: name,
                    url: url,
                    totalBytes: total,
                    freeBytes: avail,
                    isRemovable: isRemovable
                ))
            }
        }
        self.mountedVolumes = vols
    }

    public func ejectVolume(_ vol: VolumeInfoItem) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: vol.url)
            FileOperationsManager.shared.lastStatusMessage = "Wysunięto wolumin \(vol.name)"
            refreshMountedVolumes()
        } catch {
            FileOperationsManager.shared.lastStatusMessage = "Nie można wysunąć \(vol.name): \(error.localizedDescription)"
        }
    }

    // MARK: - Tab Management

    public func addNewTab(at url: URL? = nil) {
        let targetURL = url ?? activeTab.currentURL
        let newTab = PaneTabState(initialURL: targetURL)
        newTab.viewMode = activeTab.viewMode
        newTab.showHiddenFiles = activeTab.showHiddenFiles
        newTab.sortField = activeTab.sortField
        newTab.sortAscending = activeTab.sortAscending
        newTab.foldersOnTop = activeTab.foldersOnTop
        newTab.searchScope = activeTab.searchScope
        newTab.fuzzyEnabled = activeTab.fuzzyEnabled
        newTab.refresh()
        tabs.append(newTab)
        activeTabId = newTab.id
        activePaneSide = .left
        persistTabsState()
    }

    public func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].cancelPendingSavedSearches()
            savedSearchLaunchSerials.removeValue(forKey: id)
            recentlyClosedTabs.append(tabs[idx])
            if recentlyClosedTabs.count > 10 { recentlyClosedTabs.removeFirst() }
            tabs.remove(at: idx)
            if activeTabId == id {
                let nextIdx = min(idx, tabs.count - 1)
                activeTabId = tabs[nextIdx].id
            }
            persistTabsState()
        }
    }

    public func reopenClosedTab() {
        guard let tab = recentlyClosedTabs.popLast() else { return }
        tabs.append(tab)
        activeTabId = tab.id
        activePaneSide = .left
        tab.refresh()
        persistTabsState()
    }

    public func selectAdjacentTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabId }), !tabs.isEmpty else { return }
        activeTabId = tabs[(index + offset + tabs.count) % tabs.count].id
        activePaneSide = .left
        persistTabsState()
    }

    public func closeOtherTabs(keeping id: UUID) {
        for tab in tabs where tab.id != id { closeTab(tab.id) }
        activeTabId = id
        activePaneSide = .left
    }

    public func reloadVisiblePanes() {
        leftTab.refresh()
        if isDualPane { rightPane.refresh() }
    }

    public func toggleDualPane() {
        if !isDualPane {
            rightPane.navigate(to: leftTab.currentURL, recordHistory: false)
            isDualPane = true
        } else {
            isDualPane = false
            activePaneSide = .left
        }
    }

    public func toggleQuickLook() {
        let selected = activeTab.selectedItems
        guard !selected.isEmpty else { return }
        QuickLookCoordinator.shared.preview(urls: selected.map(\.url))
    }
}

/// Native macOS QuickLook (`QLPreviewPanel`) bridge
@MainActor
public final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookCoordinator()
    private var previewURLs: [URL] = []

    public func preview(urls: [URL]) {
        self.previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    public func updateIfVisible(urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        self.previewURLs = urls
        panel.reloadData()
    }

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard index >= 0 && index < previewURLs.count else { return nil }
            return previewURLs[index] as NSURL
        }
    }
}
