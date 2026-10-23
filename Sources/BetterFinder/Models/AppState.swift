import Foundation
import Combine
import AppKit
import QuickLookUI

public enum PaneSide: String, Sendable {
    case left
    case right
}

public struct SidebarLocationItem: Identifiable, Hashable {
    public var id: String { bookmarkPath ?? url.path }
    public var bookmarkPath: String? = nil
    public let title: String
    public let iconName: String
    public let url: URL
    public let isCustomBookmark: Bool
}

public struct VolumeInfoItem: Identifiable, Sendable {
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

    @Published public var tabs: [PaneTabState] = [] {
        didSet { observeSessionPanes(); synchronizeQuickLookOwnership() }
    }
    @Published public var activeTabId: UUID {
        didSet {
            if oldValue != activeTabId { tabs.first { $0.id == oldValue }?.cancelSessionRestoration() }
            synchronizeQuickLookOwnership()
        }
    }

    // Dual-pane mode
    @Published public var isDualPane: Bool = false {
        didSet {
            Self.preferences.set(isDualPane, forKey: "bf.isDualPane")
            if !isDualPane { rightPane.cancelPendingSavedSearches() }
            synchronizeQuickLookOwnership()
        }
    }
    @Published public var rightPane: PaneTabState {
        didSet { observeSessionPanes(); synchronizeQuickLookOwnership() }
    }
    @Published public var activePaneSide: PaneSide = .left {
        didSet {
            if oldValue != activePaneSide {
                (oldValue == .left ? leftTab : rightPane).cancelSessionRestoration()
            }
            synchronizeQuickLookOwnership()
        }
    }
    @Published public private(set) var restoreSessionEnabled = true
    @Published public private(set) var sessionPersistenceNotice: String?
    private let sessionStore: FinderSessionStore
    private var sessionObservers: [AnyCancellable] = []
    private var appSessionObserver: AnyCancellable?
    private var sessionSaveTask: Task<Void, Never>?
    private var sessionObservationReady = false

    private func observeSessionPanes() {
        guard sessionObservationReady else { return }
        sessionObservers = (tabs + [rightPane]).map { pane in
            pane.objectWillChange.sink { [weak self] _ in self?.scheduleSessionSave() }
        }
        scheduleSessionSave()
    }

    private func scheduleSessionSave() {
        guard sessionObservationReady, restoreSessionEnabled else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSessionState()
        }
    }

    public func setSessionRestorationEnabled(_ enabled: Bool) {
        sessionSaveTask?.cancel()
        sessionStore.setEnabled(enabled)
        restoreSessionEnabled = enabled
        if enabled { flushSessionState() }
    }

    public func clearSavedSession() {
        sessionSaveTask?.cancel()
        sessionStore.clearAndDisable()
        restoreSessionEnabled = false
        sessionPersistenceNotice = nil
    }

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
    @Published public private(set) var volumeInventory = VolumeInventoryState()
    public var mountedVolumes: [VolumeInfoItem] { volumeInventory.items }
    private var volumeService: VolumeRefreshService?
    private lazy var pinnedFolderStore = PinnedFolderStore(
        read: { Self.preferences.object(forKey: PinnedFolderStore.key) },
        write: { Self.preferences.set($0, forKey: PinnedFolderStore.key) })
    @Published public private(set) var pinnedFolderNotice: String?


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
        let store = FinderSessionStore(defaults: defaults)
        self.sessionStore = store
        let homeURL = Self.homeDirectoryURL
        let devLabPath = homeURL.appendingPathComponent("dev").path
        let defaultStartURL = FileManager.default.fileExists(atPath: devLabPath)
            ? URL(fileURLWithPath: devLabPath, isDirectory: true)
            : homeURL

        let restored = store.load(defaultRightPath: homeURL.path)
        let snapshot = restored.snapshot
        let restoredTabs = snapshot?.tabs.map { $0.makePausedPane() }
            ?? [PaneTabState(initialURL: defaultStartURL)]
        self.tabs = restoredTabs
        self.activeTabId = restoredTabs[snapshot?.activeIndex ?? 0].id
        self.rightPane = snapshot?.right.makePausedPane() ?? PaneTabState(initialURL: homeURL)
        self.restoreSessionEnabled = store.isEnabled
        self.sessionPersistenceNotice = restored.notice
        if let snapshot {
            self.isDualPane = snapshot.dualPane
            self.activePaneSide = snapshot.activeSide == "right" ? .right : .left
        }

        if defaults.object(forKey: "bf.showSidebar") != nil {
            self.showSidebar = defaults.bool(forKey: "bf.showSidebar")
        }
        if defaults.object(forKey: "bf.showInspector") != nil {
            self.showInspector = defaults.bool(forKey: "bf.showInspector")
        }
        if snapshot == nil, defaults.object(forKey: "bf.isDualPane") != nil {
            self.isDualPane = defaults.bool(forKey: "bf.isDualPane")
        }
        let savedIconSize = defaults.double(forKey: "bf.iconGridSize")
        if savedIconSize >= 40 && savedIconSize <= 140 {
            self.iconGridSize = savedIconSize
        }

        if isDualPane { rightPane.retainInitialLocation() }

        setupSidebarLocations()
        loadPersistedBookmarksAndSmartFolders()
        #if !BETTERFINDER_TESTING
        let volumes = VolumeRefreshService.production()
        volumeService = volumes
        volumes.start { [weak self] result in self?.volumeInventory.apply(result) }
        #endif
        setupIndexCallbacks()
        sessionObservationReady = true
        observeSessionPanes()
        appSessionObserver = objectWillChange.sink { [weak self] _ in self?.scheduleSessionSave() }
    }

    private var indexLifecycle = IndexingLifecycleState()
    private func setupIndexCallbacks() {
        FSearchIndex.shared.onIndexingLifecycle = { event in
            Task { @MainActor in
                self.indexLifecycle.apply(event)
                self.isIndexing = self.indexLifecycle.isIndexing
            }
        }
        FSearchIndex.shared.onIndexUpdated = { count, durationMs in
            Task { @MainActor in
                self.indexedFileCount = count
                self.indexBuildDurationMs = durationMs
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
        updatePinnedFolderRows()
        if let data = defaults.data(forKey: "bf.savedSmartFolders") {
            savedSearchArchive = try? SavedSearchArchive(data: data)
            savedSmartFolders = savedSearchArchive?.items ?? []
        }
    }

    public func persistTabsState() { scheduleSessionSave() }

    /// Flush synchronously at normal termination; snapshots never include runtime actions.
    public func flushSessionState() {
        guard sessionObservationReady, restoreSessionEnabled else { return }
        let snapshot = FinderSessionSnapshot(tabs: tabs.map { FinderPaneSession(pane: $0) },
            right: FinderPaneSession(pane: rightPane),
            activeIndex: tabs.firstIndex { $0.id == activeTabId } ?? 0,
            dualPane: isDualPane, activeSide: activePaneSide.rawValue)
        if sessionStore.save(snapshot) {
            if sessionPersistenceNotice != nil { sessionPersistenceNotice = nil }
        } else if sessionPersistenceNotice == nil {
            sessionPersistenceNotice = "Nie zapisano sesji. Poprzedni zapis został zachowany."
        }
    }

    #if BETTERFINDER_TESTING
    var hasPersistedSessionForTesting: Bool { Self.preferences.object(forKey: FinderSessionStore.dataKey) != nil }
    #endif

    private func updatePinnedFolderRows() {
        customBookmarks = pinnedFolderStore.displayedPaths.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return SidebarLocationItem(bookmarkPath: path, title: url.lastPathComponent, iconName: "bookmark.fill",
                url: url, isCustomBookmark: true)
        }
        pinnedFolderNotice = pinnedFolderStore.notice
    }

    public func addBookmark(for url: URL) {
        guard pinnedFolderStore.notice == nil else { updatePinnedFolderRows(); return }
        guard url.isFileURL, PinnedFolderStore.validPath(url.path) else { return }
        // Only a new, explicitly requested target is probed; restored pins never are.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        if !pinnedFolderStore.add(url.path) {
            FileOperationsManager.shared.lastStatusMessage = "Nie potwierdzono zapisu przypiętego folderu."
        }
        updatePinnedFolderRows()
    }

    public func removeBookmark(_ item: SidebarLocationItem) {
        if !pinnedFolderStore.remove(item.id) {
            FileOperationsManager.shared.lastStatusMessage = "Nie potwierdzono zapisu zmiany przypiętych folderów."
        }
        updatePinnedFolderRows()
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

    public func refreshMountedVolumes() { volumeService?.requestRefresh() }

    public func ejectVolume(_ vol: VolumeInfoItem) {
        do {
            try VolumeEjectAction.perform(vol.url,
                eject: { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) },
                refresh: refreshMountedVolumes)
            FileOperationsManager.shared.lastStatusMessage = "Wysunięto wolumin \(vol.name)"
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
            rightPane.initializeLocationIfNeeded(matching: leftTab.currentURL)
            isDualPane = true
        } else {
            isDualPane = false
            activePaneSide = .left
        }
    }

    /// A preview remains bound to its initiating pane. Explicit context changes
    /// close it; background updates must never choose a new owner implicitly.
    private func synchronizeQuickLookOwnership() {
        let visibleOwner: UUID?
        if isDualPane && activePaneSide == .right {
            visibleOwner = rightPane.id
        } else {
            visibleOwner = tabs.first(where: { $0.id == activeTabId })?.id ?? tabs.first?.id
        }
        QuickLookCoordinator.shared.retainOwner(visibleOwner)
    }

    public func toggleQuickLook() {
        let pane = activeTab
        let selected = pane.selectedItems
        guard !selected.isEmpty else { return }
        QuickLookCoordinator.shared.preview(ownerID: pane.id, urls: selected.map(\.url))
    }
}

/// Value-only ownership state shared by the native bridge and focused tests.
/// URLs may change only through an explicit preview or an update by this owner.
struct QuickLookPreviewSession {
    private(set) var ownerID: UUID?
    private(set) var urls: [URL] = []

    mutating func open(ownerID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { close(); return }
        self.ownerID = ownerID
        self.urls = urls
    }

    @discardableResult
    mutating func update(ownerID: UUID, urls: [URL]) -> Bool {
        guard self.ownerID == ownerID else { return false }
        if urls.isEmpty { close() } else { self.urls = urls }
        return true
    }

    mutating func close() { ownerID = nil; urls = [] }
}

@MainActor
protocol QuickLookPanelDriving: AnyObject {
    var isVisible: Bool { get }
    func show(coordinator: QuickLookCoordinator) -> Bool
    func reload()
    func hide()
}

/// Only this adapter touches QLPreviewPanel. Ownership transitions can be tested
/// with an inert driver without presenting a native window or loading file data.
@MainActor
private final class NativeQuickLookPanelDriver: QuickLookPanelDriving {
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible == true)
    }
    func show(coordinator: QuickLookCoordinator) -> Bool {
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = coordinator
        panel.delegate = coordinator
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        return true
    }
    func reload() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
    }
    func hide() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }
}

/// Native macOS QuickLook (`QLPreviewPanel`) bridge with explicit pane ownership.
@MainActor
public final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    #if BETTERFINDER_TESTING
    public static var shared = QuickLookCoordinator()
    #else
    public static let shared = QuickLookCoordinator()
    #endif
    private let panelDriver: any QuickLookPanelDriving
    private(set) var session = QuickLookPreviewSession()

    override init() {
        panelDriver = NativeQuickLookPanelDriver()
        super.init()
    }
    init(panelDriver: any QuickLookPanelDriving) {
        self.panelDriver = panelDriver
        super.init()
    }

    public func preview(ownerID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !panelDriver.isVisible { session.close() }
        if session.ownerID == ownerID {
            close()
            return
        }
        // A new explicit preview may transfer a visible session to another pane;
        // background selection reconciliation cannot do so.
        session.open(ownerID: ownerID, urls: urls)
        if panelDriver.isVisible {
            panelDriver.reload()
        } else if !panelDriver.show(coordinator: self) {
            session.close()
        }
    }

    public func updateIfVisible(ownerID: UUID, urls: [URL]) {
        guard panelDriver.isVisible else { session.close(); return }
        guard session.update(ownerID: ownerID, urls: urls) else { return }
        if session.ownerID == nil { panelDriver.hide() } else { panelDriver.reload() }
    }

    /// Switching context or removing/hiding the owner closes instead of rebinding.
    public func retainOwner(_ visibleOwner: UUID?) {
        guard let owner = session.ownerID, owner != visibleOwner else { return }
        close()
    }

    private func close() {
        session.close()
        panelDriver.hide()
    }

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { session.urls.count }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard index >= 0 && index < session.urls.count else { return nil }
            return session.urls[index] as NSURL
        }
    }
}
