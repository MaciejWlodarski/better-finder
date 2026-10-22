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

    @Published public var currentURL: URL
    @Published public var historyBack: [URL] = []
    @Published public var historyForward: [URL] = []

    @Published public var directoryItems: [FileItem] = []
    @Published public private(set) var directoryRevision: UInt64 = 0
    @Published public var displayedItems: [FileItem] = []
    @Published public var selectedPaths: Set<String> = []
    @Published public var expandedFolderPaths: Set<String> = []

    @Published public var viewMode: FinderViewMode = .list
    @Published public var sortField: SortField = .name
    @Published public var sortAscending: Bool = true
    @Published public var foldersOnTop: Bool = true
    @Published public var showHiddenFiles: Bool = false

    // Integrated fsearch state
    @Published public var searchQuery: String = ""
    @Published public var searchScope: SearchScopeMode = .wholeIndex
    @Published public var fuzzyEnabled: Bool = true
    @Published public var isSearching: Bool = false
    @Published public var lastSearchLatencyMs: Double = 0
    @Published public var activeFilterPills: [ActiveFilterPill] = []
    @Published public var searchBackendName: String = "fsearch-native"

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

    public var selectedItems: [FileItem] {
        displayedItems.filter { selectedPaths.contains($0.path) }
    }

    public var primarySelectedItem: FileItem? {
        if let cursor = selectionCursorPath, selectedPaths.contains(cursor),
           let item = displayedItems.first(where: { $0.path == cursor }) {
            return item
        }
        return displayedItems.first(where: { selectedPaths.contains($0.path) })
    }

    public init(initialURL: URL) {
        self.currentURL = initialURL
        self.columnTrailURLs = [initialURL]
        reloadDirectory()
    }

    public func navigate(to url: URL, recordHistory: Bool = true) {
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
        guard item.isDirectory else { return }
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
        let targetPath = currentURL.path
        let includeHidden = showHiddenFiles

        metadataGeneration &+= 1
        for operation in tagOperations { operation.cancel() }
        tagOperations.removeAll()
        tagCache.removeAll()
        pendingTagPaths.removeAll()
        let entries = BulkCrawler.readDirectoryFast(at: targetPath, includeHidden: includeHidden)
        let items = sortItems(entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
        self.directoryItems = items
        triggerSearch()
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { directoryRevision &+= 1 }

        // Asynchronously fetch git status for developer directories
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let gitMap = FileOperationsManager.fetchGitStatusMap(for: targetPath)
            guard !gitMap.isEmpty else { return }
            Task { @MainActor in
                guard let self = self, self.currentURL.path == targetPath else { return }
                var updated = false
                for idx in self.directoryItems.indices {
                    let p = self.directoryItems[idx].path
                    if let status = gitMap[p] {
                        self.directoryItems[idx].gitStatus = status
                        updated = true
                    }
                }
                if updated && self.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.rebuildDisplayedItemsWithExpandedTree()
                }
            }
        }
    }

    private func rebuildDisplayedItemsWithExpandedTree() {
        guard searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if expandedFolderPaths.isEmpty {
            displayedItems = directoryItems
            selectedPaths.formIntersection(Set(displayedItems.map(\.path)))
            loadTagMetadataIfNeeded(for: displayedItems)
            return
        }
        var flat: [FileItem] = []
        flat.reserveCapacity(directoryItems.count + expandedFolderPaths.count * 10)
        appendTreeItems(from: directoryItems, into: &flat)
        displayedItems = flat
        selectedPaths.formIntersection(Set(flat.map(\.path)))
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
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let parsed = ParsedFSearchQuery.parse(q, fuzzyEnabled: fuzzyEnabled)
        activeFilterPills = parsed.pills

        guard !q.isEmpty else {
            isSearching = false
            lastSearchLatencyMs = 0
            directoryItems = sortItems(directoryItems)
            rebuildDisplayedItemsWithExpandedTree()
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
                fuzzyEnabled: fuzzy
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.searchGeneration == generation else { return }
                self.displayedItems = self.sortItems(bundle.items)
                self.selectedPaths.formIntersection(Set(self.displayedItems.map(\.path)))
                self.lastSearchLatencyMs = bundle.elapsedMilliseconds
                self.searchBackendName = bundle.backendName
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

    public func isAffectedByDirectoryChanges(_ changedDirectories: Set<String>) -> Bool {
        let path = currentURL.path
        if changedDirectories.contains(path) { return true }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch searchScope {
        case .wholeIndex: return !changedDirectories.isEmpty
        case .currentFolder:
            return changedDirectories.contains { path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        case .recursiveFolder:
            return changedDirectories.contains {
                $0.hasPrefix(path == "/" ? "/" : path + "/") || path.hasPrefix($0 == "/" ? "/" : $0 + "/")
            }
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
        if extending,
           let anchor = selectionAnchorPath ?? primarySelectedItem?.path,
           let start = displayedItems.firstIndex(where: { $0.path == anchor }),
           let end = displayedItems.firstIndex(where: { $0.path == item.path }) {
            selectionAnchorPath = anchor
            selectedPaths = Set(displayedItems[min(start, end)...max(start, end)].map(\.path))
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
        guard !displayedItems.isEmpty else { return }
        let current = selectionCursorPath.flatMap { path in displayedItems.firstIndex(where: { $0.path == path }) }
            ?? primarySelectedItem.flatMap { item in displayedItems.firstIndex(where: { $0.path == item.path }) }
        let next = current.map { max(0, min(displayedItems.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : displayedItems.count - 1)
        select(displayedItems[next], extending: extending)
    }

    public func selectAll() {
        selectedPaths = Set(displayedItems.map(\.path))
        selectionAnchorPath = displayedItems.first?.path
        selectionCursorPath = displayedItems.last?.path
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

    private func sortItems(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            if foldersOnTop && a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            let cmp: Bool
            switch sortField {
            case .name:
                cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                let sizeA = a.isDirectory ? (FolderSizeCache.shared.size(for: a.path) ?? 0) : a.size
                let sizeB = b.isDirectory ? (FolderSizeCache.shared.size(for: b.path) ?? 0) : b.size
                if sizeA != sizeB {
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
                let sizeA = a.isDirectory ? (FolderSizeCache.shared.size(for: a.path) ?? 0) : a.size
                let sizeB = b.isDirectory ? (FolderSizeCache.shared.size(for: b.path) ?? 0) : b.size
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
