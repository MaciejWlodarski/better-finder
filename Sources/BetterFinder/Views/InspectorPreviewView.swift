import SwiftUI
import AppKit

public struct InspectorPreviewView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var folderSizes = FolderSizeCache.shared
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject private var iconCache = FileIconCache.shared

    @ViewState private var textPreviewLines: [(Int, String)] = []
    @ViewState private var posixPermissionsString: String = "—"
    @ViewState private var currentModeBits: UInt16 = 0o644
    @ViewState private var showChmodEditor: Bool = false
    @ViewState private var sha256Hash: String? = nil
    @ViewState private var md5Hash: String? = nil
    @ViewState private var isComputingHash: Bool = false
    @ViewState private var hashRequestID = UUID()

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text("Inspektor")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if activeTab.primarySelectedItem != nil {
                    Button {
                        appState.toggleQuickLook()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.system(size: 10))
                            Text("Quick Look")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Otwórz natywny Quick Look (Spacja)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if activeTab.selectedItems.count > 1 {
                selectionSummary
            } else if let item = activeTab.primarySelectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        // Top Identity Card
                        HStack(spacing: 12) {
                            Image(nsImage: FileIconCache.shared.icon(for: item))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .lineLimit(2)
                                Text(item.kindDisplayString)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                if let git = item.gitStatus {
                                    Text("Git: \(git.badgeDescription)")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                        }

                        // Interactive macOS Color Tags Picker
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tagi macOS")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(FinderTagColor.allCases) { tagColor in
                                    let isTagged = item.tags.contains(tagColor)
                                    Button {
                                        fileOps.toggleTag(tagColor, for: [item])
                                        activeTab.reloadDirectory()
                                    } label: {
                                        Circle()
                                            .fill(tagColor.swiftUIColor)
                                            .frame(width: 16, height: 16)
                                            .overlay(
                                                Circle()
                                                    .stroke(isTagged ? Color.primary : Color.clear, lineWidth: 2)
                                            )
                                            .scaleEffect(isTagged ? 1.15 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                    .help(tagColor.displayName)
                                }
                                Spacer()
                                if !item.tags.isEmpty {
                                    Button("Wyczyść") {
                                        fileOps.clearTags(for: [item])
                                        activeTab.reloadDirectory()
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))

                        // Live Visual Preview (Image or Code/Text)
                        livePreviewBox(for: item)

                        Divider()

                        // Metadata + Interactive chmod Permissions
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Szczegóły i uprawnienia")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            metadataRow(
                                label: "Rozmiar",
                                value: item.isDirectory
                                    ? (folderSizes.displaySize(for: item.path) ?? "Obliczanie...")
                                    : FormatHelpers.formatBytes(item.size)
                            )
                            metadataRow(label: "Zmodyfikowano", value: FormatHelpers.formatDate(item.modificationDate))

                            // Interactive POSIX chmod row
                            HStack {
                                Text("Uprawnienia")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(posixPermissionsString)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Button {
                                    showChmodEditor.toggle()
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Edytuj uprawnienia POSIX (chmod)")
                            }

                            if showChmodEditor {
                                chmodEditorBox(for: item)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Pełna ścieżka:")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Text(item.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        // Checksums (SHA-256 & MD5) for Files
                        if !item.isDirectory {
                            Divider()
                            checksumsSection(for: item)
                        }

                        Divider()

                        // Quick Actions Grid
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Szybkie akcje")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            if item.isExtractableArchive {
                                inspectorActionButton(title: "Rozpakuj archiwum tutaj", icon: "archivebox.fill") {
                                    fileOps.extractArchive(item)
                                }
                            }

                            HStack(spacing: 6) {
                                inspectorActionButton(title: "Terminal", icon: "terminal") {
                                    fileOps.openInTerminal(at: item.url)
                                }
                                inspectorActionButton(title: "Edytor", icon: "chevron.left.forwardslash.chevron.right") {
                                    fileOps.openInCodeEditor(at: item.url)
                                }
                            }
                            HStack(spacing: 6) {
                                inspectorActionButton(title: "Kopiuj ścieżkę", icon: "doc.on.doc") {
                                    fileOps.copyPaths([item])
                                }
                                inspectorActionButton(title: "Udostępnij", icon: "square.and.arrow.up") {
                                    fileOps.showShareSheet(for: [item])
                                }
                            }
                            HStack(spacing: 6) {
                                inspectorActionButton(title: "Duplikuj", icon: "plus.square.on.square") {
                                    fileOps.duplicateItems([item])
                                    activeTab.reloadDirectory()
                                }
                                inspectorActionButton(title: "Kosz", icon: "trash", isDestructive: true) {
                                    fileOps.moveToTrash([item])
                                    activeTab.reloadDirectory()
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: item.path) { _, _ in
                    hashRequestID = UUID()
                    isComputingHash = false
                    sha256Hash = nil
                    md5Hash = nil
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: activeTab.directoryRevision) { _, _ in
                    hashRequestID = UUID()
                    isComputingHash = false
                    sha256Hash = nil
                    md5Hash = nil
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: folderSizes.result(for: item.path)) { _, result in
                    if item.isDirectory && result == nil {
                        folderSizes.requestSizeIfNeeded(for: item.path)
                    }
                }
                .onDisappear {
                    hashRequestID = UUID()
                    isComputingHash = false
                    sha256Hash = nil
                    md5Hash = nil
                }
            } else {
                // Current Folder Summary when no file is selected
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                            .resizable()
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeTab.currentURL.lastPathComponent.isEmpty ? "Macintosh HD" : activeTab.currentURL.lastPathComponent)
                                .font(.system(size: 13.5, weight: .bold))
                            Text("\(activeTab.displayedItems.count) elementów w widoku")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Text("Wskazówki skrótów:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 5) {
                        shortcutHintRow(keys: "Cmd + F", desc: "Szukaj fsearch na pasku")
                        shortcutHintRow(keys: "Cmd + P", desc: "Okno Spotlight fsearch")
                        shortcutHintRow(keys: "Spacja", desc: "Natywny podgląd Quick Look")
                        shortcutHintRow(keys: "Cmd + Z", desc: "Cofnij operację plikową")
                        shortcutHintRow(keys: "Cmd + X / V", desc: "Wytnij i przenieś pliki")
                        shortcutHintRow(keys: "Ctrl + `", desc: "Wbudowany dolny panel Terminala")
                        shortcutHintRow(keys: "Cmd + ,", desc: "Ustawienia indeksu fsearch")
                        shortcutHintRow(keys: "Cmd + Shift + D", desc: "Widok dwupanelowy (Dual Pane)")
                        shortcutHintRow(keys: "Cmd + L", desc: "Edytuj pasek adresu ręcznie")
                    }

                    Spacer()
                }
                .padding(14)
            }
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow))
    }

    private var selectionSummary: some View {
        let items = activeTab.selectedItems
        let folders = items.filter(\.isDirectory)
        let knownBytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? (folderSizes.result(for: $1.path)?.bytes ?? 0) : $1.size) }
        let hasUnknownSize = folders.contains { folderSizes.size(for: $0.path) == nil }
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
            Text("\(items.count) zaznaczonych elementów")
                .font(.system(size: 17, weight: .semibold))
            VStack(spacing: 10) {
                metadataRow(label: "Pliki", value: "\(items.count - folders.count)")
                metadataRow(label: "Foldery", value: "\(folders.count)")
                metadataRow(label: "Rozmiar", value: "\(hasUnknownSize ? "≥ " : "")\(FormatHelpers.formatBytes(knownBytes))")
            }
            .font(.system(size: 12))
            Divider()
            Button("Podgląd zaznaczenia", systemImage: "eye") { appState.toggleQuickLook() }
            Button("Udostępnij…", systemImage: "square.and.arrow.up") { fileOps.showShareSheet(for: items) }
            Button("Kopiuj ścieżki", systemImage: "link") { fileOps.copyPaths(items) }
            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: items.map(\.path)) {
            for folder in folders { folderSizes.requestSizeIfNeeded(for: folder.path) }
        }
        .onChange(of: folderSizes.results) { _, _ in
            for folder in folders where folderSizes.result(for: folder.path) == nil {
                folderSizes.requestSizeIfNeeded(for: folder.path)
            }
        }
    }

    // MARK: - Interactive chmod Box

    private func chmodEditorBox(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Szybki chmod:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("644 (rw-r--r--)") { applyChmod(0o644, for: item) }
                    .buttonStyle(.bordered).controlSize(.mini)
                Button("755 (+x exec)") { applyChmod(0o755, for: item) }
                    .buttonStyle(.bordered).controlSize(.mini)
                Button("700 (rwx------)") { applyChmod(0o700, for: item) }
                    .buttonStyle(.bordered).controlSize(.mini)
            }

            HStack(spacing: 12) {
                chmodBitGroup(label: "Owner", rBit: 0o400, wBit: 0o200, xBit: 0o100, item: item)
                chmodBitGroup(label: "Group", rBit: 0o040, wBit: 0o020, xBit: 0o010, item: item)
                chmodBitGroup(label: "Other", rBit: 0o004, wBit: 0o002, xBit: 0o001, item: item)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .disabled(fileOps.isBusy)
    }

    private func chmodBitGroup(label: String, rBit: UInt16, wBit: UInt16, xBit: UInt16, item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                chmodBitButton("r", bit: rBit, item: item)
                chmodBitButton("w", bit: wBit, item: item)
                chmodBitButton("x", bit: xBit, item: item)
            }
        }
    }

    private func chmodBitButton(_ title: String, bit: UInt16, item: FileItem) -> some View {
        let isSet = (currentModeBits & bit) != 0
        return Button {
            let newMode = isSet ? (currentModeBits & ~bit) : (currentModeBits | bit)
            applyChmod(newMode, for: item)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 18, height: 18)
                .foregroundStyle(isSet ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSet ? Color.accentColor : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func applyChmod(_ mode: UInt16, for item: FileItem) {
        let requestedMode = mode & 0o777
        guard !activeTab.actionItems(for: item).isEmpty,
              fileOps.setPosixPermissions(requestedMode, for: item) else { return }
        currentModeBits = requestedMode
        posixPermissionsString = String(format: "%@ (%03o)", Self.formatModeBits(currentModeBits), currentModeBits)
    }

    // MARK: - Checksums Section (SHA-256 / MD5)

    private func checksumsSection(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sumy kontrolne (SHA-256 / MD5)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if sha256Hash == nil {
                    Button {
                        isComputingHash = true
                        let requestID = UUID()
                        hashRequestID = requestID
                        let url = item.url
                        DispatchQueue.global(qos: .userInitiated).async {
                            let hashes = FileOperationsManager.computeHashes(for: url)
                            Task { @MainActor in
                                guard self.hashRequestID == requestID,
                                      self.activeTab.primarySelectedItem?.path == url.path else { return }
                                self.sha256Hash = hashes?.sha256
                                self.md5Hash = hashes?.md5
                                self.isComputingHash = false
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isComputingHash {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "number.square")
                            }
                            Text("Oblicz hash")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isComputingHash)
                }
            }

            if let sha = sha256Hash {
                hashDisplayRow(label: "SHA-256", value: sha)
            }
            if let md5 = md5Hash {
                hashDisplayRow(label: "MD5", value: md5)
            }
        }
    }

    private func hashDisplayRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Kopiuj") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    fileOps.lastStatusMessage = "Skopiowano \(label): \(value.prefix(16))..."
                }
                .font(.system(size: 9.5))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private func livePreviewBox(for item: FileItem) -> some View {
        if item.kindCategory == .image, let nsImg = NSImage(contentsOf: item.url) {
            VStack(spacing: 4) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(Int(nsImg.size.width)) × \(Int(nsImg.size.height)) px")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else if !textPreviewLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Podgląd treści")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let grep = item.grepMatch {
                        Text("Trafienie w linii \(grep.lineNumber)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 1.5) {
                        ForEach(textPreviewLines, id: \.0) { lineNo, text in
                            let isMatchedLine = (item.grepMatch?.lineNumber == lineNo)
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(lineNo)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(isMatchedLine ? Color.accentColor : .secondary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(text.isEmpty ? " " : text)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(isMatchedLine ? Color.primary : Color.primary.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isMatchedLine ? Color.accentColor.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                        }
                    }
                    .padding(6)
                }
                .frame(height: 185)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func shortcutHintRow(keys: String, desc: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func inspectorActionButton(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func loadPreviewAndMetadata(for item: FileItem) {
        if item.isDirectory {
            folderSizes.requestSizeIfNeeded(for: item.path)
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path),
           let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.uint16Value & 0o777
            currentModeBits = mode
            posixPermissionsString = String(format: "%@ (%03o)", Self.formatModeBits(mode), mode)
        } else {
            posixPermissionsString = "—"
        }

        guard !item.isDirectory && item.size > 0 && item.size <= 2 * 1024 * 1024 else {
            textPreviewLines = []
            return
        }

        guard let fh = try? FileHandle(forReadingFrom: item.url),
              let sampleData = try? fh.read(upToCount: 24 * 1024) else {
            textPreviewLines = []
            return
        }
        try? fh.close()

        if sampleData.prefix(512).contains(0) {
            textPreviewLines = []
            return
        }

        let str = String(decoding: sampleData, as: UTF8.self)
        let rawLines = str.components(separatedBy: .newlines)
        let targetLine = item.grepMatch?.lineNumber ?? 1
        let startIdx = min(rawLines.count, max(0, targetLine - 15))
        let endIdx = min(rawLines.count, startIdx + 90)
        var numbered: [(Int, String)] = []
        for idx in startIdx..<endIdx {
            numbered.append((idx + 1, rawLines[idx]))
        }
        textPreviewLines = numbered
    }

    private static func formatModeBits(_ mode: UInt16) -> String {
        let chars: [Character] = [
            (mode & 0o400) != 0 ? "r" : "-",
            (mode & 0o200) != 0 ? "w" : "-",
            (mode & 0o100) != 0 ? "x" : "-",
            (mode & 0o040) != 0 ? "r" : "-",
            (mode & 0o020) != 0 ? "w" : "-",
            (mode & 0o010) != 0 ? "x" : "-",
            (mode & 0o004) != 0 ? "r" : "-",
            (mode & 0o002) != 0 ? "w" : "-",
            (mode & 0o001) != 0 ? "x" : "-"
        ]
        return String(chars)
    }
}
