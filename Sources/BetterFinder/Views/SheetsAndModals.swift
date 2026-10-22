import SwiftUI
import AppKit

// MARK: - 1. Instant Cmd+P Spotlight fsearch Modal

public struct QuickFSearchSpotlightModal: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var queryText: String = ""
    @ViewState private var results: [FileItem] = []
    @ViewState private var elapsedMs: Double = 0
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
                    Text(queryText.isEmpty
                         ? "Wpisz zapytanie fsearch, aby przeszukać \(appState.indexedFileCount.formatted()) plików w < 1 ms"
                         : "Brak pasujących wyników")
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
                Text("Kliknij lub Enter aby przejść do pliku/folderu · Esc aby zamknąć")
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
        .onAppear {
            isFocused = true
        }
    }

    private func quickSampleButton(_ sample: String) -> some View {
        Button(sample) {
            queryText = sample
            runSpotlightQuery(sample)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func runSpotlightQuery(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            elapsedMs = 0
            return
        }
        let bundle = FSearchIndex.shared.search(
            rawQuery: trimmed,
            scope: .wholeIndex,
            scopeDirectory: activeTab.currentURL.path,
            includeHidden: activeTab.showHiddenFiles,
            fuzzyEnabled: true
        )
        results = bundle.items
        elapsedMs = bundle.elapsedMilliseconds
        selectedIndex = 0
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

public struct FolderCompareEntry: Identifiable {
    public enum Status: String {
        case onlyLeft = "Tylko w lewym"
        case onlyRight = "Tylko w prawym"
        case modified = "Różny rozmiar/czas"
        case identical = "Identyczne"
    }
    public var id: String { name }
    public let name: String
    public let leftItem: FileItem?
    public let rightItem: FileItem?
    public let status: Status
}

public struct FolderCompareSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var fileOps = FileOperationsManager.shared

    @ViewState private var entries: [FolderCompareEntry] = []
    @ViewState private var hideIdentical: Bool = true

    public init(appState: AppState) {
        self.appState = appState
    }

    private var filteredEntries: [FolderCompareEntry] {
        hideIdentical ? entries.filter { $0.status != .identical } : entries
    }

    public var body: some View {
        let leftURL = appState.leftTab.currentURL
        let rightURL = appState.rightPane.currentURL

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("Porównanie i synchronizacja katalogów (Dual-Pane)")
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
                Button("Synchronizuj Lewy → Prawy") {
                    let toCopy = entries.compactMap { e -> URL? in
                        guard e.status == .onlyLeft || e.status == .modified else { return nil }
                        return e.leftItem?.url
                    }
                    fileOps.performTransfer(sourceURLs: toCopy, into: rightURL, isMove: false, explicitPolicy: .overwrite)
                    appState.rightPane.reloadDirectory()
                    computeDiff()
                }
                .buttonStyle(.bordered)

                Button("Synchronizuj Prawy → Lewy") {
                    let toCopy = entries.compactMap { e -> URL? in
                        guard e.status == .onlyRight || e.status == .modified else { return nil }
                        return e.rightItem?.url
                    }
                    fileOps.performTransfer(sourceURLs: toCopy, into: leftURL, isMove: false, explicitPolicy: .overwrite)
                    appState.leftTab.reloadDirectory()
                    computeDiff()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Zamknij") {
                    appState.showCompareSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear {
            computeDiff()
        }
    }

    private func statusColor(_ status: FolderCompareEntry.Status) -> Color {
        switch status {
        case .onlyLeft: return .blue
        case .onlyRight: return .purple
        case .modified: return .orange
        case .identical: return .green
        }
    }

    private func computeDiff() {
        let leftMap = Dictionary(uniqueKeysWithValues: appState.leftTab.directoryItems.map { ($0.name, $0) })
        let rightMap = Dictionary(uniqueKeysWithValues: appState.rightPane.directoryItems.map { ($0.name, $0) })
        let allNames = Set(leftMap.keys).union(rightMap.keys).sorted()

        var list: [FolderCompareEntry] = []
        for name in allNames {
            let l = leftMap[name]
            let r = rightMap[name]
            let status: FolderCompareEntry.Status
            if l != nil && r == nil {
                status = .onlyLeft
            } else if l == nil && r != nil {
                status = .onlyRight
            } else if let li = l, let ri = r {
                status = (li.size == ri.size) ? .identical : .modified
            } else {
                status = .identical
            }
            list.append(FolderCompareEntry(name: name, leftItem: l, rightItem: r, status: status))
        }
        entries = list
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
            copyAcrossVolumes: c.copyAcrossVolumes
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
