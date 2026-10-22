import SwiftUI
import AppKit

public struct PathBreadcrumbSegment: Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let isRoot: Bool
}

public struct PathBreadcrumbBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ViewState private var editablePathText: String = ""
    @ViewState private var pathValidationMessage: String? = nil
    @FocusState private var isPathFieldFocused: Bool

    public init(appState: AppState, pane: PaneTabState) {
        self.appState = appState
        self.pane = pane
    }

    private var segments: [PathBreadcrumbSegment] {
        var result: [PathBreadcrumbSegment] = []
        var runningURL = URL(fileURLWithPath: "/", isDirectory: true)
        let rootName = appState.mountedVolumes.first { $0.url.path == "/" }?.name ?? "/"

        for (index, component) in pane.currentURL.pathComponents.enumerated() {
            if index == 0 && component == "/" {
                result.append(PathBreadcrumbSegment(name: rootName, url: runningURL, isRoot: true))
            } else {
                runningURL = runningURL.appendingPathComponent(component, isDirectory: true)
                result.append(PathBreadcrumbSegment(name: component, url: runningURL, isRoot: false))
            }
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if pane.isEditingPathBar {
                    pathEditor
                } else {
                    breadcrumbTrail
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 2) {
                        pathActionButton(icon: "pencil", label: "Edytuj ścieżkę", help: "Przejdź do folderu (⌘L)") {
                            beginEditing()
                        }
                        pathActionButton(icon: "doc.on.doc", label: "Kopiuj ścieżkę bieżącego folderu", help: pane.currentURL.path) {
                            FileOperationsManager.shared.copyPathString(pane.currentURL.path)
                        }
                        folderActionsMenu
                    }
                    .fixedSize()
                }
            }

            if pane.isEditingPathBar, let pathValidationMessage {
                Label(pathValidationMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(FinderUI.captionFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
        .font(FinderUI.bodyFont)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onChange(of: pane.isEditingPathBar) { _, isEditing in
            if !isEditing {
                pathValidationMessage = nil
                isPathFieldFocused = false
            }
        }
    }

    private var breadcrumbTrail: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        breadcrumbButton(segment)
                            .id(segment.id)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            .onAppear {
                scrollProxy.scrollTo(pane.currentURL.path, anchor: .trailing)
            }
            .onChange(of: pane.currentURL) { _, url in
                scrollProxy.scrollTo(url.path, anchor: .trailing)
            }
            .help(pane.currentURL.path)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                beginEditing()
            }
        }
        .frame(height: 28)
    }

    private func breadcrumbButton(_ segment: PathBreadcrumbSegment) -> some View {
        let isCurrent = segment.url.path == pane.currentURL.path

        return Button {
            navigate(to: segment.url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: segment.isRoot ? "internaldrive" : "folder")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(segment.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(segment.url.path)
        .accessibilityLabel(segment.name)
        .accessibilityValue(isCurrent ? "Bieżący folder" : segment.url.path)
        .accessibilityHint("Otwiera folder. Menu kontekstowe zawiera działania dla tego folderu.")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            folderContextActions(for: segment.url)
        }
    }

    private var pathEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            TextField("Ścieżka folderu, np. ~/Documents", text: $editablePathText)
                .textFieldStyle(.plain)
                .font(FinderUI.bodyFont)
                .focused($isPathFieldFocused)
                .accessibilityLabel("Ścieżka folderu")
                .accessibilityHint(pathValidationMessage ?? "Return otwiera folder, Escape anuluje. Możesz użyć ~ lub ścieżki względnej.")
                .help("Wpisz ścieżkę bezwzględną, ścieżkę względem bieżącego folderu lub użyj ~ dla folderu domowego.")
                .onSubmit {
                    submitPath()
                }
                .onExitCommand {
                    cancelEditing()
                }
                .onChange(of: editablePathText) { _, _ in
                    pathValidationMessage = nil
                }

            Button("Idź") {
                submitPath()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Otwórz wpisany folder (Return)")

            pathActionButton(icon: "xmark", label: "Anuluj edycję ścieżki", help: "Anuluj (Escape)") {
                cancelEditing()
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                .strokeBorder(pathValidationMessage == nil ? Color.accentColor : Color.red, lineWidth: 1)
        }
        .onAppear {
            editablePathText = pane.currentURL.path
            pathValidationMessage = nil
            isPathFieldFocused = true
        }
    }

    private var folderActionsMenu: some View {
        Menu {
            folderContextActions(for: pane.currentURL)

            if !pane.selectedItems.isEmpty {
                Button {
                    FileOperationsManager.shared.copyPaths(pane.selectedItems)
                } label: {
                    Label("Kopiuj ścieżki zaznaczonych elementów", systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button {
                activatePane()
                appState.showNewFileSheet = true
            } label: {
                Label("Nowy plik…", systemImage: "doc.badge.plus")
            }
            Button {
                activatePane()
                appState.showNewFolderSheet = true
            } label: {
                Label("Nowy folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: FinderUI.iconButtonSize, height: FinderUI.iconButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Działania dla bieżącego folderu")
        .accessibilityLabel("Działania dla bieżącego folderu")
    }

    @ViewBuilder
    private func folderContextActions(for url: URL) -> some View {
        Button {
            appState.addNewTab(at: url)
        } label: {
            Label("Otwórz w nowej karcie", systemImage: "plus.square.on.square")
        }
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Otwórz w Finderze", systemImage: "folder")
        }
        Button {
            FileOperationsManager.shared.copyPathString(url.path)
        } label: {
            Label("Kopiuj ścieżkę folderu", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            FileOperationsManager.shared.openInTerminal(at: url)
        } label: {
            Label("Otwórz w Terminalu", systemImage: "terminal")
        }
        Button {
            FileOperationsManager.shared.openInCodeEditor(at: url)
        } label: {
            Label("Otwórz w edytorze kodu", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Button {
            appState.addBookmark(for: url)
        } label: {
            Label("Przypnij folder do paska bocznego", systemImage: "pin")
        }
        .disabled(appState.customBookmarks.contains { $0.url.path == url.path })
    }

    private func pathActionButton(icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: FinderUI.iconButtonSize, height: FinderUI.iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

    private func beginEditing() {
        editablePathText = pane.currentURL.path
        pathValidationMessage = nil
        pane.isEditingPathBar = true
    }

    private func cancelEditing() {
        pane.isEditingPathBar = false
        isPathFieldFocused = false
        pathValidationMessage = nil
    }

    private func submitPath() {
        let expandedPath = (editablePathText as NSString).expandingTildeInPath
        guard !expandedPath.isEmpty else {
            pathValidationMessage = "Wpisz ścieżkę folderu."
            isPathFieldFocused = true
            return
        }

        let baseURL = URL(fileURLWithPath: pane.currentURL.path, isDirectory: true)
        let targetURL = URL(fileURLWithPath: expandedPath, isDirectory: true, relativeTo: baseURL).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            pathValidationMessage = "Nie znaleziono folderu pod podaną ścieżką."
            isPathFieldFocused = true
            return
        }

        navigate(to: targetURL)
        cancelEditing()
    }

    private func navigate(to url: URL) {
        pane.searchQuery = ""
        pane.activeFilterPills = []
        pane.navigate(to: url)
    }

    private func activatePane() {
        if appState.isDualPane {
            appState.activePaneSide = pane.id == appState.rightPane.id ? .right : .left
        }
    }
}
