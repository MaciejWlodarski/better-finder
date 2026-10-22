import Foundation
import Darwin

/// Integration regressions use the actual manager, stacks, subprocess methods,
/// and IO executor. All destructive work is redirected into a disposable fixture.
@MainActor
struct FileOperationSafetyTests {
    private final class Fixture {
        let root: URL
        let sourceDirectory: URL
        let destination: URL
        let trash: URL
        let fm = FileManager.default

        init() throws {
            root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bf-manager-safety-\(UUID())", isDirectory: true)
            sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
            destination = root.appendingPathComponent("destination", isDirectory: true)
            trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
            for directory in [sourceDirectory, destination, trash] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        deinit { try? fm.removeItem(at: root) }
        func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func item(_ url: URL) -> FileItem {
            FileItem(url: url, name: url.lastPathComponent, path: url.path,
                     parentPath: url.deletingLastPathComponent().path, fileExtension: url.pathExtension,
                     isDirectory: false, isHidden: false, size: 1, modificationDate: .distantPast)
        }
        var io: FileOperationIO {
            var io = FileOperationIO.live
            io.trash = { [self] url in
                guard url.path.hasPrefix(root.path + "/") else {
                    throw RegressionFailure(description: "Refusing to trash outside fixture")
                }
                let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try fm.moveItem(at: url, to: target)
                return target
            }
            return io
        }
        @MainActor func manager(_ io: FileOperationIO? = nil) -> FileOperationsManager {
            FileOperationsManager(fileIO: io ?? self.io, reloadVisiblePanes: {})
        }
    }

    /// Deterministic barriers never block the main actor. Their bounded worker wait
    /// also makes a synchronous-execution regression fail instead of hanging CI.
    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        let release = DispatchSemaphore(value: 0)
        private var entered = false
        private var mainThread = false
        private var shouldFail = false
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return shouldFail }
            set { lock.lock(); shouldFail = newValue; lock.unlock() }
        }
        var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
        func hold() throws {
            lock.lock(); entered = true; mainThread = Thread.isMainThread; lock.unlock()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw RegressionFailure(description: "Worker barrier timed out (possibly MainActor IO)")
            }
        }
    }

    private static func idle(_ manager: FileOperationsManager) async throws {
        let deadline = Date().addingTimeInterval(10)
        while manager.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(!manager.isBusy)
    }
    private static func entered(_ control: Control) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !control.didEnter && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(control.didEnter)
    }

    static func runAll() async throws -> Int {
        try testDanglingNamesAndExclusiveCreation()
        try await testDanglingTransferAndTrashRestore()
        try await testBusyGateDuringTransfer()
        try await testDuplicateDoesNotBlockMainActor()
        try await testHistoryDoesNotBlockMainActor()
        try await testPartialHistoryIdentity()
        try testTrashValidationAbortsBatch()
        try await testZipOperandsPreserveSources()
        try await testArchivePublicationRacePreservesRival()
        try await testArchivePublicationFailurePreservesOwnedStaging()
        #if BETTERFINDER_TESTING
        try await testMutationDoesNotWaitForIndexCrawl()
        #endif
        try testGitDoesNotExecuteLocalHelper()
        try await testGitDoesNotExecuteCleanFilter()
        try testBoundedGitInspectionAndDriverNames()
        try testGitRenameRecordPairs()
        #if BETTERFINDER_TESTING
        return 15
        #else
        return 14
        #endif
    }

    private static func testDanglingNamesAndExclusiveCreation() throws {
        let f = try Fixture()
        let requested = f.destination.appendingPathComponent("item.txt")
        for name in ["item.txt", "item 1.txt", "item copy.txt", "item copy 2.txt"] {
            try f.fm.createSymbolicLink(atPath: f.destination.appendingPathComponent(name).path,
                                       withDestinationPath: "/missing-betterfinder-fixture-\(UUID())")
        }
        try expect(FileOperationsManager.uniqueURL(for: requested).lastPathComponent == "item 2.txt")
        try expect(FileOperationsManager.uniqueURL(for: requested, suffixWord: " copy").lastPathComponent == "item copy 3.txt")
        let manager = f.manager()
        let created = manager.createFile(named: "item.txt", content: "new", in: f.destination)
        try expect(created?.lastPathComponent == "item 2.txt")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: requested.path)) != nil)

        let raced = f.destination.appendingPathComponent("race.txt")
        var first = true
        let result = try FileOperationsManager.createUniqueItem(at: raced) { candidate in
            if first { first = false; try f.write("other process", to: candidate) }
            try Data("ours".utf8).write(to: candidate, options: .withoutOverwriting)
        }
        let racedText = try f.text(raced)
        let resultText = try f.text(result)
        try expect(racedText == "other process" && resultText == "ours" && result != raced)
    }

    private static func testDanglingTransferAndTrashRestore() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        let target = f.destination.appendingPathComponent("item.txt")
        try f.write("incoming", to: source)
        try f.fm.createSymbolicLink(atPath: target.path, withDestinationPath: "/missing-bf-fixture-\(UUID())")
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .ask)
        try expect(manager.pendingConflict?.conflictingNames == ["item.txt"])
        manager.pendingConflict = nil
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await idle(manager)
        let copy = f.destination.appendingPathComponent("item 1.txt")
        let copiedText = try f.text(copy)
        try expect(copiedText == "incoming")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: target.path)) != nil)
        manager.moveToTrash([f.item(copy)])
        try f.fm.createSymbolicLink(atPath: copy.path, withDestinationPath: "/missing-bf-fixture-\(UUID())")
        manager.undoLastOperation()
        try await idle(manager)
        let restoredText = try f.text(f.destination.appendingPathComponent("item 1 1.txt"))
        try expect(restoredText == "incoming")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: copy.path)) != nil)
    }

    private static func testBusyGateDuringTransfer() async throws {
        let f = try Fixture()
        let a = f.sourceDirectory.appendingPathComponent("a.txt")
        let b = f.sourceDirectory.appendingPathComponent("b.txt")
        try f.write("a", to: a); try f.write("b", to: b)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.copy = { from, to in
            if from == b { try control.hold() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [a, b], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await entered(control)
        let copiedA = f.destination.appendingPathComponent("a.txt")
        try expect(manager.isBusy && !control.ranOnMain)
        try expect(manager.renameItem(f.item(copiedA), to: "renamed.txt") == nil)
        manager.duplicateItems([f.item(copiedA)])
        try expect(!f.io.exists(f.destination.appendingPathComponent("a copy.txt")))
        try expect(manager.createFile(named: "new.txt", in: f.destination) == nil)
        try expect(manager.createFolder(named: "new-folder", in: f.destination) == nil)
        try expect(!manager.setPosixPermissions(0o777, for: f.item(copiedA)))
        manager.moveToTrash([f.item(copiedA)])
        manager.toggleTag(.red, for: [f.item(copiedA)])
        manager.clearTags(for: [f.item(copiedA)])
        manager.undoLastOperation()
        try expect(manager.undoStack.isEmpty && manager.redoStack.isEmpty)
        try expect(f.io.exists(copiedA))
        control.release.signal()
        try await idle(manager)
        try expect(manager.undoStack.count == 1)
    }

    private static func testDuplicateDoesNotBlockMainActor() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        try f.write("duplicate me", to: source)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.copy = { from, to in
            try control.hold()
            try FileManager.default.copyItem(at: from, to: to)
        }
        let manager = f.manager(io)
        var completed: [URL] = []
        manager.duplicateItems([f.item(source)]) { completed = $0 }
        try expect(manager.isBusy)
        try await entered(control)
        try expect(!control.ranOnMain && manager.isBusy && completed.isEmpty)
        try expect(manager.renameItem(f.item(source), to: "renamed.txt") == nil)
        control.release.signal()
        try await idle(manager)
        let copy = f.sourceDirectory.appendingPathComponent("item copy.txt")
        let copied = try f.text(copy)
        try expect(copied == "duplicate me" && completed == [copy] && manager.undoStack.count == 1)
        try expect(f.io.exists(source))
    }

    private static func testHistoryDoesNotBlockMainActor() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        try f.write("incoming", to: source)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.move = { from, to in
            if to == source { try control.hold() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: true, explicitPolicy: .keepBoth)
        try await idle(manager)
        manager.undoLastOperation()
        try expect(manager.isBusy && !manager.canUndo && !manager.canRedo)
        try await entered(control)
        // Reaching this assertion while worker IO is suspended proves MainActor liveness.
        try expect(manager.isBusy && !control.ranOnMain)
        control.release.signal()
        try await idle(manager)
        try expect(f.io.exists(source) && manager.redoStack.count == 1)
    }

    private static func testPartialHistoryIdentity() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        let target = f.destination.appendingPathComponent("item.txt")
        try f.write("incoming", to: source); try f.write("original", to: target)
        let control = Control()
        var io = f.io
        io.move = { from, to in
            if control.fail && from.deletingLastPathComponent() == f.trash && to == target {
                throw RegressionFailure(description: "Injected original restoration failure")
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .overwrite)
        try await idle(manager)
        let identity = manager.undoStack.last?.transactionID
        control.fail = true
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1 && !f.io.exists(target))
        try expect(manager.undoStack.last?.transactionID == identity && manager.redoStack.last?.transactionID == identity)
        control.fail = false
        manager.redoLastOperation(); try await idle(manager)
        let incoming = try f.text(target)
        try expect(incoming == "incoming" && manager.undoStack.count == 1 && manager.redoStack.isEmpty)
        manager.undoLastOperation(); try await idle(manager)
        let original = try f.text(target)
        try expect(original == "original" && manager.undoStack.isEmpty && manager.redoStack.count == 1)
        manager.redoLastOperation(); try await idle(manager)
        let restored = try f.text(target)
        try expect(restored == "incoming" && manager.undoStack.count == 1)

        // The mirrored case: partial redo -> undo -> redo must stay one operation.
        manager.undoLastOperation(); try await idle(manager)
        control.fail = true
        manager.redoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1)
        control.fail = false
        manager.undoLastOperation(); try await idle(manager)
        let afterReversingRedo = try f.text(target)
        try expect(afterReversingRedo == "original" && manager.redoStack.count == 1 && manager.undoStack.isEmpty)
        manager.redoLastOperation(); try await idle(manager)
        let afterFullRedo = try f.text(target)
        try expect(afterFullRedo == "incoming" && manager.undoStack.count == 1)

        // Retrying the pending suffix also merges the redo prefix, without requiring
        // the user to reverse the partial undo first.
        control.fail = true
        manager.undoLastOperation(); try await idle(manager)
        control.fail = false
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.isEmpty && manager.redoStack.count == 1)
        manager.redoLastOperation(); try await idle(manager)
        let final = try f.text(target)
        try expect(final == "incoming" && manager.undoStack.count == 1)
    }

    private static func testTrashValidationAbortsBatch() throws {
        let f = try Fixture()
        let urls = ["one.txt", "two.txt", "three.txt"].map { f.sourceDirectory.appendingPathComponent($0) }
        for url in urls { try f.write(url.lastPathComponent, to: url) }
        let manager = f.manager()
        manager.moveToTrash(urls.map(f.item)) { item in
            if item.url == urls[1] { throw RegressionFailure(description: "Retained copy changed") }
        }
        try expect(!f.io.exists(urls[0]) && f.io.exists(urls[1]) && f.io.exists(urls[2]))
        try expect(manager.undoStack.count == 1 && manager.lastStatusMessage?.contains("Retained copy changed") == true)
    }

    private static func testZipOperandsPreserveSources() async throws {
        let f = try Fixture()
        let inheritedZipOption = getenv("ZIPOPT").map { String(cString: $0) }
        setenv("ZIPOPT", "-m", 1)
        defer {
            if let inheritedZipOption { setenv("ZIPOPT", inheritedZipOption, 1) } else { unsetenv("ZIPOPT") }
        }
        let sanitized = FileOperationsManager.archiveProcessEnvironment(inherited: ["ZIPOPT": "-m", "TAR_OPTIONS": "--remove-files", "ENV": "/unsafe", "PATH": "/unsafe"])
        try expect(sanitized["ZIPOPT"] == nil && sanitized["TAR_OPTIONS"] == nil && sanitized["ENV"] == nil)
        try expect(sanitized["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        let names = ["-m", "-T", "space name.txt", "line\nbreak.txt", "Zażółć.txt"]
        let urls = names.map { f.sourceDirectory.appendingPathComponent($0) }
        for (name, url) in zip(names, urls) { try f.write("contents:" + name, to: url) }
        let manager = f.manager()
        manager.compressItems(urls.map(f.item), in: f.sourceDirectory)
        try await idle(manager)
        let archive = f.sourceDirectory.appendingPathComponent("Archiwum.zip")
        try expect(f.io.exists(archive) && manager.undoStack.count == 1)
        let unpacked = f.root.appendingPathComponent("unpacked", isDirectory: true)
        try f.fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try expect(FileOperationsManager.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, unpacked.path], in: f.root) == 0)
        for (name, url) in zip(names, urls) {
            let original = try f.text(url)
            let extracted = try f.text(unpacked.appendingPathComponent(name))
            try expect(original == "contents:" + name && extracted == original)
        }
    }

    private static func testGitDoesNotExecuteLocalHelper() throws {
        let f = try Fixture()
        let marker = f.root.appendingPathComponent("helper-executed")
        let helper = f.root.appendingPathComponent("fsmonitor")
        try f.write("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n", to: helper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        func git(_ args: [String]) throws {
            try expect(FileOperationsManager.runProcess("/usr/bin/git", arguments: args, in: f.sourceDirectory) == 0)
        }
        try git(["init", "-q"])
        let baseline = f.sourceDirectory.appendingPathComponent("baseline.txt")
        try f.write("tracked baseline", to: baseline)
        try git(["add", "--", "baseline.txt"])
        try git(["-c", "user.name=BetterFinder Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
        try git(["config", "core.fsmonitor", helper.path])
        // Deliberately unprotected positive control runs ONLY this inert fixture helper.
        try git(["status", "--porcelain=v1", "-z", "-uall"])
        try expect(f.io.exists(marker))
        try f.fm.removeItem(at: marker)
        let file = f.sourceDirectory.appendingPathComponent("file.txt")
        try f.write("untracked", to: file)
        guard let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path) else {
            throw RegressionFailure(description: "Git snapshot unexpectedly failed")
        }
        try expect(!f.io.exists(marker) && snapshot.statuses[file.path] == .untracked)
        try expect(URL(fileURLWithPath: snapshot.repositoryRoot).resolvingSymlinksInPath() == f.sourceDirectory.resolvingSymlinksInPath())
        try f.fm.removeItem(at: file)
        let clean = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(clean != nil && clean?.statuses.isEmpty == true && !f.io.exists(marker))
        try expect(FileOperationsManager.fetchGitStatusSnapshot(for: f.destination.path) == nil)
    }

    private static func testGitDoesNotExecuteCleanFilter() async throws {
        let f = try Fixture()
        func git(_ arguments: [String]) throws {
            try expect(FileOperationsManager.runProcess("/usr/bin/git", arguments: arguments, in: f.sourceDirectory) == 0)
        }
        try git(["init", "-q"])
        let tracked = f.sourceDirectory.appendingPathComponent("tracked.txt")
        try f.write("original\n", to: tracked)
        try f.write("*.txt filter=fixture\n", to: f.sourceDirectory.appendingPathComponent(".gitattributes"))
        try git(["add", "--", ".gitattributes", "tracked.txt"])
        try git(["-c", "user.name=BetterFinder Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
        let marker = f.root.appendingPathComponent("clean-filter-executed")
        let helper = f.root.appendingPathComponent("clean-filter")
        try f.write("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n/bin/cat\n", to: helper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try git(["config", "filter.fixture.clean", helper.path])
        try await Task.sleep(for: .milliseconds(1100))
        try f.write("modified\n", to: tracked) // Same byte count forces a content comparison.
        try git(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "status", "--porcelain=v1", "-z", "-uall"])
        try expect(f.io.exists(marker))
        try f.fm.removeItem(at: marker)
        let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(snapshot?.statuses[tracked.path] == .modified && !f.io.exists(marker))
        try expect(snapshot?.usesRawContentComparison == true)

        let processMarker = f.root.appendingPathComponent("process-filter-executed")
        let processHelper = f.root.appendingPathComponent("process-filter")
        // A benign server greeting followed by deliberate EOF proves that even a
        // failed optional process-filter initialization executes configured code.
        try f.write("#!/bin/sh\n/usr/bin/touch '\(processMarker.path)'\nprintf '0016git-filter-server\\n000eversion=2\\n0000'\n", to: processHelper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: processHelper.path)
        try git(["config", "filter.processor.process", processHelper.path])
        try git(["config", "filter.processor.required", "false"])
        try f.write("*.txt filter=processor\n", to: f.sourceDirectory.appendingPathComponent(".gitattributes"))
        // Deliberate protocol EOF may make Git exit 0 or 128 depending on version;
        // the positive control is helper invocation, not successful filtering.
        _ = FileOperationsManager.runProcess("/usr/bin/git", arguments: ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "-uall"], in: f.sourceDirectory)
        try expect(f.io.exists(processMarker))
        try f.fm.removeItem(at: processMarker)
        let processSnapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(processSnapshot?.statuses[tracked.path] == .modified && !f.io.exists(processMarker))
    }

    private static func testBoundedGitInspectionAndDriverNames() throws {
        let f = try Fixture()
        let keys = Data("filter.Space Name.clean\0filter.a.b.process\0filter.Space Name.required\0".utf8)
        let options = FileOperationsManager.disabledGitFilterOptions(configurationKeys: keys)
        try expect(options?.contains("filter.Space Name.clean=") == true)
        try expect(options?.contains("filter.a.b.process=") == true)
        try expect(options?.count == 12) // Each distinct driver gets exactly three -c overrides.
        try expect(FileOperationsManager.disabledGitFilterOptions(configurationKeys: Data("filter.a=b.clean\0".utf8)) == nil)
        try expect(FileOperationsManager.disabledGitFilterOptions(configurationKeys: Data("filter.a\nb.clean\0".utf8)) == nil)
        let start = ProcessInfo.processInfo.systemUptime
        let excessiveOutput = FileOperationsManager.runProcessCapturingOutput(
            "/usr/bin/yes", arguments: [], in: f.root, maxOutputBytes: 128, timeout: 2)
        let timedOut = FileOperationsManager.runProcessCapturingOutput(
            "/bin/sleep", arguments: ["2"], in: f.root, timeout: 0.05)
        try expect(excessiveOutput == nil && timedOut == nil)
        try expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
    }


    private static func testGitRenameRecordPairs() throws {
        let records = Data(" R new name.txt\0?? misleading-old-name.txt\0R  other.txt\0old.txt\0?? plain.txt\0".utf8)
        let parsed = FileOperationsManager.parseGitStatusRecords(records, repositoryRoot: "/fixture")
        try expect(parsed.count == 3)
        try expect(parsed["/fixture/new name.txt"] == .renamed && parsed["/fixture/other.txt"] == .renamed)
        try expect(parsed["/fixture/plain.txt"] == .untracked)
        try expect(parsed["/fixture/misleading-old-name.txt"] == nil)
    }


    private static func testArchivePublicationRacePreservesRival() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("incoming.txt")
        try f.write("incoming bytes", to: source)
        let desiredArchive = f.sourceDirectory.appendingPathComponent("incoming.zip")
        var io = f.io
        let first = Control()
        first.fail = true
        let livePublish = io.publishExclusive
        io.publishExclusive = { staged, candidate in
            if first.fail {
                first.fail = false
                // Occupy the candidate AFTER the production unique-name lookup.
                try Data("unrelated archive bytes".utf8).write(to: candidate, options: .withoutOverwriting)
            }
            try livePublish(staged, candidate)
        }
        let manager = f.manager(io)
        manager.compressItems([f.item(source)], in: f.sourceDirectory)
        try await idle(manager)
        let archive = f.sourceDirectory.appendingPathComponent("incoming 1.zip")
        let rivalArchive = try f.text(desiredArchive)
        try expect(rivalArchive == "unrelated archive bytes" && f.io.exists(archive) && manager.undoStack.count == 1)

        let desiredDirectory = f.sourceDirectory.appendingPathComponent("incoming 1", isDirectory: true)
        let extractionIO = f.io
        var extraction = extractionIO
        let next = Control()
        next.fail = true
        extraction.publishExclusive = { staged, candidate in
            if next.fail {
                next.fail = false
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                try Data("unrelated directory bytes".utf8).write(to: candidate.appendingPathComponent("rival.txt"))
            }
            try extractionIO.publishExclusive(staged, candidate)
        }
        let extractor = f.manager(extraction)
        extractor.extractArchive(f.item(archive))
        try await idle(extractor)
        let publishedDirectory = f.sourceDirectory.appendingPathComponent("incoming 1 1", isDirectory: true)
        let extracted = try f.text(publishedDirectory.appendingPathComponent(source.lastPathComponent))
        try expect(extracted == "incoming bytes" && extractor.undoStack.count == 1)
        extractor.undoLastOperation(); try await idle(extractor)
        let rivalDirectory = try f.text(desiredDirectory.appendingPathComponent("rival.txt"))
        try expect(rivalDirectory == "unrelated directory bytes" && !f.io.exists(publishedDirectory))
        manager.undoLastOperation(); try await idle(manager)
        let rivalAfterUndo = try f.text(desiredArchive)
        let originalAfterUndo = try f.text(source)
        try expect(rivalAfterUndo == "unrelated archive bytes" && originalAfterUndo == "incoming bytes" && !f.io.exists(archive))
    }

    private static func testArchivePublicationFailurePreservesOwnedStaging() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("incoming.txt")
        try f.write("incoming bytes", to: source)
        var io = f.io
        io.publishExclusive = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let manager = f.manager(io)
        manager.compressItems([f.item(source)], in: f.sourceDirectory)
        try await idle(manager)
        let staging = try f.fm.contentsOfDirectory(at: f.sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".betterfinder-archive-") }
        try expect(staging.count == 1 && manager.undoStack.isEmpty)
        try expect(f.io.exists(staging[0].appendingPathComponent("archive.zip")))
        try expect(manager.lastStatusMessage?.contains(staging[0].path) == true)
        let original = try f.text(source)
        try expect(original == "incoming bytes")
    }

    #if BETTERFINDER_TESTING
    private static func testMutationDoesNotWaitForIndexCrawl() async throws {
        let f = try Fixture()
        try f.write("baseline", to: f.sourceDirectory.appendingPathComponent("baseline.txt"))
        let index = FSearchIndex(roots: [f.sourceDirectory.path], enableMonitoring: false)
        index.usePersistentMMapCache = false
        let gate = Control()
        defer { gate.release.signal() }
        index.crawlProgressHookForTesting = { _ in
            if !gate.didEnter { try? gate.hold() }
        }
        index.startIndexing()
        try await entered(gate)
        let refreshed = Control()
        let manager = FileOperationsManager(fileIO: f.io, reloadVisiblePanes: {}, enqueueDirectoryRefresh: { path in
            index.enqueueDirectoryRefresh(path) { refreshed.fail = true }
        })
        let started = ProcessInfo.processInfo.systemUptime
        let created = manager.createFile(named: "created-during-crawl.txt", content: "new", in: f.sourceDirectory)
        try expect(created != nil && ProcessInfo.processInfo.systemUptime - started < 0.5)
        await Task.yield()
        try expect(!refreshed.fail) // Actual index worker still owns updateLock.
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !refreshed.fail && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(refreshed.fail)
    }
    #endif

}
