import Foundation
import AppKit
import Combine

public enum FinderViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case icons = "Icons"
    case columns = "Columns"
    case wiztree = "WizTree"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: return "Lista"
        case .icons: return "Ikony"
        case .columns: return "Kolumny"
        case .wiztree: return "Mapa dysku"
        }
    }

    public var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        case .wiztree: return "square.grid.3x1.below.line.grid.1x2.fill"
        }
    }
}

public enum SortField: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case dateModified = "Date Modified"
    case kind = "Kind"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "Nazwa"
        case .size: return "Rozmiar"
        case .dateModified: return "Data modyfikacji"
        case .kind: return "Rodzaj"
        }
    }
}

@MainActor
public final class PaneTabState: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public var currentURL: URL {
        didSet { if oldValue != currentURL { cancelSavedSearchActivation() } }
    }
    @Published public var historyBack: [URL] = []
    @Published public var historyForward: [URL] = []

    @Published public var directoryItems: [FileItem] = []
    @Published public private(set) var directoryRevision: UInt64 = 0
    @Published public var displayedItems: [FileItem] = []
    @Published public var selectedPaths: Set<String> = []
    @Published public var expandedFolderPaths: Set<String> = []

    @Published public var viewMode: FinderViewMode = .list {
        didSet {
            guard oldValue != viewMode else { return }
            cancelSavedSearchActivation()
            clearAnalysisSelection()
            if viewMode != .list { expandedFolderPaths.removeAll() }
            rebuildDisplayedItemsWithExpandedTree()
            reconcileSelection()
            directoryRevision &+= 1
        }
    }
    @Published public var sortField: SortField = .name
    @Published public var sortAscending: Bool = true
    @Published public var foldersOnTop: Bool = true
    @Published public var showHiddenFiles: Bool = false {
        didSet { if oldValue != showHiddenFiles { cancelSavedSearchActivation() } }
    }

    // Integrated fsearch state
    @Published public var searchQuery: String = "" {
        didSet { if oldValue != searchQuery { cancelSavedSearchActivation() } }
    }
    @Published public var searchScope: SearchScopeMode = .wholeIndex {
        didSet { if oldValue != searchScope { cancelSavedSearchActivation() } }
    }
    @Published public var fuzzyEnabled: Bool = true {
        didSet { if oldValue != fuzzyEnabled { cancelSavedSearchActivation() } }
    }
    @Published public var isSearching: Bool = false
    @Published public private(set) var isActivatingSavedSearch: Bool = false
    private var savedSearchActivationGeneration: UInt64 = 0
    private var savedSearchPreparation: SavedSearchWork<PreparedSavedSearch>?
    private var savedSearchBrowsingPreparation: SavedSearchWork<[IndexedFileEntry]>?
    @Published public var lastSearchLatencyMs: Double = 0
    @Published public var activeFilterPills: [ActiveFilterPill] = []
    @Published public var searchBackendName: String = "fsearch-native"
    @Published public private(set) var searchDiagnostic: String?
    @Published public private(set) var searchIsPartial: Bool = false

    // Inline editing / path bar state
    @Published public var isEditingPathBar: Bool = false
    @Published public var renamingItemPath: String? = nil
    @Published public var focusFilePaneTrigger: UInt64 = 0
    @Published public var selectionCursorPath: String?
    private var selectionAnchorPath: String?

    // Miller column trail
    @Published public var columnTrailURLs: [URL] = []

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var searchContext: String?
    private var directoryLoadGeneration: UInt64 = 0
    @Published private var analysisItems: [FileItem] = []
    private var analysisRootPath: String?
    private var analysisGeneration: UUID?
    @Published public private(set) var tagMetadataRevision: UInt64 = 0
    private var metadataGeneration: UInt64 = 0
    private var tagCache: [String: [FinderTagColor]] = [:]
    private var pendingTagPaths: Set<String> = []
    private var tagOperations: [Operation] = []
    private static let metadataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.betterfinder.tag-metadata"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    public var title: String {
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return searchQuery
        }
        let name = currentURL.lastPathComponent
        return name.isEmpty || name == "/" ? "Macintosh HD" : name
    }

    /// The only projection eligible for keyboard commands and file operations.
    public var selectableItems: [FileItem] {
        if viewMode == .wiztree && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return analysisRootPath == currentURL.path ? analysisItems : []
        }
        return displayedItems
    }

    public var selectedItems: [FileItem] {
        selectableItems.filter { selectedPaths.contains($0.path) }
    }

    public var primarySelectedItem: FileItem? {
        if let cursor = selectionCursorPath, selectedPaths.contains(cursor),
           let item = selectableItems.first(where: { $0.path == cursor }) {
            return item
        }
        return selectableItems.first(where: { selectedPaths.contains($0.path) })
    }

    public var renamingItem: FileItem? {
        guard let path = renamingItemPath else { return nil }
        return selectableItems.first { $0.path == path }
    }

    public func beginAnalysisProjection(rootPath: String, generation: UUID) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearAnalysisSelection()
        analysisRootPath = root
        analysisGeneration = generation
    }

    public func publishAnalysisItems(_ items: [FileItem], rootPath: String, generation: UUID) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path,
              root == analysisRootPath, generation == analysisGeneration,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var seen = Set<String>()
        analysisItems = items.filter {
            ($0.path == root || $0.path.hasPrefix(root == "/" ? "/" : root + "/")) && seen.insert($0.path).inserted
        }
        reconcileSelection()
    }

    public func setAnalysisSelection(_ items: [FileItem], rootPath: String) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path, root == analysisRootPath,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let visible = Set(analysisItems.map(\.path))
        let selected = items.filter { visible.contains($0.path) }
        selectedPaths = Set(selected.map(\.path))
        selectionCursorPath = selected.last?.path
        selectionAnchorPath = selected.first?.path
        QuickLookCoordinator.shared.updateIfVisible(urls: selectedItems.map(\.url))
    }

    public func clearAnalysisSelection() {
        if analysisRootPath != nil {
            renamingItemPath = nil
            selectedPaths.removeAll()
            selectionCursorPath = nil
            selectionAnchorPath = nil
        }
        analysisRootPath = nil
        analysisGeneration = nil
        analysisItems.removeAll()
    }

    /// Context-menu actions re-resolve their targets at invocation time.
    public func actionItems(for item: FileItem) -> [FileItem] {
        guard let current = selectableItems.first(where: { $0.path == item.path }) else { return [] }
        return selectedPaths.contains(item.path) ? selectedItems : [current]
    }

    private func reconcileSelection() {
        let visible = Set(selectableItems.map(\.path))
        if let renamingItemPath, !visible.contains(renamingItemPath) { self.renamingItemPath = nil }
        selectedPaths.formIntersection(visible)
        if let cursor = selectionCursorPath, !visible.contains(cursor) { selectionCursorPath = nil }
        if let anchor = selectionAnchorPath, !visible.contains(anchor) { selectionAnchorPath = nil }
        QuickLookCoordinator.shared.updateIfVisible(urls: selectedItems.map(\.url))
    }

    public init(initialURL: URL) {
        self.currentURL = initialURL.standardizedFileURL
        self.columnTrailURLs = [initialURL.standardizedFileURL]
        reloadDirectory()
    }

    public func navigate(to url: URL, recordHistory: Bool = true) {
        cancelPendingSavedSearches()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue {
            NSWorkspace.shared.open(url)
            return
        }

        let standardized = url.standardizedFileURL
        if recordHistory && standardized.path != currentURL.path {
            historyBack.append(currentURL)
            historyForward.removeAll()
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        isSearching = false
        clearAnalysisSelection()
        displayedItems.removeAll()
        searchContext = nil
        currentURL = standardized
        selectionCursorPath = nil
        selectionAnchorPath = nil
        selectedPaths.removeAll()
        expandedFolderPaths.removeAll()
        renamingItemPath = nil

        if !searchQuery.isEmpty && searchScope == .wholeIndex {
            searchQuery = ""
            activeFilterPills = []
        }
        // Keep the browsing snapshot in sync even while a local query stays active.
        reloadDirectory()

        updateColumnTrail(for: standardized)
        FSearchIndex.shared.ensureDirectoryIndexed(standardized.path)
        AppState.shared.persistTabsState()
    }

    var savedSearchActivationContext: String {
        "\(currentURL.path)\u{0}\(searchQuery)\u{0}\(searchScope.rawValue)\u{0}\(showHiddenFiles)\u{0}\(fuzzyEnabled)\u{0}\(viewMode.rawValue)\u{0}\(directoryLoadGeneration)\u{0}\(savedSearchActivationGeneration)"
    }

    /// Validate and list off the main actor. Commit only if this exact request
    /// still owns the captured pane context; navigation and newer queries win.
    @discardableResult
    func applySavedSearch(
        _ item: SavedSmartFolderItem,
        prepare: (@Sendable (SavedSmartFolderItem) throws -> PreparedSavedSearch)? = nil,
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) async throws -> Bool {
        cancelPendingSavedSearches()
        savedSearchActivationGeneration &+= 1
        let generation = savedSearchActivationGeneration
        let context = savedSearchActivationContext
        isActivatingSavedSearch = true
        let request = SavedSearchWork<PreparedSavedSearch>()
        savedSearchPreparation = request
        defer {
            if generation == savedSearchActivationGeneration {
                isActivatingSavedSearch = false
                savedSearchPreparation = nil
            }
        }
        let prepared: PreparedSavedSearch
        do {
            // Global activation requires no directory probe/listing. A changed
            // hidden-file option refreshes its browsing snapshot separately.
            if item.scope == .wholeIndex {
                prepared = PreparedSavedSearch(root: nil, entries: [])
            } else {
                prepared = try await SavedSearchPreparation.run({
                    if let prepare { return try prepare(item) }
                    return try SavedSearchPreparation.prepare(item, isCancelled: { request.isCancelled })
                }, request: request)
            }
        } catch {
            guard generation == savedSearchActivationGeneration,
                  context == savedSearchActivationContext, !Task.isCancelled, shouldApply() else { return false }
            throw error
        }
        guard generation == savedSearchActivationGeneration,
              context == savedSearchActivationContext, !Task.isCancelled, shouldApply() else { return false }
        let hiddenChanged = showHiddenFiles != item.includeHidden
        if let root = prepared.root, root.path != currentURL.path {
            historyBack.append(currentURL)
            historyForward.removeAll()
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        clearAnalysisSelection()
        displayedItems.removeAll()
        selectedPaths.removeAll()
        selectionCursorPath = nil
        selectionAnchorPath = nil
        expandedFolderPaths.removeAll()
        renamingItemPath = nil
        searchContext = nil
        directoryLoadGeneration &+= 1
        metadataGeneration &+= 1
        for operation in tagOperations { operation.cancel() }
        tagOperations.removeAll()
        tagCache.removeAll()
        pendingTagPaths.removeAll()
        if viewMode == .wiztree { viewMode = .list }
        searchScope = item.scope
        showHiddenFiles = item.includeHidden
        fuzzyEnabled = item.fuzzyEnabled
        searchQuery = item.query
        if let root = prepared.root {
            currentURL = root
            updateColumnTrail(for: root)
            FileIconCache.shared.invalidate(containing: root.path)
            FolderSizeCache.shared.invalidate(containing: root.path)
            directoryItems = sortItems(prepared.entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
            AppState.shared.persistTabsState()
        } else if hiddenChanged {
            directoryItems.removeAll()
            refreshSavedSearchBrowsingSnapshot()
        }
        triggerSearch()
        return true
    }

    func cancelPendingSavedSearches() {
        cancelSavedSearchActivation()
        savedSearchBrowsingPreparation?.cancel()
        savedSearchBrowsingPreparation = nil
    }

    private func cancelSavedSearchActivation() {
        savedSearchActivationGeneration &+= 1
        savedSearchPreparation?.cancel()
        savedSearchPreparation = nil
        isActivatingSavedSearch = false
    }

    private func refreshSavedSearchBrowsingSnapshot() {
        savedSearchBrowsingPreparation?.cancel()
        let request = SavedSearchWork<[IndexedFileEntry]>()
        savedSearchBrowsingPreparation = request
        let path = currentURL.path
        let hidden = showHiddenFiles
        let generation = directoryLoadGeneration
        Task { @MainActor [weak self] in
            guard let entries = try? await SavedSearchPreparation.run({
                BulkCrawler.readDirectoryResult(at: path, includeHidden: hidden,
                                                isCancelled: { request.isCancelled }).entries
            }, request: request), let self, self.directoryLoadGeneration == generation,
                  self.currentURL.path == path, self.showHiddenFiles == hidden else { return }
            self.directoryItems = self.sortItems(entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
            if self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.triggerSearch()
            }
        }
    }

    public func goBack() {
        guard let prev = historyBack.popLast() else { return }
        historyForward.append(currentURL)
        navigate(to: prev, recordHistory: false)
    }

    public func goForward() {
        guard let next = historyForward.popLast() else { return }
        historyBack.append(currentURL)
        navigate(to: next, recordHistory: false)
    }

    public func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    // MARK: - Outline Tree Disclosure (`▸`) in List View

    public func isExpanded(_ folderPath: String) -> Bool {
        expandedFolderPaths.contains(folderPath)
    }

    public func toggleFolderExpansion(for item: FileItem) {
        guard viewMode == .list, item.isDirectory, selectableItems.contains(where: { $0.path == item.path }) else { return }
        if expandedFolderPaths.contains(item.path) {
            expandedFolderPaths.remove(item.path)
            // Also collapse any nested subfolders under this folder
            let prefix = item.path + "/"
            expandedFolderPaths = expandedFolderPaths.filter { !$0.hasPrefix(prefix) }
        } else {
            expandedFolderPaths.insert(item.path)
        }
        rebuildDisplayedItemsWithExpandedTree()
    }

    public func reloadDirectory() {
        cancelPendingSavedSearches()
        let targetPath = currentURL.path
        let includeHidden = showHiddenFiles
        directoryLoadGeneration &+= 1
        let loadGeneration = directoryLoadGeneration
        // Invalidate consumers of this directory snapshot before a local query
        // starts asynchronous work. Its eventual result commit has its own revision.
        directoryRevision &+= 1
        FileIconCache.shared.invalidate(containing: targetPath)
        FolderSizeCache.shared.invalidate(containing: targetPath)
        clearAnalysisSelection()

        metadataGeneration &+= 1
        for operation in tagOperations { operation.cancel() }
        tagOperations.removeAll()
        tagCache.removeAll()
        pendingTagPaths.removeAll()
        let entries = BulkCrawler.readDirectoryFast(at: targetPath, includeHidden: includeHidden)
        let items = sortItems(entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
        self.directoryItems = items
        triggerSearch()

        // A successful empty snapshot clears formerly dirty badges. Ignore
        // late responses even when the user has returned to the same folder.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: targetPath) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentURL.path == targetPath,
                      self.directoryLoadGeneration == loadGeneration else { return }
                FSearchIndex.shared.recordGitStatuses(snapshot.statuses, repositoryRoot: snapshot.repositoryRoot)
                for idx in self.directoryItems.indices {
                    self.directoryItems[idx].gitStatus = snapshot.statuses[self.directoryItems[idx].path]
                }
                if self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.rebuildDisplayedItemsWithExpandedTree()
                }
            }
        }
    }

    private func rebuildDisplayedItemsWithExpandedTree() {
        guard searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if viewMode != .list || expandedFolderPaths.isEmpty {
            displayedItems = directoryItems
            reconcileSelection()
            loadTagMetadataIfNeeded(for: displayedItems)
            return
        }
        var flat: [FileItem] = []
        flat.reserveCapacity(directoryItems.count + expandedFolderPaths.count * 10)
        appendTreeItems(from: directoryItems, into: &flat)
        displayedItems = flat
        reconcileSelection()
        loadTagMetadataIfNeeded(for: flat)
    }

    private func appendTreeItems(from items: [FileItem], into output: inout [FileItem]) {
        for item in items {
            output.append(item)
            if item.isDirectory && expandedFolderPaths.contains(item.path) && item.treeDepth < 8 {
                let childEntries = BulkCrawler.readDirectoryFast(at: item.path, includeHidden: showHiddenFiles)
                let childItems = sortItems(childEntries.map {
                    var child = $0.toFileItem(treeDepth: item.treeDepth + 1, loadTags: false)
                    child.tags = tagCache[child.path] ?? []
                    return child
                })
                appendTreeItems(from: childItems, into: &output)
            }
        }
    }

    public func triggerSearch() {
        cancelSavedSearchActivation()
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let parsed = ParsedFSearchQuery.parse(q, fuzzyEnabled: fuzzyEnabled)
        activeFilterPills = parsed.pills
        searchDiagnostic = parsed.validationError
        searchIsPartial = false
        let context = "\(currentURL.path)\u{0}\(searchScope.rawValue)\u{0}\(q)\u{0}\(showHiddenFiles)\u{0}\(fuzzyEnabled)"
        if context != searchContext {
            selectedPaths.removeAll()
            selectionCursorPath = nil
            selectionAnchorPath = nil
            clearAnalysisSelection()
        }
        searchContext = context

        guard !q.isEmpty else {
            isSearching = false
            lastSearchLatencyMs = 0
            directoryItems = sortItems(directoryItems)
            rebuildDisplayedItemsWithExpandedTree()
            return
        }

        // Never leave results from a previous query or directory actionable.
        // Same-context refreshes may restore selection only after fresh results commit.
        displayedItems.removeAll()
        QuickLookCoordinator.shared.updateIfVisible(urls: [])
        if parsed.validationError != nil {
            isSearching = false
            reconcileSelection()
            directoryRevision &+= 1
            return
        }
        isSearching = true
        let scope = searchScope
        let dirPath = currentURL.path
        let showHidden = showHiddenFiles
        let fuzzy = fuzzyEnabled

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bundle = FSearchIndex.shared.search(
                rawQuery: q,
                scope: scope,
                scopeDirectory: dirPath,
                includeHidden: showHidden,
                fuzzyEnabled: fuzzy,
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.searchGeneration == generation else { return }
                self.displayedItems = self.sortItems(bundle.items)
                self.reconcileSelection()
                self.lastSearchLatencyMs = bundle.elapsedMilliseconds
                self.searchBackendName = bundle.backendName
                self.searchIsPartial = bundle.isPartial
                self.searchDiagnostic = bundle.diagnostic
                self.isSearching = false
                self.directoryRevision &+= 1
            }
        }
    }

    public func cachedTags(for path: String) -> [FinderTagColor]? { tagCache[path] }

    /// Native tag providers can block on cloud/network metadata. Never query them
    /// while building a view or initializing a tab on the main actor.
    public func loadTagMetadataIfNeeded(for items: [FileItem]) {
        let pending = items.filter { tagCache[$0.path] == nil && !pendingTagPaths.contains($0.path) }
        guard !pending.isEmpty else { return }
        pendingTagPaths.formUnion(pending.map(\.path))
        let generation = metadataGeneration
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            for item in pending {
                guard let operation, !operation.isCancelled, self != nil else { return }
                let tags = FinderTagColor.readTags(for: item.url)
                if operation.isCancelled { return }
                Task { @MainActor [weak self] in
                    guard let self, self.metadataGeneration == generation else { return }
                    self.tagCache[item.path] = tags
                    self.pendingTagPaths.remove(item.path)
                    if let index = self.directoryItems.firstIndex(where: { $0.path == item.path }) {
                        self.directoryItems[index].tags = tags
                    }
                    if let index = self.displayedItems.firstIndex(where: { $0.path == item.path }) {
                        self.displayedItems[index].tags = tags
                    }
                    self.tagMetadataRevision &+= 1
                }
            }
        }
        tagOperations.removeAll { $0.isFinished || $0.isCancelled }
        tagOperations.append(operation)
        Self.metadataQueue.addOperation(operation)
    }

    public var visibleDirectoryPaths: Set<String> {
        var paths: Set<String> = [currentURL.path]
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return paths }
        if viewMode == .list { paths.formUnion(expandedFolderPaths) }
        if viewMode == .columns { paths.formUnion(columnTrailURLs.map(\.path)) }
        return paths
    }

    public func isAffectedByDirectoryChanges(_ changedDirectories: Set<String>) -> Bool {
        let changed = Set(changedDirectories.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let path = currentURL.path
        // Changes to a displayed directory, or its ancestor (removed/renamed
        // directory), invalidate its snapshot. Component boundaries are required.
        if visibleDirectoryPaths.contains(where: { visible in
            changed.contains { dir in visible == dir || visible.hasPrefix(dir == "/" ? "/" : dir + "/") }
        }) { return true }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Disk-analysis views also depend on descendants of the root.
            return viewMode == .wiztree && changed.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
        }
        switch searchScope {
        case .wholeIndex: return !changed.isEmpty
        case .currentFolder: return false
        case .recursiveFolder:
            return changed.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
        }
    }

    public func refresh() {
        reloadDirectory()
    }

    public func clearSearch() {
        searchQuery = ""
        reloadDirectory()
    }

    public func select(_ item: FileItem, extending: Bool = false, toggling: Bool = false) {
        let items = selectableItems
        guard items.contains(where: { $0.path == item.path }) else { return }
        if extending,
           let anchor = selectionAnchorPath ?? primarySelectedItem?.path,
           let start = items.firstIndex(where: { $0.path == anchor }),
           let end = items.firstIndex(where: { $0.path == item.path }) {
            selectionAnchorPath = anchor
            selectedPaths = Set(items[min(start, end)...max(start, end)].map(\.path))
        } else if toggling {
            if selectedPaths.contains(item.path) { selectedPaths.remove(item.path) }
            else { selectedPaths.insert(item.path) }
            selectionAnchorPath = item.path
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
        selectionCursorPath = item.path
        QuickLookCoordinator.shared.updateIfVisible(urls: selectedItems.map(\.url))
    }

    public func moveSelection(by delta: Int, extending: Bool = false) {
        let items = selectableItems
        guard !items.isEmpty else { return }
        let current = selectionCursorPath.flatMap { path in items.firstIndex(where: { $0.path == path }) }
            ?? primarySelectedItem.flatMap { item in items.firstIndex(where: { $0.path == item.path }) }
        let next = current.map { max(0, min(items.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : items.count - 1)
        select(items[next], extending: extending)
    }

    public func selectAll() {
        let items = selectableItems
        selectedPaths = Set(items.map(\.path))
        selectionAnchorPath = items.first?.path
        selectionCursorPath = items.last?.path
        QuickLookCoordinator.shared.updateIfVisible(urls: selectedItems.map(\.url))
    }

    public func removeFilterPill(_ pill: ActiveFilterPill) {
        let updated = searchQuery
            .replacingOccurrences(of: pill.rawToken, with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        searchQuery = updated
        triggerSearch()
    }

    public func appendSearchOperator(_ token: String) {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(token) {
            searchQuery = trimmed.replacingOccurrences(of: token, with: "").trimmingCharacters(in: .whitespaces)
        } else {
            searchQuery = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        }
        triggerSearch()
    }

    public func applySortChange() {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            directoryItems = sortItems(directoryItems)
            rebuildDisplayedItemsWithExpandedTree()
        } else {
            displayedItems = sortItems(displayedItems)
        }
    }

    public func sortItems(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            if foldersOnTop && a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            let cmp: Bool
            switch sortField {
            case .name:
                cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                let exactA = a.isDirectory ? FolderSizeCache.shared.size(for: a.path) : a.size
                let exactB = b.isDirectory ? FolderSizeCache.shared.size(for: b.path) : b.size
                if (exactA == nil) != (exactB == nil) { return exactA != nil }
                let sizeA = exactA ?? FolderSizeCache.shared.result(for: a.path)?.bytes
                let sizeB = exactB ?? FolderSizeCache.shared.result(for: b.path)?.bytes
                if (sizeA == nil) != (sizeB == nil) { return sizeA != nil }
                if let sizeA, let sizeB, sizeA != sizeB {
                    cmp = sizeA < sizeB
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .dateModified:
                if a.modificationDate != b.modificationDate {
                    cmp = a.modificationDate < b.modificationDate
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .kind:
                if a.kindDisplayString != b.kindDisplayString {
                    cmp = a.kindDisplayString < b.kindDisplayString
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            if a.path == b.path { return false }
            let equal: Bool
            switch sortField {
            case .name: equal = a.name.localizedStandardCompare(b.name) == .orderedSame
            case .size:
                let sizeA = a.isDirectory ? FolderSizeCache.shared.result(for: a.path)?.bytes : a.size
                let sizeB = b.isDirectory ? FolderSizeCache.shared.result(for: b.path)?.bytes : b.size
                equal = sizeA == sizeB && a.name.localizedStandardCompare(b.name) == .orderedSame
            case .dateModified: equal = a.modificationDate == b.modificationDate && a.name.localizedStandardCompare(b.name) == .orderedSame
            case .kind: equal = a.kindDisplayString == b.kindDisplayString && a.name.localizedStandardCompare(b.name) == .orderedSame
            }
            if equal { return a.path < b.path }
            return sortAscending ? cmp : !cmp
        }
    }

    private func updateColumnTrail(for url: URL) {
        if let idx = columnTrailURLs.firstIndex(of: url) {
            columnTrailURLs = Array(columnTrailURLs.prefix(through: idx))
        } else if let last = columnTrailURLs.last, url.deletingLastPathComponent().path == last.path {
            columnTrailURLs.append(url)
            if columnTrailURLs.count > 4 {
                columnTrailURLs.removeFirst(columnTrailURLs.count - 4)
            }
        } else {
            let parent = url.deletingLastPathComponent()
            if parent.path != url.path {
                columnTrailURLs = [parent, url]
            } else {
                columnTrailURLs = [url]
            }
        }
    }
}
