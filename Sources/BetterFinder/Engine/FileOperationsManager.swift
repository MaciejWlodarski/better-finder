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
    public let completion: (@MainActor ([URL]) -> Void)?
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

public struct GitStatusSnapshot: Sendable {
    /// Inspection deliberately never executes conversion helpers. With configured
    /// filters (including LFS), raw bytes can look modified even when trusted Git's
    /// filtered comparison would be clean. Submodule contents are not inspected.
    public let usesRawContentComparison: Bool
    public let repositoryRoot: String
    public let statuses: [String: GitFileStatus]
}

public struct UndoableFileOperation {
    public enum Kind {
        case moved(pairs: [(from: URL, to: URL)])
        case copied(created: [URL])
        case created(url: URL)
        case trashed(pairs: [(original: URL, trashed: URL)])
        case actions([FileHistoryAction])
    }
    /// Both stacks retain this identity while a transaction is only partly applied.
    public let transactionID: UUID
    public let label: String
    public let kind: Kind

    public init(label: String, kind: Kind, transactionID: UUID = UUID()) {
        self.transactionID = transactionID
        self.label = label
        self.kind = kind
    }
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
    var publishExclusive: (URL, URL) throws -> Void
    var trash: (URL) throws -> URL
    var removeEmptyDirectory: (URL) -> Void

    static let live = FileOperationIO(
        exists: { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        publishExclusive: { try SafeArchivePublication.moveExclusive(from: $0, to: $1) },
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

/// Archive subprocesses only touch privately reserved staging paths. Final
/// publication is one same-filesystem, no-replace rename, not a check-then-move.
enum SafeArchivePublication {
    static func stagingDirectory(in parent: URL) throws -> URL {
        let staging = parent.appendingPathComponent(".betterfinder-archive-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return staging
    }

    static func moveExclusive(from source: URL, to destination: URL) throws {
        // Some network/filesystem implementations do not support exclusive
        // rename. Do not fall back to a racy check followed by ordinary rename.
        let parent = destination.deletingLastPathComponent()
        let capabilities = try parent.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        guard capabilities.volumeSupportsExclusiveRenaming == true else {
            throw FileOperationFailure(message: "Ten wolumin nie obsługuje bezpiecznego publikowania bez zastępowania; zachowano dane tymczasowe.")
        }
        let result = source.path.withCString { from in
            destination.path.withCString { to in
                Darwin.renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
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
        didSet {
            #if !BETTERFINDER_TESTING
            UserDefaults.standard.set(defaultConflictPolicy.rawValue, forKey: "bf.defaultConflictPolicy")
            #endif
        }
    }
    @Published public var pendingConflict: PendingTransferConflict? = nil
    @Published public private(set) var activeTransfer: TransferProgressInfo? = nil

    /// `NSPasteboard.changeCount` captured when this app last wrote files to the pasteboard.
    /// Used to detect whether the internal cut/copy clipboard is still current.
    private var clipboardChangeCount: Int = -1
    private var transferCancellation: TransferCancellationFlag?

    private let fileIO: FileOperationIO
    private let reloadVisiblePanes: @MainActor () -> Void
    nonisolated private let enqueueDirectoryRefresh: @Sendable (String) -> Void

    // Internal injection keeps regression tests on the actual manager path without
    // touching the user's Trash, clipboard, or visible panes.
    init(fileIO: FileOperationIO = .live,
         reloadVisiblePanes: @escaping @MainActor () -> Void = { AppState.shared.reloadVisiblePanes() },
         enqueueDirectoryRefresh: @escaping @Sendable (String) -> Void = { FSearchIndex.shared.enqueueDirectoryRefresh($0) }) {
        self.fileIO = fileIO
        self.reloadVisiblePanes = reloadVisiblePanes
        self.enqueueDirectoryRefresh = enqueueDirectoryRefresh
        #if !BETTERFINDER_TESTING
        if let raw = UserDefaults.standard.string(forKey: "bf.defaultConflictPolicy"),
           let policy = FileConflictPolicy(rawValue: raw) {
            defaultConflictPolicy = policy
        }
        #endif
    }

    public var canUndo: Bool { !isBusy && !undoStack.isEmpty }
    public var canRedo: Bool { !isBusy && !redoStack.isEmpty }
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

    /// All file-mutating entry points share this gate, including context-menu and
    /// inspector actions. MainActor checks and acquisition cannot interleave.
    private func canStartMutation() -> Bool {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return false
        }
        return true
    }

    private func beginMutation(title: String, currentFile: String = "", totalCount: Int = 1) -> Bool {
        guard canStartMutation() else { return false }
        activeTransfer = TransferProgressInfo(title: title, currentFile: currentFile,
                                              completedCount: 0, totalCount: totalCount)
        return true
    }

    private func applyHistory(isUndo: Bool) {
        guard canStartMutation() else { return }
        guard let op = isUndo ? undoStack.popLast() : redoStack.popLast() else {
            lastStatusMessage = isUndo ? "Brak operacji do cofnięcia" : "Brak operacji do ponowienia"
            return
        }
        // Acquire before dispatch, not inside the worker: another mutation must
        // never alter paths/history while this transaction is in flight.
        activeTransfer = TransferProgressInfo(title: isUndo ? "Cofanie" : "Ponawianie",
                                              currentFile: op.label, completedCount: 0, totalCount: 1)
        let io = fileIO
        Task.detached(priority: .userInitiated) { [self] in
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
                    let destination = io.exists($0.original) ? Self.uniqueURL(for: $0.original) : $0.original
                    return .move(from: $0.trashed, to: destination)
                }
            case .actions(let stored):
                actions = stored
            }
            let result = FileHistoryExecutor.execute(actions, io: io)
            for dir in result.touchedDirectories {
                self.enqueueDirectoryRefresh(dir)
            }
            await MainActor.run {
                if !result.pending.isEmpty {
                    let pending = UndoableFileOperation(label: op.label, kind: .actions(result.pending), transactionID: op.transactionID)
                    if isUndo { self.undoStack.append(pending) } else { self.redoStack.append(pending) }
                }
                if !result.inverse.isEmpty {
                    // Retrying or reversing a partial transaction must reconnect
                    // its completed prefix to the still-pending suffix.
                    if isUndo {
                        Self.appendHistoryInverse(result.inverse, for: op, to: &self.redoStack)
                    } else {
                        Self.appendHistoryInverse(result.inverse, for: op, to: &self.undoStack)
                    }
                }
                let message: String
                if let error = result.error {
                    message = "Nie udało się \(isUndo ? "cofnąć" : "ponowić"): \(op.label) (\(result.completedCount) z \(actions.count) kroków): \(error)"
                } else {
                    message = "\(isUndo ? "Cofnięto" : "Ponowiono"): \(op.label)"
                }
                self.activeTransfer = nil
                self.finishUndoRedo(touchedDirs: result.touchedDirectories, message: message)
            }
        }
    }

    private static func appendHistoryInverse(_ actions: [FileHistoryAction], for operation: UndoableFileOperation,
                                             to stack: inout [UndoableFileOperation]) {
        var combined = actions
        if let prior = stack.last, prior.transactionID == operation.transactionID,
           case .actions(let pending) = prior.kind {
            stack.removeLast()
            combined += pending
        }
        stack.append(UndoableFileOperation(label: operation.label, kind: .actions(combined),
                                          transactionID: operation.transactionID))
    }

    private func finishUndoRedo(touchedDirs: Set<String>, message: String) {
        for dir in touchedDirs {
            FolderSizeCache.shared.invalidate(containing: dir)
        }
        lastStatusMessage = message
        reloadVisiblePanes()
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
        let io = fileIO
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
                if dst.standardizedFileURL.path != src.standardizedFileURL.path && io.exists(dst) {
                    conflicts.append(src.lastPathComponent)
                }
            }
            if !conflicts.isEmpty {
                pendingConflict = PendingTransferConflict(
                    sourceURLs: validSources,
                    destinationDirectory: destinationDirectory,
                    conflictingNames: conflicts,
                    isMove: isMove,
                    copyAcrossVolumes: copyAcrossVolumes,
                    completion: completion
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

        Task.detached(priority: .userInitiated) { [self, validSources, rejectedNested] in
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
                    await MainActor.run { self.activeTransfer = info }
                }

                let doMove = isMove && (!copyAcrossVolumes || Self.isSameVolume(src, destinationDirectory))
                var targetURL = destinationDirectory.appendingPathComponent(src.lastPathComponent)
                var replacesExisting = false
                if targetURL.standardizedFileURL.path == src.standardizedFileURL.path {
                    if doMove { skipped += 1; continue }
                    targetURL = Self.uniqueURL(for: targetURL)
                } else if io.exists(targetURL) {
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
                        itemUndo = try SafeFileReplacement.replace(source: src, target: targetURL, isMove: doMove, io: io)
                    } else if doMove {
                        try io.move(src, targetURL)
                        itemUndo = [.move(from: targetURL, to: src)]
                    } else {
                        try io.copy(src, targetURL)
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
                self.enqueueDirectoryRefresh(dir)
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
                let manager = self
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
                manager.reloadVisiblePanes()
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
        guard beginMutation(title: "Tworzenie folderu") else { return nil }
        defer { activeTransfer = nil }
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa folderu"
            return nil
        }
        let fm = FileManager.default
        do {
            let target = try Self.createUniqueItem(at: directory.appendingPathComponent(safeName)) { target in
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            }
            pushUndo(UndoableFileOperation(label: "Utworzenie folderu \(target.lastPathComponent)", kind: .created(url: target)))
            self.enqueueDirectoryRefresh(directory.path)
            lastStatusMessage = "Utworzono folder \(target.lastPathComponent)"
            return target
        } catch {
            lastStatusMessage = "Nie udało się utworzyć folderu: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func createFile(named name: String, content: String = "", in directory: URL) -> URL? {
        guard beginMutation(title: "Tworzenie pliku") else { return nil }
        defer { activeTransfer = nil }
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa pliku"
            return nil
        }
        do {
            let target = try Self.createUniqueItem(at: directory.appendingPathComponent(safeName)) { target in
                // O_EXCL-style creation; an atomic replacement write could overwrite
                // another process's file/symlink created after uniqueURL's check.
                try Data(content.utf8).write(to: target, options: .withoutOverwriting)
            }
            if safeName.hasSuffix(".sh") || content.hasPrefix("#!") {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            pushUndo(UndoableFileOperation(label: "Utworzenie pliku \(target.lastPathComponent)", kind: .created(url: target)))
            self.enqueueDirectoryRefresh(directory.path)
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
        guard beginMutation(title: "Zmiana nazwy") else { return nil }
        defer { activeTransfer = nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard let safeName = Self.validatedFileName(trimmed) else {
            lastStatusMessage = "Nazwa nie może zawierać znaku „/” ani być „.” lub „..”"
            return nil
        }
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(safeName)
        let isCaseOnlyChange = safeName.lowercased() == item.name.lowercased()
        if !isCaseOnlyChange && fileIO.exists(dst) {
            lastStatusMessage = "Element o nazwie „\(safeName)” już istnieje"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            pushUndo(UndoableFileOperation(label: "Zmiana nazwy \(item.name) → \(safeName)", kind: .moved(pairs: [(from: item.url, to: dst)])))
            self.enqueueDirectoryRefresh(item.parentPath)
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
            self.enqueueDirectoryRefresh(trashPath)
            let removedURLs = removed
            let finalError = lastError
            await MainActor.run {
                let manager = self
                manager.activeTransfer = nil
                // Undo entries pointing into the Trash are no longer restorable.
                manager.undoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.redoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.lastStatusMessage = finalError.map {
                    "Nie opróżniono całego Kosza (usunięto \(removedURLs.count) z \(items.count)): \($0)"
                } ?? "Opróżniono Kosz (usunięto \(removedURLs.count) elem.)"
                manager.reloadVisiblePanes()
                completion?()
            }
        }
    }

    /// Duplicate can copy multi-gigabyte trees, so it owns the same mutation gate
    /// as transfers and runs off MainActor. Completion reports only created items.
    public func duplicateItems(_ items: [FileItem], completion: (@MainActor ([URL]) -> Void)? = nil) {
        guard !items.isEmpty, beginMutation(title: "Duplikowanie", totalCount: items.count) else { return }
        let io = fileIO
        Task.detached(priority: .userInitiated) { [self] in
            var created: [URL] = []
            var errors: [String] = []
            var touched = Set<String>()
            for (index, item) in items.enumerated() {
                await MainActor.run {
                    self.activeTransfer = TransferProgressInfo(title: "Duplikowanie", currentFile: item.name,
                                                              completedCount: index, totalCount: items.count)
                }
                let destination = Self.uniqueURL(for: item.url, suffixWord: " copy")
                do {
                    try io.copy(item.url, destination)
                    created.append(destination)
                    touched.insert(item.parentPath)
                } catch {
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }
            for directory in touched { self.enqueueDirectoryRefresh(directory) }
            let finalCreated = created
            let finalErrors = errors
            let finalTouched = touched
            await MainActor.run {
                if !finalCreated.isEmpty {
                    self.pushUndo(UndoableFileOperation(label: "Duplikacja \(finalCreated.count) elem.", kind: .copied(created: finalCreated)))
                }
                for directory in finalTouched { FolderSizeCache.shared.invalidate(containing: directory) }
                self.lastStatusMessage = finalErrors.isEmpty
                    ? "Zduplikowano \(finalCreated.count) elem."
                    : "Zduplikowano \(finalCreated.count) z \(items.count) elem.: " + finalErrors.joined(separator: "; ")
                self.activeTransfer = nil
                self.reloadVisiblePanes()
                completion?(finalCreated)
            }
        }
    }

    public func moveToTrash(_ items: [FileItem], validating: ((FileItem) throws -> Void)? = nil) {
        guard !items.isEmpty, beginMutation(title: "Przenoszenie do Kosza", totalCount: items.count) else { return }
        defer { activeTransfer = nil }
        var trashedPairs: [(original: URL, trashed: URL)] = []
        var failures = 0
        var validationError: String?
        for item in items {
            do {
                // A stale duplicate scan must not be allowed to remove the last
                // surviving or newly modified copy. Abort the batch on invalidation.
                try validating?(item)
            } catch {
                validationError = error.localizedDescription
                break
            }
            do {
                let trashed = try fileIO.trash(item.url)
                trashedPairs.append((original: item.url, trashed: trashed))
                self.enqueueDirectoryRefresh(item.parentPath)
                FolderSizeCache.shared.invalidate(containing: item.parentPath)
            } catch {
                failures += 1
            }
        }
        if !trashedPairs.isEmpty {
            pushUndo(UndoableFileOperation(label: "Kosz (\(trashedPairs.count) elem.)", kind: .trashed(pairs: trashedPairs)))
        }
        if let validationError {
            lastStatusMessage = "Przerwano usuwanie: \(validationError) (przeniesiono \(trashedPairs.count) elem.)"
        } else if failures > 0 {
            lastStatusMessage = "Nie udało się przenieść do Kosza \(failures) elem. (brak uprawnień?)"
        } else {
            lastStatusMessage = "Przeniesiono do Kosza: \(trashedPairs.count) elem. (Cmd+Z aby przywrócić)"
        }
    }

    // MARK: - Native macOS Finder Color Tags

    public func toggleTag(_ color: FinderTagColor, for items: [FileItem]) {
        guard beginMutation(title: "Zmiana tagów") else { return }
        defer { activeTransfer = nil }
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
        guard beginMutation(title: "Usuwanie tagów") else { return }
        defer { activeTransfer = nil }
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

    /// Archive tools get a minimal environment. In particular ZIPOPT=-m must
    /// never turn a non-destructive compression command into source deletion;
    /// TAR_OPTIONS, UNZIP*, and shell startup variables are excluded as well.
    nonisolated static func archiveProcessEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }

    public func compressItems(_ items: [FileItem], in directory: URL) {
        guard !items.isEmpty, canStartMutation() else { return }
        let parents = Set(items.map { $0.url.deletingLastPathComponent().path })
        let workingDir = parents.count == 1 ? items[0].url.deletingLastPathComponent() : directory
        let archiveBaseName = items.count == 1 ? "\(items[0].url.deletingPathExtension().lastPathComponent).zip" : "Archiwum.zip"
        let requestedURL = workingDir.appendingPathComponent(archiveBaseName)
        // A filename such as "-m" is always an operand, never ZIP's move option.
        let names = parents.count == 1 ? items.map { "./" + $0.url.lastPathComponent } : items.map(\.path)
        let io = fileIO
        activeTransfer = TransferProgressInfo(title: "Kompresowanie", currentFile: requestedURL.lastPathComponent, completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) { [self] in
            var staging: URL?
            var published: URL?
            var failure: String?
            do {
                let root = try SafeArchivePublication.stagingDirectory(in: workingDir)
                staging = root
                let stagedURL = root.appendingPathComponent("archive.zip")
                let status = Self.runProcess("/usr/bin/zip", arguments: ["-r", "-q", "-y", stagedURL.path] + names,
                                             in: workingDir, environment: Self.archiveProcessEnvironment())
                guard status == 0 else { throw FileOperationFailure(message: "Kompresja nie powiodła się (kod \(status))") }
                published = try Self.createUniqueItem(at: requestedURL) { candidate in
                    try io.publishExclusive(stagedURL, candidate)
                }
                io.removeEmptyDirectory(root)
            } catch {
                failure = error.localizedDescription
                if let staging {
                    // Only the owned empty directory may be removed. Partial data
                    // stays discoverable and never becomes a whole-output undo entry.
                    io.removeEmptyDirectory(staging)
                    if io.exists(staging) { failure! += "; dane operacji zachowano w \(staging.path)" }
                }
            }
            self.enqueueDirectoryRefresh(workingDir.path)
            let finalURL = published
            let finalError = failure
            await MainActor.run {
                if let finalURL {
                    self.pushUndo(UndoableFileOperation(label: "Utworzenie archiwum \(finalURL.lastPathComponent)", kind: .created(url: finalURL)))
                    self.lastStatusMessage = "Utworzono archiwum \(finalURL.lastPathComponent)"
                } else {
                    self.lastStatusMessage = finalError ?? "Kompresja nie powiodła się"
                }
                self.activeTransfer = nil
                self.reloadVisiblePanes()
            }
        }
    }

    public func extractArchive(_ item: FileItem) {
        guard canStartMutation() else { return }
        let parentDir = item.url.deletingLastPathComponent()
        let ext = item.fileExtension.lowercased()
        let lowerName = item.name.lowercased()
        if ext == "dmg" {
            activeTransfer = TransferProgressInfo(title: "Montowanie", currentFile: item.name, completedCount: 0, totalCount: 1)
            Task.detached(priority: .userInitiated) { [self] in
                let status = Self.runProcess("/usr/bin/hdiutil", arguments: ["attach", item.path], in: parentDir,
                                             environment: Self.archiveProcessEnvironment())
                await MainActor.run {
                    self.activeTransfer = nil
                    self.lastStatusMessage = status == 0
                        ? "Zamontowano obraz \(item.name)"
                        : "Nie udało się zamontować \(item.name) (kod \(status))"
                    AppState.shared.refreshMountedVolumes()
                }
            }
            return
        }
        var baseFolder = item.url.deletingPathExtension().lastPathComponent
        if baseFolder.lowercased().hasSuffix(".tar") { baseFolder = String(baseFolder.dropLast(4)) }
        let requestedURL = parentDir.appendingPathComponent(baseFolder, isDirectory: true)
        let isTarball = ext == "tar" || ext == "tgz" || lowerName.hasSuffix(".tar.gz") ||
                        lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tar.xz")
        let io = fileIO
        activeTransfer = TransferProgressInfo(title: "Rozpakowywanie", currentFile: item.name, completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) { [self] in
            var staging: URL?
            var published: URL?
            var failure: String?
            do {
                let root = try SafeArchivePublication.stagingDirectory(in: parentDir)
                staging = root
                let stagedURL = root.appendingPathComponent("contents", isDirectory: true)
                try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let environment = Self.archiveProcessEnvironment()
                let status: Int32
                if isTarball {
                    status = Self.runProcess("/usr/bin/tar", arguments: ["-xf", item.path, "-C", stagedURL.path], in: parentDir, environment: environment)
                } else if ext == "gz" || ext == "bz2" || ext == "xz" {
                    let outName = item.url.deletingPathExtension().lastPathComponent
                    status = Self.runProcess("/bin/sh", arguments: ["-c", "/usr/bin/tar -xOf \"$0\" > \"$1\"", item.path, stagedURL.appendingPathComponent(outName).path], in: parentDir, environment: environment)
                } else {
                    status = Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", item.path, stagedURL.path], in: parentDir, environment: environment)
                }
                guard status == 0 else { throw FileOperationFailure(message: "Nie udało się rozpakować \(item.name) (kod \(status))") }
                published = try Self.createUniqueItem(at: requestedURL) { candidate in
                    try io.publishExclusive(stagedURL, candidate)
                }
                io.removeEmptyDirectory(root)
            } catch {
                failure = error.localizedDescription
                if let staging {
                    io.removeEmptyDirectory(staging.appendingPathComponent("contents", isDirectory: true))
                    io.removeEmptyDirectory(staging)
                    if io.exists(staging) { failure! += "; dane operacji zachowano w \(staging.path)" }
                }
            }
            self.enqueueDirectoryRefresh(parentDir.path)
            let finalURL = published
            let finalError = failure
            await MainActor.run {
                if let finalURL {
                    self.pushUndo(UndoableFileOperation(label: "Rozpakowanie \(item.name)", kind: .created(url: finalURL)))
                    self.lastStatusMessage = "Rozpakowano do: \(finalURL.lastPathComponent)"
                } else {
                    self.lastStatusMessage = finalError ?? "Rozpakowanie nie powiodło się"
                }
                self.activeTransfer = nil
                self.reloadVisiblePanes()
            }
        }
    }

    // MARK: - POSIX Permissions (chmod) & Checksums (SHA-256 / MD5)

    @discardableResult
    public func setPosixPermissions(_ mode: UInt16, for item: FileItem) -> Bool {
        guard beginMutation(title: "Zmiana uprawnień") else { return false }
        defer { activeTransfer = nil }
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
        guard let snapshot = fetchGitStatusSnapshot(for: directoryPath) else { return [:] }
        FSearchIndex.shared.recordGitStatuses(snapshot.statuses, repositoryRoot: snapshot.repositoryRoot)
        return snapshot.statuses
    }

    /// A successful empty snapshot clears stale statuses; nil means status was not
    /// available and must not be confused with a clean repository.
    nonisolated public static func fetchGitStatusSnapshot(for directoryPath: String) -> GitStatusSnapshot? {
        // Browsing is read-only, not permission to execute a worktree's fsmonitor
        // helper, hooks, or recursively inspect untrusted submodule configuration.
        let safeOptions = ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
        guard let rootData = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + ["rev-parse", "--show-toplevel"],
            in: URL(fileURLWithPath: directoryPath)
        ), var gitRoot = String(data: rootData, encoding: .utf8) else { return nil }
        // Remove exactly Git's delimiter, not whitespace that belongs to a path.
        if gitRoot.hasSuffix("\n") { gitRoot.removeLast() }
        guard !gitRoot.isEmpty else { return nil }
        // Git emits physical /private/var paths on macOS; Foundation's file
        // URLs use the normalized /var namespace. Normalize once off-main so
        // status keys match the directory crawler and successful-empty clears.
        gitRoot = URL(fileURLWithPath: gitRoot).standardizedFileURL.resolvingSymlinksInPath().path

        // Status may run clean/process filters from .gitattributes when comparing
        // a tracked same-size edit. Enumerate keys without running Git plumbing,
        // then override every configured driver. Never interpret config as shell.
        guard let configurationKeys = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + ["config", "--includes", "--null", "--name-only", "--list"],
            in: URL(fileURLWithPath: directoryPath)
        ), let disabledFilters = disabledGitFilterOptions(configurationKeys: configurationKeys) else { return nil }

        guard let data = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + disabledFilters + ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "-uall", "--ignore-submodules=all"],
            in: URL(fileURLWithPath: directoryPath)
        ) else { return nil }

        return GitStatusSnapshot(usesRawContentComparison: !disabledFilters.isEmpty, repositoryRoot: gitRoot,
                                 statuses: parseGitStatusRecords(data, repositoryRoot: gitRoot))
    }

    nonisolated static func parseGitStatusRecords(_ data: Data, repositoryRoot: String) -> [String: GitFileStatus] {
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
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") ||
               y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
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
            statusMap[URL(fileURLWithPath: repositoryRoot).appendingPathComponent(relPath).path] = status
        }
        return statusMap
    }

    /// Git's NUL-delimited name-only output retains subsection spelling. A name
    /// containing "=" cannot safely be passed through `-c key=value`; fail closed
    /// rather than silently leave a potentially executable driver enabled.
    nonisolated static func disabledGitFilterOptions(configurationKeys: Data) -> [String]? {
        var drivers = Set<String>()
        for record in configurationKeys.split(separator: 0, omittingEmptySubsequences: true) {
            guard let key = String(data: Data(record), encoding: .utf8) else { return nil }
            let lower = key.lowercased()
            guard lower.hasPrefix("filter."),
                  let suffix = [".clean", ".process", ".required"].first(where: { lower.hasSuffix($0) }) else { continue }
            let driver = String(key.dropFirst("filter.".count).dropLast(suffix.count))
            guard !driver.isEmpty, !driver.contains("="),
                  !driver.contains("\n"), !driver.contains("\r") else { return nil }
            drivers.insert(driver)
        }
        return drivers.sorted().flatMap { driver in
            ["-c", "filter.\(driver).clean=", "-c", "filter.\(driver).process=",
             "-c", "filter.\(driver).required=false"]
        }
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
        if suffixWord.isEmpty && !FileOperationIO.live.exists(url) {
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
            if !FileOperationIO.live.exists(candidateURL) {
                return candidateURL
            }
            counter += 1
        }
    }

    /// The creator must fail rather than overwrite an occupied entry. A racing
    /// creator is handled by picking a fresh name, with a bound against livelock.
    nonisolated static func createUniqueItem(at requested: URL, create: (URL) throws -> Void) throws -> URL {
        for _ in 0..<100 {
            let candidate = uniqueURL(for: requested)
            do {
                try create(candidate)
                return candidate
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError else { throw error }
            }
        }
        throw FileOperationFailure(message: "Nie można wybrać wolnej nazwy pliku; spróbuj ponownie.")
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
    nonisolated static func runProcess(_ executable: String, arguments: [String], in directory: URL,
                                       environment: [String: String]? = nil) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        if let environment { proc.environment = environment }
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

    /// Bounded read-only inspection. Nonblocking reads keep both output volume and
    /// elapsed time bounded even if a corrupt repository hangs Git or fills a pipe.
    nonisolated static func runProcessCapturingOutput(_ executable: String, arguments: [String], in directory: URL,
                                                       maxOutputBytes: Int = 8 * 1024 * 1024,
                                                       timeout: TimeInterval = 10) -> Data? {
        guard maxOutputBytes > 0, timeout.isFinite, timeout > 0 else { return nil }
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
        try? outPipe.fileHandleForWriting.close()
        let reader = outPipe.fileHandleForReading
        defer {
            try? reader.close()
            if proc.isRunning { _ = Darwin.kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }
        let descriptor = reader.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var reachedEOF = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !reachedEOF {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    guard count <= maxOutputBytes, data.count <= maxOutputBytes - count else { return nil }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    return nil
                }
            }
            if reachedEOF && !proc.isRunning {
                proc.waitUntilExit()
                return proc.terminationStatus == 0 ? data : nil
            }
            if reachedEOF {
                usleep(10_000)
            } else {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&pollDescriptor, 1, 20)
            }
        }
        return nil
    }
}
