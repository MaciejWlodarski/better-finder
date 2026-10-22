import SwiftUI
import AppKit

struct QuickSearchRequest: Sendable {
    let query: String
    let rootPath: String
    let includeHidden: Bool
    let token: AnalysisRequestToken
}

@MainActor
final class QuickSearchModel: ObservableObject {
    @Published private(set) var results: [FileItem] = []
    @Published private(set) var elapsedMs: Double = 0
    @Published private(set) var isSearching = false
    @Published private(set) var diagnostic: String?
    private var task: Task<Void, Never>?
    private var token: AnalysisRequestToken?
    private let provider: @Sendable (QuickSearchRequest) -> FSearchResultBundle

    init(provider: @escaping @Sendable (QuickSearchRequest) -> FSearchResultBundle = { request in
        FSearchIndex.shared.search(rawQuery: request.query, scope: .wholeIndex,
            scopeDirectory: request.rootPath, includeHidden: request.includeHidden, fuzzyEnabled: true,
            isCancelled: { request.token.isCancelled })
    }) { self.provider = provider }

    func cancel() {
        token?.cancel()
        task?.cancel()
        token = nil
        isSearching = false
    }

    func schedule(_ query: String, rootPath: String, includeHidden: Bool, debounceNanoseconds: UInt64 = 180_000_000) {
        cancel()
        results = []
        elapsedMs = 0
        diagnostic = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = AnalysisRequestToken(rootPath: rootPath)
        token = current
        isSearching = true
        let request = QuickSearchRequest(query: trimmed, rootPath: rootPath, includeHidden: includeHidden, token: current)
        let provider = self.provider
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            guard !current.isCancelled else { return }
            let bundle = provider(request)
            guard !current.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, current.canPublish(active: self.token, rootPath: rootPath) else { return }
                self.results = bundle.items
                self.elapsedMs = bundle.elapsedMilliseconds
                self.diagnostic = bundle.diagnostic ?? (bundle.isPartial ? "Wyniki częściowe." : nil)
                self.isSearching = false
            }
        }
    }
}

// MARK: - 1. Instant Cmd+P Spotlight fsearch Modal

@MainActor
public struct QuickFSearchSpotlightModal: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var queryText: String = ""
    @StateObject private var search = QuickSearchModel()
    private var results: [FileItem] { search.results }
    private var elapsedMs: Double { search.elapsedMs }
    @ViewState private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)

                TextField("Szybki skok fsearch (nazwa, ext:swift, grep:tekst, size:>10mb, tag:red)...", text: $queryText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($isFocused)
                    .onChange(of: queryText) { _, newValue in
                        runSpotlightQuery(newValue)
                    }
                    .onSubmit {
                        activateSelectedResult(revealInFolder: false)
                    }

                if !queryText.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                        Text(FormatHelpers.formatLatency(elapsedMs))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }

                Button("Zamknij") {
                    appState.showQuickFSearchModal = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .background(VisualEffectBackground(material: .headerView, blendingMode: .withinWindow))

            Divider()

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(search.isSearching ? "Wyszukiwanie…" : (queryText.isEmpty
                         ? "Wpisz zapytanie fsearch, aby przeszukać \(appState.indexedFileCount.formatted()) plików"
                         : (search.diagnostic == nil ? "Brak pasujących wyników" : "Brak wyników w sprawdzonym zakresie")))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        quickSampleButton("ext:swift")
                        quickSampleButton("type:code grep:struct")
                        quickSampleButton("git:modified")
                        quickSampleButton("mtime:<24h")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.prefix(100).enumerated()), id: \.element.id) { idx, item in
                            let isHighlighted = (idx == selectedIndex)
                            HStack(spacing: 10) {
                                Image(nsImage: FileIconCache.shared.icon(for: item))
                                    .resizable()
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(isHighlighted ? .white : .primary)
                                        if !item.tags.isEmpty {
                                            ForEach(item.tags) { tag in
                                                Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
                                            }
                                        }
                                        Text(FormatHelpers.formatBytes(item.size))
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                                    }
                                    Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                                        .lineLimit(1)

                                    if let grep = item.grepMatch {
                                        Text("L\(grep.lineNumber): \(grep.lineText)")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(isHighlighted ? .white : Color.accentColor)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                Button("Pokaż w karcie") {
                                    selectedIndex = idx
                                    activateSelectedResult(revealInFolder: true)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isHighlighted ? Color.accentColor : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = idx
                                activateSelectedResult(revealInFolder: true)
                            }
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            HStack {
                Text(search.diagnostic ?? "Kliknij lub Enter aby przejść do pliku/folderu · Esc aby zamknąć")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Indeks RAM/mmap: \(appState.indexedFileCount.formatted()) obiektów")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 680, height: 440)
        .onAppear { isFocused = true }
        .onDisappear { search.cancel() }
        .onChange(of: activeTab.currentURL.path) { _, _ in runSpotlightQuery(queryText) }
        .onChange(of: activeTab.showHiddenFiles) { _, _ in runSpotlightQuery(queryText) }
    }

    private func quickSampleButton(_ sample: String) -> some View {
        Button(sample) {
            queryText = sample
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func runSpotlightQuery(_ q: String) {
        selectedIndex = 0
        search.schedule(q, rootPath: activeTab.currentURL.path, includeHidden: activeTab.showHiddenFiles)
    }

    private func activateSelectedResult(revealInFolder: Bool) {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        let chosen = results[selectedIndex]
        appState.showQuickFSearchModal = false
        if chosen.isDirectory && !revealInFolder {
            activeTab.searchQuery = ""
            activeTab.navigate(to: chosen.url)
        } else {
            let parentURL = URL(fileURLWithPath: chosen.parentPath, isDirectory: true)
            activeTab.searchQuery = ""
            activeTab.navigate(to: parentURL)
            activeTab.selectedPaths = [chosen.path]
        }
    }
}

// MARK: - 2. New File Sheet

public struct NewFileSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var selectedTemplate: NewFileTemplate = .emptyText
    @ViewState private var filename: String = "Untitled.txt"
    @ViewState private var customContent: String = ""

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Utwórz nowy plik")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }

            Picker("Szablon pliku:", selection: $selectedTemplate) {
                ForEach(NewFileTemplate.allCases) { tpl in
                    Text(tpl.rawValue).tag(tpl)
                }
            }
            .onChange(of: selectedTemplate) { _, newValue in
                filename = newValue.defaultFilename
                customContent = newValue.initialContent
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Nazwa pliku:")
                    .font(.system(size: 12, weight: .medium))
                TextField("Nazwa pliku", text: $filename)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Początkowa zawartość (opcjonalnie):")
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: $customContent)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }

            HStack {
                Text("Lokalizacja: \(activeTab.currentURL.path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Anuluj") {
                    appState.showNewFileSheet = false
                }
                Button("Utwórz plik") {
                    if let created = FileOperationsManager.shared.createFile(
                        named: filename,
                        content: customContent,
                        in: activeTab.currentURL
                    ) {
                        activeTab.reloadDirectory()
                        activeTab.selectedPaths = [created.path]
                    }
                    appState.showNewFileSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - 3. New Folder Sheet

public struct NewFolderSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var folderName: String = "Nowy folder"

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Utwórz nowy folder")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }

            TextField("Nazwa folderu", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    createAndClose()
                }

            HStack {
                Spacer()
                Button("Anuluj") {
                    appState.showNewFolderSheet = false
                }
                Button("Utwórz") {
                    createAndClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func createAndClose() {
        if let created = FileOperationsManager.shared.createFolder(named: folderName, in: activeTab.currentURL) {
            activeTab.reloadDirectory()
            activeTab.selectedPaths = [created.path]
        }
        appState.showNewFolderSheet = false
    }
}

// MARK: - 4. Dual-Pane Folder Compare & Sync Sheet

public struct FolderCompareEntry: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case onlyLeft = "Tylko w lewym"
        case onlyRight = "Tylko w prawym"
        case modified = "Różna treść lub czas"
        case identical = "Zgodna treść i czas"
        case notCompared = "Podfolder: nieporównany"
        case typeConflict = "Różny typ: sprawdź ręcznie"
        case unreadable = "Nieodczytany / zmieniony"
    }
    public var id: String { name }
    public let name: String
    public let leftItem: FileItem?
    public let rightItem: FileItem?
    public let status: Status
}

/// Deliberately shallow comparison: common directories are UNKNOWN, never identical.
/// This UI copies selected top-level files; it is not a recursive mirror/synchronizer.
enum FolderComparison {
    static func compare(left: URL, right: URL, includeHidden: Bool, token: AnalysisRequestToken) -> (entries: [FolderCompareEntry], diagnostic: String?) {
        let leftRead = BulkCrawler.readDirectoryResult(at: left.path, includeHidden: includeHidden, isCancelled: { token.isCancelled })
        let rightRead = BulkCrawler.readDirectoryResult(at: right.path, includeHidden: includeHidden, isCancelled: { token.isCancelled })
        guard leftRead.isComplete && rightRead.isComplete else {
            return ([], "Nie można w pełni odczytać obu katalogów. Kopiowanie wyłączone.")
        }
        let leftMap = Dictionary(uniqueKeysWithValues: leftRead.entries.map { ($0.name, $0.toFileItem(loadTags: false)) })
        let rightMap = Dictionary(uniqueKeysWithValues: rightRead.entries.map { ($0.name, $0.toFileItem(loadTags: false)) })
        var entries: [FolderCompareEntry] = []
        for name in Set(leftMap.keys).union(rightMap.keys).sorted() {
            if token.isCancelled { return ([], nil) }
            let l = leftMap[name], r = rightMap[name]
            let status: FolderCompareEntry.Status
            if l == nil { status = .onlyRight }
            else if r == nil { status = .onlyLeft }
            else if let l, let r {
                if l.isDirectory != r.isDirectory || l.isSymlink != r.isSymlink { status = .typeConflict }
                else if l.isDirectory { status = .notCompared }
                else {
                    do {
                        if l.isSymlink {
                            let leftTarget = try FileManager.default.destinationOfSymbolicLink(atPath: l.path)
                            let rightTarget = try FileManager.default.destinationOfSymbolicLink(atPath: r.path)
                            status = leftTarget == rightTarget && l.modificationDate == r.modificationDate ? .identical : .modified
                        } else {
                            let lh = try DuplicateFileSafety.hash(at: l.url, isCancelled: { token.isCancelled })
                            let rh = try DuplicateFileSafety.hash(at: r.url, isCancelled: { token.isCancelled })
                            status = lh.hash == rh.hash && lh.snapshot.size == rh.snapshot.size
                                && lh.snapshot.modifiedSeconds == rh.snapshot.modifiedSeconds
                                && lh.snapshot.modifiedNanoseconds == rh.snapshot.modifiedNanoseconds ? .identical : .modified
                        }
                    } catch { status = .unreadable }
                }
            } else { status = .unreadable }
            entries.append(FolderCompareEntry(name: name, leftItem: l, rightItem: r, status: status))
        }
        return (entries, nil)
    }

    static func copyCandidates(_ entries: [FolderCompareEntry], leftToRight: Bool) -> [URL] {
        entries.compactMap { entry in
            guard entry.status == .modified || entry.status == (leftToRight ? .onlyLeft : .onlyRight) else { return nil }
            return leftToRight ? entry.leftItem?.url : entry.rightItem?.url
        }
    }
}

/// Both nested pane objects must be observed directly. AppState does not forward
/// their objectWillChange, and a same-path refresh is a new comparison generation.
struct FolderComparisonContext: Equatable, Sendable {
    let leftID: UUID
    let rightID: UUID
    let leftPath: String
    let rightPath: String
    let leftRevision: UInt64
    let rightRevision: UInt64
    let leftHidden: Bool
    let rightHidden: Bool

    @MainActor init(left: PaneTabState, right: PaneTabState) {
        leftID = left.id
        rightID = right.id
        leftPath = left.currentURL.path
        rightPath = right.currentURL.path
        leftRevision = left.directoryRevision
        rightRevision = right.directoryRevision
        leftHidden = left.showHiddenFiles
        rightHidden = right.showHiddenFiles
    }
}

public struct FolderCompareSheetView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        FolderComparisonContentView(appState: appState, leftPane: appState.leftTab, rightPane: appState.rightPane)
            .id(appState.leftTab.id.uuidString + appState.rightPane.id.uuidString)
    }
}

private struct FolderComparisonContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var leftPane: PaneTabState
    @ObservedObject var rightPane: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared

    @ViewState private var entries: [FolderCompareEntry] = []
    @ViewState private var hideIdentical: Bool = true
    @ViewState private var compareTask: Task<Void, Never>?
    @ViewState private var compareToken: AnalysisRequestToken?
    @ViewState private var isComparing = false
    @ViewState private var compareDiagnostic: String?
    @ViewState private var comparedContext: FolderComparisonContext?

    init(appState: AppState, leftPane: PaneTabState, rightPane: PaneTabState) {
        self.appState = appState
        self.leftPane = leftPane
        self.rightPane = rightPane
    }

    private var comparisonContext: FolderComparisonContext {
        FolderComparisonContext(left: leftPane, right: rightPane)
    }

    private var filteredEntries: [FolderCompareEntry] {
        hideIdentical ? entries.filter { $0.status != .identical } : entries
    }

    public var body: some View {
        let leftURL = leftPane.currentURL
        let rightURL = rightPane.currentURL

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Porównanie bezpośredniej zawartości katalogów")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Toggle("Ukryj identyczne", isOn: $hideIdentical)
                    .font(.system(size: 11.5))
            }

            HStack(spacing: 12) {
                Label("Lewy: \(leftURL.path)", systemImage: "folder.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("Prawy: \(rightURL.path)", systemImage: "folder.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)

            Divider()

            Text(compareDiagnostic ?? (isComparing ? "Porównywanie treści plików…" : "Porównanie treści i czasu plików, bez rekurencji. Wspólne podfoldery i konflikty typów wymagają osobnego porównania. Kopiowanie nie usuwa pozycji docelowych."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredEntries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.leftItem?.name ?? "—")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.leftItem == nil ? .tertiary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(entry.status.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(statusColor(entry.status).opacity(0.16), in: Capsule())
                                .foregroundStyle(statusColor(entry.status))

                            Text(entry.rightItem?.name ?? "—")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.rightItem == nil ? .tertiary : .primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(height: 230)

            HStack {
                Button("Kopiuj różnice Lewy → Prawy") { copyDifferences(leftToRight: true) }
                    .buttonStyle(.bordered)
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy)
                Button("Kopiuj różnice Prawy → Lewy") { copyDifferences(leftToRight: false) }
                    .buttonStyle(.bordered)
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy)

                Spacer()

                Button("Zamknij") {
                    appState.showCompareSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear { computeDiff() }
        .onChange(of: comparisonContext) { _, _ in computeDiff() }
        .onDisappear { compareToken?.cancel(); compareTask?.cancel() }
    }

    private func statusColor(_ status: FolderCompareEntry.Status) -> Color {
        switch status {
        case .onlyLeft: return .blue
        case .onlyRight: return .purple
        case .modified: return .orange
        case .identical: return .green
        case .notCompared: return .secondary
        case .typeConflict, .unreadable: return .red
        }
    }

    private func computeDiff() {
        compareToken?.cancel()
        compareTask?.cancel()
        let context = comparisonContext
        let left = leftPane.currentURL
        let right = rightPane.currentURL
        let includeHidden = context.leftHidden || context.rightHidden
        let token = AnalysisRequestToken(rootPath: left.path)
        compareToken = token
        entries = []
        compareDiagnostic = nil
        comparedContext = nil
        isComparing = true
        compareTask = Task.detached(priority: .userInitiated) {
            let result = FolderComparison.compare(left: left, right: right, includeHidden: includeHidden, token: token)
            await MainActor.run {
                guard token.canPublish(active: self.compareToken, rootPath: self.leftPane.currentURL.path),
                      context == self.comparisonContext else { return }
                self.entries = result.entries
                self.compareDiagnostic = result.diagnostic
                self.comparedContext = context
                self.isComparing = false
            }
        }
    }

    private func copyDifferences(leftToRight: Bool) {
        guard !isComparing, compareDiagnostic == nil, comparedContext == comparisonContext,
              let token = compareToken, token.canPublish(active: compareToken, rootPath: leftPane.currentURL.path) else { return }
        let candidates = FolderComparison.copyCandidates(entries, leftToRight: leftToRight)
        let destination = leftToRight ? rightPane.currentURL : leftPane.currentURL
        fileOps.performTransfer(sourceURLs: candidates, into: destination, isMove: false, explicitPolicy: .ask) { _ in
            guard token.canPublish(active: self.compareToken, rootPath: self.leftPane.currentURL.path) else { return }
            self.leftPane.reloadDirectory()
            self.rightPane.reloadDirectory()
            self.computeDiff()
        }
    }

}

// MARK: - 5. File Conflict Resolution Sheet

public struct ConflictResolutionSheetView: View {
    public let conflict: PendingTransferConflict
    @ObservedObject var fileOps = FileOperationsManager.shared

    public init(conflict: PendingTransferConflict) {
        self.conflict = conflict
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wykryto konflikt nazw plików (\(conflict.conflictingNames.count))")
                        .font(.system(size: 14.5, weight: .bold))
                    Text("W folderze docelowym '\(conflict.destinationDirectory.lastPathComponent)' istnieją już pliki o tych samych nazwach:")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conflict.conflictingNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.system(size: 11.5, design: .monospaced))
                            Spacer()
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 10) {
                Button("Anuluj") {
                    fileOps.pendingConflict = nil
                }

                Spacer()

                Button("Pomiń istniejące") {
                    resolveWith(.skip)
                }
                .buttonStyle(.bordered)

                Button("Zastąp istniejące") {
                    resolveWith(.overwrite)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)

                Button("Zachowaj oba (dopisz licznik)") {
                    resolveWith(.keepBoth)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 500)
    }

    private func resolveWith(_ policy: FileConflictPolicy) {
        let c = conflict
        fileOps.pendingConflict = nil
        fileOps.performTransfer(
            sourceURLs: c.sourceURLs,
            into: c.destinationDirectory,
            isMove: c.isMove,
            explicitPolicy: policy,
            copyAcrossVolumes: c.copyAcrossVolumes,
            completion: c.completion
        )
        AppState.shared.activeTab.reloadDirectory()
        if AppState.shared.isDualPane {
            AppState.shared.rightPane.reloadDirectory()
        }
    }
}

// MARK: - 6. Settings & fsearch Engine Configuration Sheet (Cmd+,)

public struct FSearchSettingsSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var fileOps = FileOperationsManager.shared

    @ViewState private var roots: [String] = FSearchIndex.shared.configuredRoots
    @ViewState private var skippedDirsText: String = FSearchIndex.shared.skippedDirectoryNames.sorted().joined(separator: ", ")
    @ViewState private var skipHeavyDirs: Bool = FSearchIndex.shared.skipHeavyDevDirs
    @ViewState private var useMMapCache: Bool = FSearchIndex.shared.usePersistentMMapCache
    @ViewState private var newRootPath: String = ""

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Ustawienia BetterFinder & Silnika fsearch")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
            }

            Divider()

            // Indexed Roots
            VStack(alignment: .leading, spacing: 6) {
                Text("Indeksowane katalogi (getattrlistbulk + FSEvents):")
                    .font(.system(size: 12, weight: .semibold))

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(roots, id: \.self) { root in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(root)
                                    .font(.system(size: 11.5, design: .monospaced))
                                Spacer()
                                Button {
                                    roots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .frame(height: 115)

                HStack(spacing: 6) {
                    TextField("Dodaj ścieżkę folderu (np. ~/Work)...", text: $newRootPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Dodaj") {
                        let exp = (newRootPath as NSString).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: exp) && !roots.contains(exp) {
                            roots.append(exp)
                            newRootPath = ""
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // Exclusions & MMap Cache
            Toggle("Pomijaj ciężkie katalogi deweloperskie i pamięć podręczną", isOn: $skipHeavyDirs)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Ignorowane nazwy katalogów (oddzielone przecinkami):")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("node_modules, .git, .build...", text: $skippedDirsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }

            Toggle("Trwały indeks binarny na dysku (mmap cache — start w 0 ms)", isOn: $useMMapCache)
                .font(.system(size: 12))

            Picker("Domyślna akcja przy konflikcie plików:", selection: $fileOps.defaultConflictPolicy) {
                ForEach(FileConflictPolicy.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .font(.system(size: 12))

            // Engine Diagnostics Footer
            HStack(spacing: 12) {
                Text("Plików w indeksie: \(appState.indexedFileCount.formatted())")
                Text("·")
                Text("Filtry Blooma trigramów: \(FSearchIndex.shared.trigramCacheCount)")
                Text("·")
                Text("Plik mmap: \((FSearchIndex.shared.cacheFilePath as NSString).lastPathComponent)")
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Zamknij") {
                    appState.showSettingsSheet = false
                }
                Button("Zapisz i przebuduj indeks") {
                    let parsedSkip = Set(
                        skippedDirsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    )
                    FSearchIndex.shared.skippedDirectoryNames = parsedSkip
                    FSearchIndex.shared.skipHeavyDevDirs = skipHeavyDirs
                    FSearchIndex.shared.usePersistentMMapCache = useMMapCache
                    appState.isIndexing = true
                    FSearchIndex.shared.startIndexing(roots: roots)
                    appState.showSettingsSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 540)
    }
}
