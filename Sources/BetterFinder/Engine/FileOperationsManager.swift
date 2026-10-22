import Foundation
import AppKit
import CryptoKit
import Darwin

public enum NewFileTemplate: String, CaseIterable, Identifiable {
    case emptyText = "Text File (.txt)"
    case markdown = "Markdown Document (.md)"
    case swift = "Swift Source (.swift)"
    case json = "JSON File (.json)"
    case python = "Python Script (.py)"
    case shell = "Shell Script (.sh)"

    public var id: String { rawValue }

    public var defaultFilename: String {
        switch self {
        case .emptyText: return "Untitled.txt"
        case .markdown: return "Notes.md"
        case .swift: return "File.swift"
        case .json: return "config.json"
        case .python: return "script.py"
        case .shell: return "run.sh"
        }
    }

    public var initialContent: String {
        switch self {
        case .emptyText: return ""
        case .markdown: return "# Title\n\n"
        case .swift: return "import Foundation\n\n"
        case .json: return "{\n  \n}\n"
        case .python: return "#!/usr/bin/env python3\n\n"
        case .shell: return "#!/usr/bin/env zsh\nset -euo pipefail\n\n"
        }
    }
}

public enum FileConflictPolicy: String, CaseIterable, Identifiable {
    case ask = "Pytaj przy konflikcie"
    case keepBoth = "Zachowaj oba (dopisz licznik)"
    case overwrite = "Zastąp istniejący"
    case skip = "Pomiń istniejący"

    public var id: String { rawValue }
}

public struct PendingTransferConflict: Identifiable {
    public let id = UUID()
    public let sourceURLs: [URL]
    public let destinationDirectory: URL
    public let conflictingNames: [String]
    public let isMove: Bool
    public let copyAcrossVolumes: Bool
}

public struct TransferProgressInfo {
    public let title: String
    public let currentFile: String
    public let completedCount: Int
    public let totalCount: Int
    public let isCancellable: Bool

    public init(title: String, currentFile: String, completedCount: Int, totalCount: Int, isCancellable: Bool = false) {
        self.title = title
        self.currentFile = currentFile
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.isCancellable = isCancellable
    }

    public var fraction: Double {
        guard totalCount > 0 else { return 1.0 }
        return Double(completedCount) / Double(totalCount)
    }
}

public struct UndoableFileOperation {
    public enum Kind {
        case moved(pairs: [(from: URL, to: URL)])
        case copied(created: [URL])
        case created(url: URL)
        case trashed(pairs: [(original: URL, trashed: URL)])
        case actions([FileHistoryAction])
    }
    public let label: String
    public let kind: Kind
}

/// Actions describe the next direction to execute, so replacement undo and redo keep
/// both the incoming item and the displaced original, including after a partial failure.
public enum FileHistoryAction {
    case move(from: URL, to: URL)
    case trash(URL)
}

struct FileOperationIO {
    var exists: (URL) -> Bool
    var createDirectory: (URL) throws -> Void
    var move: (URL, URL) throws -> Void
    var copy: (URL, URL) throws -> Void
    var trash: (URL) throws -> URL
    var removeEmptyDirectory: (URL) -> Void

    static let live = FileOperationIO(
        exists: { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        trash: { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let trashed = result as URL? else {
                throw FileOperationFailure(message: "Element „\(url.lastPathComponent)” jest w Koszu, ale system nie zwrócił ścieżki do przywrócenia.")
            }
            return trashed
        },
        removeEmptyDirectory: { url in
            // rmdir cannot recursively delete an item left behind by a failed transfer.
            _ = url.path.withCString { rmdir($0) }
        }
    )
}

struct FileOperationFailure: LocalizedError {
    let message: String
    var recoveryActions: [FileHistoryAction] = []
    var errorDescription: String? { message }
}

enum SafeFileReplacement {
    /// Fully prepare the incoming item before touching the destination. The staging
    /// directory is on the destination volume, so installation is a local move.
    static func replace(source: URL, target: URL, isMove: Bool, io: FileOperationIO = .live) throws -> [FileHistoryAction] {
        guard !source.standardizedFileURL.path.hasPrefix(target.standardizedFileURL.path + "/") else {
            throw FileOperationFailure(message: "Nie można zastąpić folderu zawierającego plik źródłowy.")
        }
        let stagingDirectory = target.deletingLastPathComponent()
            .appendingPathComponent(".betterfinder-transfer-\(UUID().uuidString)", isDirectory: true)
        let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
        try io.createDirectory(stagingDirectory)
        var displaced: URL?
        do {
            if isMove {
                try io.move(source, staged)
            } else {
                try io.copy(source, staged)
            }
            let original = try io.trash(target)
            displaced = original
            try io.move(staged, target)
            io.removeEmptyDirectory(stagingDirectory)
            let undoIncoming: FileHistoryAction = isMove ? .move(from: target, to: source) : .trash(target)
            return [undoIncoming, .move(from: original, to: target)]
        } catch {
            var details = [error.localizedDescription]
            var recoveryActions: [FileHistoryAction] = []
            if let displaced {
                do {
                    try io.move(displaced, target)
                } catch {
                    details.append("Nie przywrócono oryginału; zachowano go w \(displaced.path): \(error.localizedDescription)")
                    recoveryActions.append(.move(from: displaced, to: target))
                }
            }
            if isMove && io.exists(staged) {
                do {
                    try io.move(staged, source)
                } catch {
                    details.append("Plik źródłowy zachowano w \(staged.path): \(error.localizedDescription)")
                    recoveryActions.append(.move(from: staged, to: source))
                }
            }
            // Keep partial copies/moves for recovery; never remove an original as a fallback.
            if io.exists(staged) {
                details.append("Dane operacji zachowano w \(staged.path)")
            }
            io.removeEmptyDirectory(stagingDirectory)
            throw FileOperationFailure(message: details.joined(separator: "; "), recoveryActions: recoveryActions)
        }
    }
}

enum FileHistoryExecutor {
    struct Result {
        var inverse: [FileHistoryAction] = []
        var pending: [FileHistoryAction] = []
        var touchedDirectories = Set<String>()
        var completedCount = 0
        var error: String?
    }

    static func execute(_ actions: [FileHistoryAction], io: FileOperationIO = .live) -> Result {
        var result = Result()
        for (index, action) in actions.enumerated() {
            do {
                switch action {
                case .move(let from, let to):
                    try io.move(from, to)
                    result.inverse.append(.move(from: to, to: from))
                    result.touchedDirectories.insert(from.deletingLastPathComponent().path)
                    result.touchedDirectories.insert(to.deletingLastPathComponent().path)
                case .trash(let url):
                    let trashed = try io.trash(url)
                    result.inverse.append(.move(from: trashed, to: url))
                    result.touchedDirectories.insert(url.deletingLastPathComponent().path)
                }
                result.completedCount += 1
            } catch {
                result.pending = Array(actions[index...])
                result.error = error.localizedDescription
                break
            }
        }
        result.inverse.reverse()
        return result
    }
}

struct CutClipboardSnapshot {
    let changeCount: Int

    func remainingURLs(_ urls: [URL], internalChangeCount: Int, systemChangeCount: Int, movedSources: [URL]) -> [URL]? {
        guard internalChangeCount == changeCount, systemChangeCount == changeCount else { return nil }
        let movedPaths = Set(movedSources.map { $0.standardizedFileURL.path })
        return urls.filter { !movedPaths.contains($0.standardizedFileURL.path) }
    }
}

/// Thread-safe cancellation flag shared between the UI and a background transfer.
private final class TransferCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
public final class FileOperationsManager: ObservableObject {
    public static let shared = FileOperationsManager()

    public enum ClipboardMode {
        case copy
        case cut
    }

    @Published public private(set) var clipboardURLs: [URL] = []
    @Published public private(set) var clipboardMode: ClipboardMode = .copy
    @Published public var lastStatusMessage: String?

    // Undo / Redo Stacks
    @Published public private(set) var undoStack: [UndoableFileOperation] = []
    @Published public private(set) var redoStack: [UndoableFileOperation] = []

    // Conflict Resolution & Transfer Progress
    @Published public var defaultConflictPolicy: FileConflictPolicy = .ask {
        didSet { UserDefaults.standard.set(defaultConflictPolicy.rawValue, forKey: "bf.defaultConflictPolicy") }
    }
    @Published public var pendingConflict: PendingTransferConflict? = nil
    @Published public var activeTransfer: TransferProgressInfo? = nil

    /// `NSPasteboard.changeCount` captured when this app last wrote files to the pasteboard.
    /// Used to detect whether the internal cut/copy clipboard is still current.
    private var clipboardChangeCount: Int = -1
    private var transferCancellation: TransferCancellationFlag?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "bf.defaultConflictPolicy"),
           let policy = FileConflictPolicy(rawValue: raw) {
            defaultConflictPolicy = policy
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isBusy: Bool { activeTransfer != nil }

    public var undoLabel: String {
        guard let last = undoStack.last else { return "Cofnij" }
        return "Cofnij: \(last.label)"
    }

    public var redoLabel: String {
        guard let last = redoStack.last else { return "Ponów" }
        return "Ponów: \(last.label)"
    }

    public func isCut(_ path: String) -> Bool {
        guard clipboardMode == .cut, NSPasteboard.general.changeCount == clipboardChangeCount else { return false }
        return clipboardURLs.contains { $0.path == path }
    }

    // MARK: - Undo / Redo Engine (Cmd+Z / Cmd+Shift+Z)

    private func pushUndo(_ op: UndoableFileOperation) {
        undoStack.append(op)
        if undoStack.count > 40 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func undoLastOperation() {
        applyHistory(isUndo: true)
    }

    public func redoLastOperation() {
        applyHistory(isUndo: false)
    }

    private func applyHistory(isUndo: Bool) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        guard let op = isUndo ? undoStack.popLast() : redoStack.popLast() else {
            lastStatusMessage = isUndo ? "Brak operacji do cofnięcia" : "Brak operacji do ponowienia"
            return
        }
        let actions: [FileHistoryAction]
        switch op.kind {
        case .moved(let pairs):
            actions = pairs.reversed().map { .move(from: $0.to, to: $0.from) }
        case .copied(let created):
            actions = created.reversed().map { .trash($0) }
        case .created(let url):
            actions = [.trash(url)]
        case .trashed(let pairs):
            actions = pairs.map {
                let destination = FileOperationIO.live.exists($0.original) ? Self.uniqueURL(for: $0.original) : $0.original
                return .move(from: $0.trashed, to: destination)
            }
        case .actions(let stored):
            actions = stored
        }
        let result = FileHistoryExecutor.execute(actions)
        if !result.pending.isEmpty {
            let pending = UndoableFileOperation(label: op.label, kind: .actions(result.pending))
            if isUndo { undoStack.append(pending) } else { redoStack.append(pending) }
        }
        if !result.inverse.isEmpty {
            let inverse = UndoableFileOperation(label: op.label, kind: .actions(result.inverse))
            if isUndo { redoStack.append(inverse) } else { undoStack.append(inverse) }
        }
        let message: String
        if let error = result.error {
            message = "Nie udało się \(isUndo ? "cofnąć" : "ponowić"): \(op.label) (\(result.completedCount) z \(actions.count) kroków): \(error)"
        } else {
            message = "\(isUndo ? "Cofnięto" : "Ponowiono"): \(op.label)"
        }
        finishUndoRedo(touchedDirs: result.touchedDirectories, message: message)
    }

    private func finishUndoRedo(touchedDirs: Set<String>, message: String) {
        for dir in touchedDirs {
            FSearchIndex.shared.refreshDirectoryInIndex(dir)
            FolderSizeCache.shared.invalidate(containing: dir)
        }
        lastStatusMessage = message
        AppState.shared.reloadVisiblePanes()
    }

    // MARK: - Copy / Cut / Paste / Drop with Conflict Detection & Progress

    public func copyItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        writeClipboard(items.map(\.url), mode: .copy)
        lastStatusMessage = "Skopiowano \(items.count) elem. do schowka"
    }

    public func cutItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        writeClipboard(items.map(\.url), mode: .cut)
        lastStatusMessage = "Wycięto \(items.count) elem. (Cmd+V aby przenieść)"
    }

    private func writeClipboard(_ urls: [URL], mode: ClipboardMode) {
        clipboardURLs = urls
        clipboardMode = mode
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        clipboardChangeCount = pb.changeCount
    }

    /// Pastes files from the clipboard. Uses the internal cut/copy state only if nobody else
    /// has written to the system pasteboard since; otherwise falls back to file URLs on the pasteboard.
    public func paste(into destinationDirectory: URL, explicitPolicy: FileConflictPolicy? = nil) {
        let pb = NSPasteboard.general
        var sourceURLs: [URL] = []
        var isMove = false

        if !clipboardURLs.isEmpty && pb.changeCount == clipboardChangeCount {
            sourceURLs = clipboardURLs
            isMove = (clipboardMode == .cut)
        } else {
            clipboardURLs = []
            clipboardMode = .copy
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let pbURLs = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
                sourceURLs = pbURLs
            }
        }
        guard !sourceURLs.isEmpty else {
            lastStatusMessage = "Schowek nie zawiera plików do wklejenia"
            return
        }
        performTransfer(
            sourceURLs: sourceURLs,
            into: destinationDirectory,
            isMove: isMove,
            explicitPolicy: explicitPolicy
        )
    }

    /// Drag & drop: moves within the same volume, copies across volumes (Finder semantics).
    /// Holding Option forces a copy.
    public func handleDropURLs(_ urls: [URL], into destinationDirectory: URL, copyInsteadOfMove: Bool = false) {
        let destPath = destinationDirectory.standardizedFileURL.path
        let validURLs = urls.filter {
            let p = $0.standardizedFileURL.path
            return p != destPath && $0.standardizedFileURL.deletingLastPathComponent().path != destPath
        }
        guard !validURLs.isEmpty else { return }
        performTransfer(
            sourceURLs: validURLs,
            into: destinationDirectory,
            isMove: !copyInsteadOfMove,
            explicitPolicy: nil,
            copyAcrossVolumes: true
        )
    }

    /// Copies or moves files on a background task, reporting progress in `activeTransfer`.
    /// - Parameter copyAcrossVolumes: when `true`, a move whose source lives on another volume becomes a copy.
    public func performTransfer(
        sourceURLs: [URL],
        into destinationDirectory: URL,
        isMove: Bool,
        explicitPolicy: FileConflictPolicy? = nil,
        copyAcrossVolumes: Bool = false,
        completion: (@MainActor ([URL]) -> Void)? = nil
    ) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        let fm = FileManager.default
        let policy = explicitPolicy ?? defaultConflictPolicy
        let destPath = destinationDirectory.standardizedFileURL.path

        // Never copy/move a folder into itself or one of its own subfolders.
        var validSources: [URL] = []
        var rejectedNested = 0
        for src in sourceURLs {
            let srcPath = src.standardizedFileURL.path
            if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                rejectedNested += 1
                continue
            }
            validSources.append(src)
        }
        guard !validSources.isEmpty else {
            if rejectedNested > 0 {
                lastStatusMessage = "Nie można umieścić folderu wewnątrz samego siebie"
            }
            return
        }

        // Check for conflicts if policy == .ask
        if policy == .ask {
            var conflicts: [String] = []
            for src in validSources {
                let dst = destinationDirectory.appendingPathComponent(src.lastPathComponent)
                if dst.standardizedFileURL.path != src.standardizedFileURL.path && fm.fileExists(atPath: dst.path) {
                    conflicts.append(src.lastPathComponent)
                }
            }
            if !conflicts.isEmpty {
                pendingConflict = PendingTransferConflict(
                    sourceURLs: validSources,
                    destinationDirectory: destinationDirectory,
                    conflictingNames: conflicts,
                    isMove: isMove,
                    copyAcrossVolumes: copyAcrossVolumes
                )
                return
            }
        }

        let total = validSources.count
        let clipboardSnapshot = isMove && clipboardMode == .cut && NSPasteboard.general.changeCount == clipboardChangeCount
            ? CutClipboardSnapshot(changeCount: clipboardChangeCount) : nil
        let title = isMove ? "Przenoszenie" : "Kopiowanie"
        let flag = TransferCancellationFlag()
        transferCancellation = flag
        activeTransfer = TransferProgressInfo(
            title: title,
            currentFile: validSources[0].lastPathComponent,
            completedCount: 0,
            totalCount: total,
            isCancellable: total > 1
        )

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var resultURLs: [URL] = []
            var copiedURLs: [URL] = []
            var movedPairs: [(from: URL, to: URL)] = []
            var undoActions: [FileHistoryAction] = []
            var skipped = rejectedNested
            var touchedDirs = Set<String>([destinationDirectory.path])
            var errors: [String] = []
            var lastProgressUpdate = DispatchTime.now().uptimeNanoseconds

            for (idx, src) in validSources.enumerated() {
                if flag.isCancelled { break }

                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastProgressUpdate > 50_000_000 || idx == 0 {
                    lastProgressUpdate = now
                    let info = TransferProgressInfo(
                        title: title,
                        currentFile: src.lastPathComponent,
                        completedCount: idx,
                        totalCount: total,
                        isCancellable: total > 1
                    )
                    await MainActor.run { FileOperationsManager.shared.activeTransfer = info }
                }

                let doMove = isMove && (!copyAcrossVolumes || Self.isSameVolume(src, destinationDirectory))
                var targetURL = destinationDirectory.appendingPathComponent(src.lastPathComponent)
                var replacesExisting = false
                if targetURL.standardizedFileURL.path == src.standardizedFileURL.path {
                    if doMove { skipped += 1; continue }
                    targetURL = Self.uniqueURL(for: targetURL)
                } else if FileOperationIO.live.exists(targetURL) {
                    switch policy {
                    case .skip:
                        skipped += 1
                        continue
                    case .overwrite:
                        replacesExisting = true
                    case .keepBoth, .ask:
                        targetURL = Self.uniqueURL(for: targetURL)
                    }
                }

                touchedDirs.insert(src.deletingLastPathComponent().path)
                do {
                    let itemUndo: [FileHistoryAction]
                    if replacesExisting {
                        itemUndo = try SafeFileReplacement.replace(source: src, target: targetURL, isMove: doMove)
                    } else if doMove {
                        try fm.moveItem(at: src, to: targetURL)
                        itemUndo = [.move(from: targetURL, to: src)]
                    } else {
                        try fm.copyItem(at: src, to: targetURL)
                        itemUndo = [.trash(targetURL)]
                    }
                    undoActions.append(contentsOf: itemUndo.reversed())
                    if doMove {
                        movedPairs.append((from: src, to: targetURL))
                    } else {
                        copiedURLs.append(targetURL)
                    }
                    resultURLs.append(targetURL)
                } catch {
                    errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
                    if let failure = error as? FileOperationFailure {
                        undoActions.append(contentsOf: failure.recoveryActions.reversed())
                    }
                }
            }

            for dir in touchedDirs {
                FSearchIndex.shared.refreshDirectoryInIndex(dir)
            }

            let wasCancelled = flag.isCancelled
            let finalMoved = movedPairs
            let finalCopied = copiedURLs
            let finalUndo = Array(undoActions.reversed())
            let finalSkipped = skipped
            let finalResults = resultURLs
            let finalError = errors.isEmpty ? nil : errors.joined(separator: "; ")
            let finalTouched = touchedDirs

            await MainActor.run {
                let manager = FileOperationsManager.shared
                manager.activeTransfer = nil
                manager.transferCancellation = nil

                if !finalUndo.isEmpty {
                    let label = finalResults.isEmpty ? "Przywrócenie danych po błędzie" : "Transfer \(finalResults.count) elem."
                    manager.pushUndo(UndoableFileOperation(label: label, kind: .actions(finalUndo)))
                }
                if let clipboardSnapshot, !finalMoved.isEmpty,
                   manager.clipboardMode == .cut,
                   let remaining = clipboardSnapshot.remainingURLs(
                    manager.clipboardURLs,
                    internalChangeCount: manager.clipboardChangeCount,
                    systemChangeCount: NSPasteboard.general.changeCount,
                    movedSources: finalMoved.map { $0.from }
                   ) {
                    manager.writeClipboard(remaining, mode: remaining.isEmpty ? .copy : .cut)
                }

                if let err = finalError {
                    manager.lastStatusMessage = "Błąd operacji (ukończono \(finalResults.count) z \(total)): \(err)"
                } else if wasCancelled {
                    manager.lastStatusMessage = "Przerwano – \(title.lowercased()) \(finalResults.count) z \(total) elem."
                } else {
                    manager.lastStatusMessage = "Przeniesiono \(finalMoved.count), skopiowano \(finalCopied.count), pominięto \(finalSkipped) elem."
                }

                for dir in finalTouched {
                    FolderSizeCache.shared.invalidate(containing: dir)
                }
                AppState.shared.reloadVisiblePanes()
                completion?(finalResults)
            }
        }
    }

    public func cancelActiveTransfer() {
        transferCancellation?.cancel()
    }

    // MARK: - Create Folder / Create File

    @discardableResult
    public func createFolder(named name: String, in directory: URL) -> URL? {
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa folderu"
            return nil
        }
        let fm = FileManager.default
        let target = Self.uniqueURL(for: directory.appendingPathComponent(safeName))
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            pushUndo(UndoableFileOperation(label: "Utworzenie folderu \(target.lastPathComponent)", kind: .created(url: target)))
            FSearchIndex.shared.refreshDirectoryInIndex(directory.path)
            lastStatusMessage = "Utworzono folder \(target.lastPathComponent)"
            return target
        } catch {
            lastStatusMessage = "Nie udało się utworzyć folderu: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func createFile(named name: String, content: String = "", in directory: URL) -> URL? {
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa pliku"
            return nil
        }
        let target = Self.uniqueURL(for: directory.appendingPathComponent(safeName))
        do {
            try content.write(to: target, atomically: true, encoding: .utf8)
            if safeName.hasSuffix(".sh") || content.hasPrefix("#!") {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            pushUndo(UndoableFileOperation(label: "Utworzenie pliku \(target.lastPathComponent)", kind: .created(url: target)))
            FSearchIndex.shared.refreshDirectoryInIndex(directory.path)
            lastStatusMessage = "Utworzono plik \(target.lastPathComponent)"
            return target
        } catch {
            lastStatusMessage = "Nie udało się utworzyć pliku: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Rename / Batch Rename / Duplicate / Trash

    @discardableResult
    public func renameItem(_ item: FileItem, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard let safeName = Self.validatedFileName(trimmed) else {
            lastStatusMessage = "Nazwa nie może zawierać znaku „/” ani być „.” lub „..”"
            return nil
        }
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(safeName)
        let isCaseOnlyChange = safeName.lowercased() == item.name.lowercased()
        if !isCaseOnlyChange && FileManager.default.fileExists(atPath: dst.path) {
            lastStatusMessage = "Element o nazwie „\(safeName)” już istnieje"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            pushUndo(UndoableFileOperation(label: "Zmiana nazwy \(item.name) → \(safeName)", kind: .moved(pairs: [(from: item.url, to: dst)])))
            FSearchIndex.shared.refreshDirectoryInIndex(item.parentPath)
            lastStatusMessage = "Zmieniono nazwę na \(safeName)"
            return dst
        } catch {
            lastStatusMessage = "Błąd zmiany nazwy: \(error.localizedDescription)"
            return nil
        }
    }

    /// Asks for confirmation and permanently removes everything in `~/.Trash`.
    public func emptySystemTrash(completion: (@MainActor () -> Void)? = nil) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        let trashPath = "\(NSHomeDirectory())/.Trash"
        let fm = FileManager.default
        let items: [String]
        do {
            items = try fm.contentsOfDirectory(atPath: trashPath)
        } catch {
            lastStatusMessage = "Nie można odczytać Kosza: \(error.localizedDescription)"
            return
        }
        guard !items.isEmpty else {
            lastStatusMessage = "Kosz jest pusty"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Czy na pewno opróżnić Kosz?"
        alert.informativeText = "Elementy (\(items.count)) zostaną trwale usunięte. Tej operacji nie można cofnąć."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Opróżnij Kosz")
        alert.addButton(withTitle: "Anuluj")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The modal alert runs a nested event loop, during which another operation can start.
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }

        activeTransfer = TransferProgressInfo(title: "Opróżnianie Kosza", currentFile: "\(items.count) elem.", completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) {
            var removed: [URL] = []
            var lastError: String?
            for name in items {
                let url = URL(fileURLWithPath: trashPath).appendingPathComponent(name)
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(url)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            FSearchIndex.shared.refreshDirectoryInIndex(trashPath)
            let removedURLs = removed
            let finalError = lastError
            await MainActor.run {
                let manager = FileOperationsManager.shared
                manager.activeTransfer = nil
                // Undo entries pointing into the Trash are no longer restorable.
                manager.undoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.redoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.lastStatusMessage = finalError.map {
                    "Nie opróżniono całego Kosza (usunięto \(removedURLs.count) z \(items.count)): \($0)"
                } ?? "Opróżniono Kosz (usunięto \(removedURLs.count) elem.)"
                AppState.shared.reloadVisiblePanes()
                completion?()
            }
        }
    }

    @discardableResult
    public func duplicateItems(_ items: [FileItem]) -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for item in items {
            let dst = Self.uniqueURL(for: item.url, suffixWord: " copy")
            if (try? fm.copyItem(at: item.url, to: dst)) != nil {
                created.append(dst)
                FSearchIndex.shared.refreshDirectoryInIndex(item.parentPath)
            }
        }
        if !created.isEmpty {
            pushUndo(UndoableFileOperation(label: "Duplikacja \(created.count) elem.", kind: .copied(created: created)))
        }
        lastStatusMessage = "Zduplikowano \(created.count) elem."
        return created
    }

    public func moveToTrash(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let fm = FileManager.default
        var trashedPairs: [(original: URL, trashed: URL)] = []
        var failures = 0
        for item in items {
            var resultingURL: NSURL? = nil
            if (try? fm.trashItem(at: item.url, resultingItemURL: &resultingURL)) != nil {
                if let trashed = resultingURL as URL? {
                    trashedPairs.append((original: item.url, trashed: trashed))
                }
                FSearchIndex.shared.refreshDirectoryInIndex(item.parentPath)
                FolderSizeCache.shared.invalidate(containing: item.parentPath)
            } else {
                failures += 1
            }
        }
        if !trashedPairs.isEmpty {
            pushUndo(UndoableFileOperation(label: "Kosz (\(trashedPairs.count) elem.)", kind: .trashed(pairs: trashedPairs)))
        }
        if failures > 0 {
            lastStatusMessage = "Nie udało się przenieść do Kosza \(failures) elem. (brak uprawnień?)"
        } else {
            lastStatusMessage = "Przeniesiono do Kosza: \(trashedPairs.count) elem. (Cmd+Z aby przywrócić)"
        }
    }

    // MARK: - Native macOS Finder Color Tags

    public func toggleTag(_ color: FinderTagColor, for items: [FileItem]) {
        guard !items.isEmpty else { return }
        // When tagging several items, either add the tag to all of them or (if all have it) remove it.
        do {
            let tags = try items.map { item in
                try FinderTagColor.readTagNames(for: item.url).compactMap { FinderTagColor.from(rawTagName: $0) }
            }
            let allHaveTag = tags.allSatisfy { $0.contains(color) }
            var failures = 0
            var lastError: String?
            for (item, existing) in zip(items, tags) {
                var current = existing
                if allHaveTag {
                    current.removeAll { $0 == color }
                } else if !current.contains(color) {
                    current.append(color)
                }
                do {
                    try FinderTagColor.writeTags(current, to: item.url)
                } catch {
                    failures += 1
                    lastError = error.localizedDescription
                }
            }
            lastStatusMessage = lastError.map { "Nie zaktualizowano tagów dla \(failures) z \(items.count) elem.: \($0)" }
                ?? "Zaktualizowano tagi (\(color.displayName))"
        } catch {
            lastStatusMessage = "Nie można odczytać tagów: \(error.localizedDescription)"
        }
    }

    public func clearTags(for items: [FileItem]) {
        guard !items.isEmpty else { return }
        var failures = 0
        var lastError: String?
        for item in items {
            do {
                try FinderTagColor.clearAllTags(for: item.url)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }
        lastStatusMessage = lastError.map { "Nie wyczyszczono tagów dla \(failures) z \(items.count) elem.: \($0)" }
            ?? "Wyczyszczono tagi"
    }

    // MARK: - Open With & Native Share Sheet

    public func availableApplications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    public func open(_ url: URL, withApplication appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    public func showShareSheet(for items: [FileItem]) {
        guard !items.isEmpty,
              let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: items.map(\.url))
        let mouse = contentView.window?.mouseLocationOutsideOfEventStream ?? .zero
        let local = contentView.convert(mouse, from: nil)
        let rect = NSRect(x: local.x, y: local.y, width: 1, height: 1)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Compress & One-Click Archive Extraction

    public func compressItems(_ items: [FileItem], in directory: URL) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        guard !items.isEmpty else { return }
        let parents = Set(items.map { $0.url.deletingLastPathComponent().path })
        // Items from search results may live in different folders – archive next to the first one.
        let workingDir = parents.count == 1 ? items[0].url.deletingLastPathComponent() : directory
        let archiveBaseName = items.count == 1 ? "\(items[0].url.deletingPathExtension().lastPathComponent).zip" : "Archiwum.zip"
        let dstURL = Self.uniqueURL(for: workingDir.appendingPathComponent(archiveBaseName))
        let names = parents.count == 1 ? items.map { $0.url.lastPathComponent } : items.map(\.path)

        activeTransfer = TransferProgressInfo(title: "Kompresowanie", currentFile: dstURL.lastPathComponent, completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) {
            let status = Self.runProcess("/usr/bin/zip", arguments: ["-r", "-q", "-y", dstURL.path] + names, in: workingDir)
            FSearchIndex.shared.refreshDirectoryInIndex(workingDir.path)
            await MainActor.run {
                let manager = FileOperationsManager.shared
                manager.activeTransfer = nil
                if status == 0 {
                    manager.pushUndo(UndoableFileOperation(label: "Utworzenie archiwum \(dstURL.lastPathComponent)", kind: .created(url: dstURL)))
                    manager.lastStatusMessage = "Utworzono archiwum \(dstURL.lastPathComponent)"
                } else {
                    manager.lastStatusMessage = "Kompresja nie powiodła się (kod \(status))"
                }
                AppState.shared.reloadVisiblePanes()
            }
        }
    }

    public func extractArchive(_ item: FileItem) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        let parentDir = item.url.deletingLastPathComponent()
        let ext = item.fileExtension.lowercased()
        let lowerName = item.name.lowercased()

        if ext == "dmg" {
            // Disk images are mounted, not extracted.
            Task.detached(priority: .userInitiated) {
                let status = Self.runProcess("/usr/bin/hdiutil", arguments: ["attach", item.path], in: parentDir)
                await MainActor.run {
                    FileOperationsManager.shared.lastStatusMessage = status == 0
                        ? "Zamontowano obraz \(item.name)"
                        : "Nie udało się zamontować \(item.name) (kod \(status))"
                    AppState.shared.refreshMountedVolumes()
                }
            }
            return
        }

        var baseFolder = item.url.deletingPathExtension().lastPathComponent
        if baseFolder.lowercased().hasSuffix(".tar") {
            baseFolder = String(baseFolder.dropLast(4))
        }
        let targetDir = Self.uniqueURL(for: parentDir.appendingPathComponent(baseFolder, isDirectory: true))
        let isTarball = ext == "tar" || ext == "tgz" || lowerName.hasSuffix(".tar.gz") ||
                        lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tar.xz")

        activeTransfer = TransferProgressInfo(title: "Rozpakowywanie", currentFile: item.name, completedCount: 0, totalCount: 1)

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let status: Int32
            if isTarball {
                status = Self.runProcess("/usr/bin/tar", arguments: ["-xf", item.path, "-C", targetDir.path], in: parentDir)
            } else if ext == "gz" || ext == "bz2" || ext == "xz" {
                // Single compressed file (not a tarball): decompress with libarchive's "raw" mode.
                let outName = item.url.deletingPathExtension().lastPathComponent
                status = Self.runProcess("/bin/sh", arguments: ["-c", "/usr/bin/tar -xOf \"$0\" > \"$1\"", item.path, targetDir.appendingPathComponent(outName).path], in: parentDir)
            } else {
                // zip, 7z (if supported by ditto/libarchive), etc.
                status = Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", item.path, targetDir.path], in: parentDir)
            }

            if status != 0, let contents = try? fm.contentsOfDirectory(atPath: targetDir.path), contents.isEmpty {
                try? fm.removeItem(at: targetDir)
            }
            FSearchIndex.shared.refreshDirectoryInIndex(parentDir.path)

            await MainActor.run {
                let manager = FileOperationsManager.shared
                manager.activeTransfer = nil
                if status == 0 {
                    manager.pushUndo(UndoableFileOperation(label: "Rozpakowanie \(item.name)", kind: .created(url: targetDir)))
                    manager.lastStatusMessage = "Rozpakowano do: \(targetDir.lastPathComponent)"
                } else {
                    manager.lastStatusMessage = "Nie udało się rozpakować \(item.name) (kod \(status))"
                }
                AppState.shared.reloadVisiblePanes()
            }
        }
    }

    // MARK: - POSIX Permissions (chmod) & Checksums (SHA-256 / MD5)

    @discardableResult
    public func setPosixPermissions(_ mode: UInt16, for item: FileItem) -> Bool {
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: item.path)
            lastStatusMessage = String(format: "Zmieniono uprawnienia %@ na %03o", item.name, mode & 0o777)
            return true
        } catch {
            lastStatusMessage = "Błąd chmod: \(error.localizedDescription)"
            return false
        }
    }

    /// Streams the file in 1 MB chunks so even multi-GB files can be hashed without loading them into RAM.
    nonisolated public static func computeHashes(for url: URL) -> (sha256: String, md5: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
                chunk = data
            } catch {
                return nil
            }
            sha.update(data: chunk)
            md5.update(data: chunk)
        }
        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        return (shaHex, md5Hex)
    }

    // MARK: - Developer & Power User Actions

    public func copyPaths(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let joined = items.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        lastStatusMessage = items.count == 1
            ? "Skopiowano ścieżkę: \(items[0].path)"
            : "Skopiowano \(items.count) ścieżek"
    }

    public func copyPathString(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        lastStatusMessage = "Skopiowano ścieżkę: \(path)"
    }

    public func openInTerminal(at url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let targetDir = isDir.boolValue ? url : url.deletingLastPathComponent()
        let candidates = [
            "/Applications/iTerm.app",
            "/Applications/Ghostty.app",
            "/Applications/Warp.app",
            "/System/Applications/Utilities/Terminal.app"
        ]
        let appPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.last!

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([targetDir], withApplicationAt: URL(fileURLWithPath: appPath), configuration: config)
        lastStatusMessage = "Otwarto w Terminalu: \(targetDir.lastPathComponent)"
    }

    public func openInCodeEditor(at url: URL) {
        let editors = [
            "/Applications/Cursor.app",
            "/Applications/Visual Studio Code.app",
            "/Applications/Zed.app",
            "/Applications/Sublime Text.app"
        ]
        if let found = editors.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: found), configuration: config)
            lastStatusMessage = "Otwarto w edytorze kodu"
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    public func revealInAppleFinder(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    // MARK: - Git Status Detection

    nonisolated public static func fetchGitStatusMap(for directoryPath: String) -> [String: GitFileStatus] {
        // 1. Cheap check whether we are inside a work tree at all.
        guard let rootData = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: ["rev-parse", "--show-toplevel"],
            in: URL(fileURLWithPath: directoryPath)
        ) else { return [:] }
        guard let gitRoot = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gitRoot.isEmpty else {
            return [:]
        }

        // 2. NUL-separated porcelain output: no quoting/escaping of non-ASCII (e.g. Polish) file names.
        guard let data = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "-uall"],
            in: URL(fileURLWithPath: directoryPath)
        ), !data.isEmpty else {
            return [:]
        }

        var statusMap: [String: GitFileStatus] = [:]
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i < records.count {
            let record = Array(records[i])
            i += 1
            guard record.count > 3 else { continue }
            let x = record[0]
            let y = record[1]
            let relPath = String(decoding: record[3...], as: UTF8.self)
            // Renames/copies are followed by an extra record holding the original path.
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") {
                i += 1
            }

            let status: GitFileStatus
            if x == UInt8(ascii: "?") {
                status = .untracked
            } else if x == UInt8(ascii: "R") || y == UInt8(ascii: "R") {
                status = .renamed
            } else if x == UInt8(ascii: "D") || y == UInt8(ascii: "D") {
                status = .deleted
            } else if x != UInt8(ascii: " ") {
                status = .staged
            } else {
                status = .modified
            }
            statusMap["\(gitRoot)/\(relPath)"] = status
        }
        FSearchIndex.shared.recordGitStatuses(statusMap)
        return statusMap
    }

    // MARK: - Helpers

    nonisolated private static func referencesRemovedItems(_ kind: UndoableFileOperation.Kind, removed: [URL]) -> Bool {
        let urls: [URL]
        switch kind {
        case .moved(let pairs): urls = pairs.flatMap { [$0.from, $0.to] }
        case .copied(let created): urls = created
        case .created(let url): urls = [url]
        case .trashed(let pairs): urls = pairs.flatMap { [$0.original, $0.trashed] }
        case .actions(let actions):
            urls = actions.flatMap { action -> [URL] in
                switch action {
                case .move(let from, let to): return [from, to]
                case .trash(let url): return [url]
                }
            }
        }
        return urls.contains { url in
            let path = url.standardizedFileURL.path
            return removed.contains {
                let removedPath = $0.standardizedFileURL.path
                return path == removedPath || path.hasPrefix(removedPath + "/")
            }
        }
    }

    public func uniqueDestinationURL(for url: URL, suffixWord: String = "") -> URL {
        Self.uniqueURL(for: url, suffixWord: suffixWord)
    }

    nonisolated public static func uniqueURL(for url: URL, suffixWord: String = "") -> URL {
        let fm = FileManager.default
        if suffixWord.isEmpty && !fm.fileExists(atPath: url.path) {
            return url
        }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))

        var counter = 1
        while true {
            let suffix = counter == 1 && !suffixWord.isEmpty ? suffixWord : "\(suffixWord) \(counter)"
            let candidateName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let candidateURL = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
    }

    /// Returns a trimmed, safe single path component or `nil` if the name is invalid.
    nonisolated public static func validatedFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\0") else { return nil }
        return trimmed
    }

    nonisolated static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: keys).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: keys).volumeIdentifier else {
            return false
        }
        return (va as AnyObject).isEqual(vb)
    }

    @discardableResult
    nonisolated static func runProcess(_ executable: String, arguments: [String], in directory: URL) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Runs a process and returns its stdout if it exited with status 0.
    nonisolated static func runProcessCapturingOutput(_ executable: String, arguments: [String], in directory: URL) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        let outPipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }
}
