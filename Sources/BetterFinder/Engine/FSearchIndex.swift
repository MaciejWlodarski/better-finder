import Foundation
import CoreServices
import Darwin

public struct FSearchResultBundle: Sendable {
    public let items: [FileItem]
    public let elapsedMilliseconds: Double
    public let totalIndexedCount: Int
    public let backendName: String
}

/// High-performance fsearch-compatible search & indexing engine with mmap persistence, trigram Bloom filters & FSEvents
public final class FSearchIndex: @unchecked Sendable {
    public static let shared = FSearchIndex()

    private var entries: [IndexedFileEntry] = []
    private var dirToIndices: [String: [Int]] = [:]
    private var eventStream: FSEventStreamRef?
    private let fseventsQueue = DispatchQueue(label: "com.betterfinder.fsevents", qos: .utility)

    // Trigram Bloom filter cache for content grep: path -> (mtimeEpoch, 64-bit trigram mask)
    private let trigramLock = NSLock()
    private var trigramBloomCache: [String: (Int64, UInt64)] = [:]

    // Global git status map for `git:` queries: fullPath -> GitFileStatus
    private let gitLock = NSLock()
    private var globalGitStatusMap: [String: GitFileStatus] = [:]

    // Configurable settings
    public var configuredRoots: [String]
    public var skippedDirectoryNames: Set<String>
    public var skipHeavyDevDirs: Bool = true
    public var usePersistentMMapCache: Bool = true

    public private(set) var isIndexing: Bool = false
    public private(set) var indexedCount: Int = 0
    public private(set) var lastCrawlDurationMs: Double = 0
    public private(set) var loadedFromMMapCache: Bool = false
    public private(set) var externalFSearchAvailable: Bool = false
    public var preferExternalDaemonIfAvailable: Bool = false

    public var onIndexUpdated: (@Sendable (Int, Double) -> Void)?
    public var onDirectoryChangedOnDisk: (@Sendable (Set<String>) -> Void)?

    private var lockPtr: UnsafeMutablePointer<pthread_rwlock_t>

    public var cacheFilePath: String {
        let cachesDir = ("~/Library/Caches/BetterFinder" as NSString).expandingTildeInPath
        if (try? FileManager.default.createDirectory(atPath: cachesDir, withIntermediateDirectories: true)) != nil {
            return "\(cachesDir)/fsearch_index.bin"
        }
        return "/tmp/betterfinder_fsearch_index.bin"
    }

    private init() {
        lockPtr = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(lockPtr, nil)

        let home = NSHomeDirectory()
        self.configuredRoots = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/dev",
            "\(home)/Projects",
            "\(home)/Developer",
            "/Applications"
        ].filter { FileManager.default.fileExists(atPath: $0) }
        self.skippedDirectoryNames = BulkCrawler.defaultSkippedDirectoryNames

        checkExternalFSearchDaemon()
    }

    deinit {
        stopFSEvents()
        pthread_rwlock_destroy(lockPtr)
        lockPtr.deallocate()
    }

    public var trigramCacheCount: Int {
        trigramLock.lock()
        defer { trigramLock.unlock() }
        return trigramBloomCache.count
    }

    public func checkExternalFSearchDaemon() {
        let socketPath = ("~/Library/Application Support/FSearch/fsearch.sock" as NSString).expandingTildeInPath
        let binPath1 = ("~/.local/bin/fsearch" as NSString).expandingTildeInPath
        let binPath2 = "/opt/homebrew/bin/fsearch"
        let fm = FileManager.default
        externalFSearchAvailable = fm.fileExists(atPath: socketPath) ||
                                   fm.isExecutableFile(atPath: binPath1) ||
                                   fm.isExecutableFile(atPath: binPath2)
    }

    public func recordGitStatuses(_ map: [String: GitFileStatus]) {
        guard !map.isEmpty else { return }
        gitLock.lock()
        for (k, v) in map {
            globalGitStatusMap[k] = v
        }
        gitLock.unlock()
    }

    /// Starts initial parallel `getattrlistbulk` index build + `mmap` instant warmup + `FSEvents` real-time watcher
    public func startIndexing(roots: [String]? = nil) {
        guard !isIndexing else { return }
        isIndexing = true

        if let customRoots = roots {
            self.configuredRoots = customRoots
        }
        let targetRoots = self.configuredRoots
        let skipHeavy = self.skipHeavyDevDirs
        let skippedSet = self.skippedDirectoryNames

        // 1. Instant warm-up from persistent mmap binary cache if available
        if usePersistentMMapCache && entries.isEmpty {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self = self else { return }
                let t0 = DispatchTime.now().uptimeNanoseconds
                if let cachedEntries = self.loadIndexFromDiskMMapCache(), !cachedEntries.isEmpty {
                    var map: [String: [Int]] = [:]
                    map.reserveCapacity(cachedEntries.count / 8)
                    for (idx, item) in cachedEntries.enumerated() {
                        map[item.parentPath, default: []].append(idx)
                    }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
                    pthread_rwlock_wrlock(self.lockPtr)
                    if self.entries.isEmpty {
                        self.entries = cachedEntries
                        self.dirToIndices = map
                        self.indexedCount = cachedEntries.count
                        self.loadedFromMMapCache = true
                    }
                    pthread_rwlock_unlock(self.lockPtr)
                    self.onIndexUpdated?(cachedEntries.count, ms)
                }
            }
        }

        // 2. Background full crawl via `getattrlistbulk` + persist to mmap file
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let t0 = DispatchTime.now().uptimeNanoseconds

            let crawled = BulkCrawler.crawlTree(
                roots: targetRoots,
                skipHeavyDevDirs: skipHeavy,
                customSkippedDirs: skippedSet,
                maxEntries: 500_000
            ) { [weak self] partialCount in
                self?.indexedCount = partialCount
            }

            var map: [String: [Int]] = [:]
            map.reserveCapacity(crawled.count / 8)
            for (idx, item) in crawled.enumerated() {
                map[item.parentPath, default: []].append(idx)
            }

            let t1 = DispatchTime.now().uptimeNanoseconds
            let ms = Double(t1 - t0) / 1_000_000.0

            pthread_rwlock_wrlock(self.lockPtr)
            self.entries = crawled
            self.dirToIndices = map
            self.indexedCount = crawled.count
            self.lastCrawlDurationMs = ms
            self.isIndexing = false
            pthread_rwlock_unlock(self.lockPtr)

            self.onIndexUpdated?(crawled.count, ms)
            self.startFSEvents(watching: targetRoots)

            if self.usePersistentMMapCache {
                self.saveIndexToDiskMMapCache(crawled)
            }
        }
    }

    // MARK: - Persistent Binary MMap Index Serialization

    private func saveIndexToDiskMMapCache(_ list: [IndexedFileEntry]) {
        let path = cacheFilePath
        var data = Data()
        data.reserveCapacity(list.count * 64)

        // Header: "FSRC" (4 bytes) + version 1 (UInt32) + count (UInt32)
        let magic: [UInt8] = [0x46, 0x53, 0x52, 0x43]
        data.append(contentsOf: magic)
        var version: UInt32 = 1
        var count = UInt32(list.count)
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for item in list where !item.name.isEmpty {
            let nameUTF8 = Array(item.name.utf8)
            let parentUTF8 = Array(item.parentPath.utf8)
            let extUTF8 = Array(item.ext.utf8)
            guard nameUTF8.count < 65535, parentUTF8.count < 65535, extUTF8.count < 255 else { continue }

            var nameLen = UInt16(nameUTF8.count)
            var parentLen = UInt16(parentUTF8.count)
            let extLen = UInt8(extUTF8.count)
            let flags: UInt8 = (item.isDirectory ? 1 : 0) | (item.isSymlink ? 2 : 0) | (item.isHidden ? 4 : 0)
            var mask = item.charMask
            var size = item.size
            var mtime = item.mtimeEpoch

            withUnsafeBytes(of: &nameLen) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &parentLen) { data.append(contentsOf: $0) }
            data.append(extLen)
            data.append(flags)
            withUnsafeBytes(of: &mask) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &mtime) { data.append(contentsOf: $0) }
            data.append(contentsOf: nameUTF8)
            data.append(contentsOf: parentUTF8)
            data.append(contentsOf: extUTF8)
        }

        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadIndexFromDiskMMapCache() -> [IndexedFileEntry]? {
        let url = URL(fileURLWithPath: cacheFilePath)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 12 else {
            return nil
        }

        return data.withUnsafeBytes { rawBuf -> [IndexedFileEntry]? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let totalBytes = rawBuf.count
            guard base[0] == 0x46, base[1] == 0x53, base[2] == 0x52, base[3] == 0x43 else { return nil }

            let version = rawBuf.baseAddress!.advanced(by: 4).loadUnaligned(as: UInt32.self)
            guard version == 1 else { return nil }
            let expectedCount = Int(rawBuf.baseAddress!.advanced(by: 8).loadUnaligned(as: UInt32.self))

            var result: [IndexedFileEntry] = []
            result.reserveCapacity(min(expectedCount, 500_000))

            var offset = 12
            while offset + 30 <= totalBytes {
                let ptr = rawBuf.baseAddress!.advanced(by: offset)
                let nameLen = Int(ptr.loadUnaligned(as: UInt16.self))
                let parentLen = Int(ptr.advanced(by: 2).loadUnaligned(as: UInt16.self))
                let extLen = Int(base[offset + 4])
                let flags = base[offset + 5]
                let mask = ptr.advanced(by: 6).loadUnaligned(as: UInt64.self)
                let size = ptr.advanced(by: 14).loadUnaligned(as: Int64.self)
                let mtime = ptr.advanced(by: 22).loadUnaligned(as: Int64.self)
                offset += 30

                guard offset + nameLen + parentLen + extLen <= totalBytes else { break }
                let nameSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: nameLen)
                let name = String(decoding: nameSlice, as: UTF8.self)
                offset += nameLen

                let parentSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: parentLen)
                let parentPath = String(decoding: parentSlice, as: UTF8.self)
                offset += parentLen

                let extSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: extLen)
                let ext = String(decoding: extSlice, as: UTF8.self)
                offset += extLen

                let lowerBytes = Array(name.lowercased().utf8)
                result.append(IndexedFileEntry(
                    name: name,
                    lowerNameUTF8: lowerBytes,
                    parentPath: parentPath,
                    ext: ext,
                    charMask: mask,
                    size: size,
                    mtimeEpoch: mtime,
                    isDirectory: (flags & 1) != 0,
                    isSymlink: (flags & 2) != 0,
                    isHidden: (flags & 4) != 0
                ))
            }
            return result
        }
    }

    /// Dynamically ensures a specific folder tree is indexed when user navigates into it
    public func ensureDirectoryIndexed(_ dirPath: String) {
        pthread_rwlock_rdlock(lockPtr)
        let alreadyIndexed = dirToIndices[dirPath] != nil
        pthread_rwlock_unlock(lockPtr)

        if !alreadyIndexed {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.refreshDirectoryInIndex(dirPath)
            }
        }
    }

    /// Differential update of a single directory (called by FSEvents in real-time)
    public func refreshDirectoryInIndex(_ dirPath: String) {
        let normalized = dirPath.count > 1 && dirPath.hasSuffix("/") ? String(dirPath.dropLast()) : dirPath
        let freshItems = BulkCrawler.readDirectoryFast(at: normalized, includeHidden: true)

        pthread_rwlock_wrlock(lockPtr)
        if let existingIndices = dirToIndices[normalized], !existingIndices.isEmpty {
            for idx in existingIndices where idx < entries.count {
                entries[idx] = IndexedFileEntry(
                    name: "",
                    lowerNameUTF8: [],
                    parentPath: "",
                    ext: "",
                    charMask: 0,
                    size: 0,
                    mtimeEpoch: 0,
                    isDirectory: false,
                    isSymlink: false,
                    isHidden: true
                )
            }
        }
        var newIdxList: [Int] = []
        newIdxList.reserveCapacity(freshItems.count)
        for item in freshItems {
            let newIdx = entries.count
            entries.append(item)
            newIdxList.append(newIdx)
        }
        dirToIndices[normalized] = newIdxList
        indexedCount = entries.count
        pthread_rwlock_unlock(lockPtr)
    }

    // MARK: - Sub-millisecond Search Execution

    public func search(
        rawQuery: String,
        scope: SearchScopeMode,
        scopeDirectory: String,
        includeHidden: Bool,
        fuzzyEnabled: Bool = true
    ) -> FSearchResultBundle {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let parsed = ParsedFSearchQuery.parse(rawQuery, fuzzyEnabled: fuzzyEnabled)

        guard parsed.hasFiltersOrTerms else {
            return FSearchResultBundle(
                items: [],
                elapsedMilliseconds: 0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch-native"
            )
        }

        if preferExternalDaemonIfAvailable && scope == .wholeIndex,
           let extItems = queryExternalFSearchSocket(rawQuery: rawQuery, limit: parsed.limit) {
            let t1 = DispatchTime.now().uptimeNanoseconds
            return FSearchResultBundle(
                items: extItems,
                elapsedMilliseconds: Double(t1 - t0) / 1_000_000.0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch.sock"
            )
        }

        let normalizedScopeDir = scopeDirectory.count > 1 && scopeDirectory.hasSuffix("/")
            ? String(scopeDirectory.dropLast())
            : scopeDirectory

        let candidateEntries: [IndexedFileEntry]
        switch scope {
        case .currentFolder:
            candidateEntries = BulkCrawler.readDirectoryFast(at: normalizedScopeDir, includeHidden: includeHidden)
        case .recursiveFolder:
            pthread_rwlock_rdlock(lockPtr)
            let snap = entries
            pthread_rwlock_unlock(lockPtr)
            let prefix = normalizedScopeDir == "/" ? "/" : normalizedScopeDir + "/"
            let filtered = snap.filter { !$0.name.isEmpty && ($0.parentPath == normalizedScopeDir || $0.parentPath.hasPrefix(prefix)) }
            if !filtered.isEmpty {
                candidateEntries = filtered
            } else {
                candidateEntries = BulkCrawler.crawlTree(roots: [normalizedScopeDir], skipHeavyDevDirs: true, maxEntries: 50_000)
            }
        case .wholeIndex:
            pthread_rwlock_rdlock(lockPtr)
            candidateEntries = entries
            pthread_rwlock_unlock(lockPtr)
        }

        let totalCount = candidateEntries.count
        if totalCount == 0 {
            let t1 = DispatchTime.now().uptimeNanoseconds
            return FSearchResultBundle(
                items: [],
                elapsedMilliseconds: Double(t1 - t0) / 1_000_000.0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch-native"
            )
        }

        let compiledRegex: NSRegularExpression?
        if let pattern = parsed.regexPattern {
            compiledRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } else {
            compiledRegex = nil
        }

        let gitSnapshot: [String: GitFileStatus]
        if parsed.gitFilter != nil {
            let dirGit = FileOperationsManager.fetchGitStatusMap(for: normalizedScopeDir)
            gitLock.lock()
            for (k, v) in dirGit { globalGitStatusMap[k] = v }
            gitSnapshot = globalGitStatusMap
            gitLock.unlock()
        } else {
            gitSnapshot = [:]
        }

        let now = Date()
        let chunkSize = max(2048, (totalCount + 7) / 8)
        let numChunks = (totalCount + chunkSize - 1) / chunkSize

        struct ScoredCandidate: Sendable {
            let index: Int
            let score: Int
        }

        let chunkLock = NSLock()
        var allScored: [ScoredCandidate] = []
        allScored.reserveCapacity(min(parsed.limit * 2, 1024))

        DispatchQueue.concurrentPerform(iterations: numChunks) { chunkIdx in
            let start = chunkIdx * chunkSize
            let end = min(start + chunkSize, totalCount)
            var localMatches: [ScoredCandidate] = []

            for i in start..<end {
                let entry = candidateEntries[i]
                if entry.name.isEmpty { continue }
                if !includeHidden && entry.isHidden { continue }

                if let score = Self.evaluateEntry(
                    entry,
                    query: parsed,
                    compiledRegex: compiledRegex,
                    gitStatusMap: gitSnapshot,
                    now: now
                ) {
                    localMatches.append(ScoredCandidate(index: i, score: score))
                }
            }

            if !localMatches.isEmpty {
                chunkLock.lock()
                allScored.append(contentsOf: localMatches)
                chunkLock.unlock()
            }
        }

        allScored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return candidateEntries[a.index].mtimeEpoch > candidateEntries[b.index].mtimeEpoch
        }

        let finalItems: [FileItem]
        if let grepPattern = parsed.grepPattern, !grepPattern.isEmpty {
            let maxGrepCandidates = min(allScored.count, 1500)
            let grepSlice = Array(allScored.prefix(maxGrepCandidates))
            let grepLock = NSLock()
            var grepMatched: [(Int, FileItem)] = []
            let needleTrigramMask = parsed.grepTrigramMask

            DispatchQueue.concurrentPerform(iterations: grepSlice.count) { idx in
                let cand = grepSlice[idx]
                let entry = candidateEntries[cand.index]
                if entry.isDirectory || entry.size <= 0 || entry.size > 15 * 1024 * 1024 {
                    return
                }
                let fullPath = entry.fullPath

                // Check 64-bit Trigram Bloom Filter cache before touching disk/mmap!
                if needleTrigramMask != 0 {
                    self.trigramLock.lock()
                    let cached = self.trigramBloomCache[fullPath]
                    self.trigramLock.unlock()

                    if let (cachedMtime, fileTrigramMask) = cached, cachedMtime == entry.mtimeEpoch {
                        if (fileTrigramMask & needleTrigramMask) != needleTrigramMask {
                            // 100% guaranteed no match by Trigram Bloom filter!
                            return
                        }
                    }
                }

                if let snippet = self.grepFileContentWithTrigramCache(
                    path: fullPath,
                    mtimeEpoch: entry.mtimeEpoch,
                    pattern: grepPattern,
                    needleTrigramMask: needleTrigramMask
                ) {
                    let item = entry.toFileItem(
                        grepMatch: snippet,
                        gitStatus: gitSnapshot[fullPath],
                        score: cand.score + 100
                    )
                    grepLock.lock()
                    grepMatched.append((cand.score, item))
                    grepLock.unlock()
                }
            }

            grepMatched.sort { $0.0 > $1.0 }
            finalItems = grepMatched.prefix(parsed.limit).map { $0.1 }
        } else {
            let limited = allScored.prefix(parsed.limit)
            finalItems = limited.map { cand in
                let entry = candidateEntries[cand.index]
                return entry.toFileItem(
                    gitStatus: gitSnapshot[entry.fullPath],
                    score: cand.score
                )
            }
        }

        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0

        return FSearchResultBundle(
            items: finalItems,
            elapsedMilliseconds: elapsedMs,
            totalIndexedCount: indexedCount,
            backendName: loadedFromMMapCache ? "fsearch-mmap" : "fsearch-native"
        )
    }

    // MARK: - Entry Evaluation & Fuzzy / 1-Typo Scoring

    @inline(__always)
    private static func evaluateEntry(
        _ entry: IndexedFileEntry,
        query: ParsedFSearchQuery,
        compiledRegex: NSRegularExpression?,
        gitStatusMap: [String: GitFileStatus],
        now: Date
    ) -> Int? {
        if !query.extensions.isEmpty && !query.extensions.contains(entry.ext) {
            return nil
        }
        if !query.excludedExtensions.isEmpty && query.excludedExtensions.contains(entry.ext) {
            return nil
        }
        if let symOnly = query.symlinkOnly, entry.isSymlink != symOnly {
            return nil
        }
        if !query.typeFilters.isEmpty {
            let kind = FileKindCategory.detect(extension: entry.ext, isDirectory: entry.isDirectory)
            let kindLower = kind.rawValue.lowercased()
            var typeMatched = false
            for tf in query.typeFilters {
                switch tf {
                case "dir", "folder", "d":
                    if entry.isDirectory { typeMatched = true }
                case "file", "f":
                    if !entry.isDirectory { typeMatched = true }
                case "symlink", "sym", "link":
                    if entry.isSymlink { typeMatched = true }
                case "doc", "docs", "document":
                    if kind == .document { typeMatched = true }
                case "img", "image", "photo", "pic":
                    if kind == .image { typeMatched = true }
                case "vid", "video", "movie":
                    if kind == .video { typeMatched = true }
                case "aud", "audio", "music":
                    if kind == .audio { typeMatched = true }
                case "arc", "archive", "zip":
                    if kind == .archive { typeMatched = true }
                case "exec", "app", "bin":
                    if kind == .executable || entry.ext == "app" { typeMatched = true }
                default:
                    if kindLower == tf || entry.ext == tf { typeMatched = true }
                }
                if typeMatched { break }
            }
            if !typeMatched { return nil }
        }

        if !query.sizeFilters.isEmpty {
            for sf in query.sizeFilters {
                if !sf.matches(entry.size) { return nil }
            }
        }

        if !query.mtimeFilters.isEmpty {
            let modDate = Date(timeIntervalSince1970: TimeInterval(entry.mtimeEpoch))
            for mf in query.mtimeFilters {
                if !mf.matches(modDate, now: now) { return nil }
            }
        }

        if !query.pathSubstrings.isEmpty {
            let parentLower = entry.parentPath.lowercased()
            for ps in query.pathSubstrings {
                if !parentLower.contains(ps) { return nil }
            }
        }

        if let gf = query.gitFilter {
            guard let status = gitStatusMap[entry.fullPath] else { return nil }
            switch gf {
            case "m", "mod", "modified":
                if status != .modified { return nil }
            case "a", "staged", "added":
                if status != .staged { return nil }
            case "?", "u", "untracked":
                if status != .untracked { return nil }
            default:
                break // "any" or "*" matches any git status
            }
        }

        if !query.tagFilters.isEmpty {
            let url = URL(fileURLWithPath: entry.fullPath, isDirectory: entry.isDirectory)
            let fileTags = Set(FinderTagColor.readTags(for: url))
            if fileTags.isDisjoint(with: query.tagFilters) {
                return nil
            }
        }

        var totalScore = 100

        for term in query.terms {
            switch term {
            case .excluded(let ex):
                let exBytes = Array(ex.utf8)
                if containsSubslice(haystack: entry.lowerNameUTF8, needle: exBytes) {
                    return nil
                }

            case .exact(let ex):
                let exBytes = Array(ex.utf8)
                if entry.lowerNameUTF8 == exBytes {
                    totalScore += 500
                } else if containsSubslice(haystack: entry.lowerNameUTF8, needle: exBytes) {
                    totalScore += 250
                } else {
                    return nil
                }

            case .prefix(let pre):
                let preBytes = Array(pre.utf8)
                if startsWithSubslice(haystack: entry.lowerNameUTF8, prefix: preBytes) {
                    totalScore += 350
                } else {
                    return nil
                }

            case .suffix(let suf):
                let sufBytes = Array(suf.utf8)
                if endsWithSubslice(haystack: entry.lowerNameUTF8, suffix: sufBytes) {
                    totalScore += 300
                } else {
                    return nil
                }

            case .fuzzyOrSubstring(_, let needleBytes, let termMask):
                if needleBytes.isEmpty { continue }

                let missingBits = (termMask & ~entry.charMask).nonzeroBitCount
                let allowOneTypo = query.fuzzyTypoTolerance && needleBytes.count >= 5

                if missingBits == 0 {
                    if entry.lowerNameUTF8 == needleBytes {
                        totalScore += 1000
                        continue
                    }
                    if startsWithSubslice(haystack: entry.lowerNameUTF8, prefix: needleBytes) {
                        totalScore += 650 - min(entry.lowerNameUTF8.count, 50)
                        continue
                    }
                    if let pos = indexOfSubslice(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        let boundaryBonus: Int
                        if pos > 0 {
                            let prev = entry.lowerNameUTF8[pos - 1]
                            boundaryBonus = (prev == 45 || prev == 95 || prev == 46 || prev == 32) ? 120 : 0
                        } else {
                            boundaryBonus = 150
                        }
                        totalScore += 400 + boundaryBonus - min(pos * 4, 80)
                        continue
                    }
                    if allowOneTypo && hasOneTypoSubstringMatch(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += 280
                        continue
                    }
                    if query.fuzzyTypoTolerance,
                       let fuzzyScore = fuzzySubsequenceScore(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += fuzzyScore
                        continue
                    }
                    return nil
                } else if allowOneTypo && missingBits <= 1 {
                    if hasOneTypoSubstringMatch(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += 240
                        continue
                    }
                    return nil
                } else {
                    return nil
                }
            }
        }

        if let regex = compiledRegex {
            let name = entry.name
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) == nil {
                return nil
            }
            totalScore += 200
        }

        return totalScore
    }

    // MARK: - Ultra-Fast UTF-8 Byte Helpers

    @inline(__always)
    private static func startsWithSubslice(haystack: [UInt8], prefix: [UInt8]) -> Bool {
        guard prefix.count <= haystack.count else { return false }
        for i in 0..<prefix.count {
            if haystack[i] != prefix[i] { return false }
        }
        return true
    }

    @inline(__always)
    private static func endsWithSubslice(haystack: [UInt8], suffix: [UInt8]) -> Bool {
        guard suffix.count <= haystack.count else { return false }
        let offset = haystack.count - suffix.count
        for i in 0..<suffix.count {
            if haystack[offset + i] != suffix[i] { return false }
        }
        return true
    }

    @inline(__always)
    private static func containsSubslice(haystack: [UInt8], needle: [UInt8]) -> Bool {
        indexOfSubslice(haystack: haystack, needle: needle) != nil
    }

    @inline(__always)
    private static func indexOfSubslice(haystack: [UInt8], needle: [UInt8]) -> Int? {
        let hCount = haystack.count
        let nCount = needle.count
        if nCount == 0 { return 0 }
        if nCount > hCount { return nil }
        let first = needle[0]
        let limit = hCount - nCount
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var matched = true
                for j in 1..<nCount {
                    if haystack[i + j] != needle[j] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    private static func fuzzySubsequenceScore(haystack: [UInt8], needle: [UInt8]) -> Int? {
        let hCount = haystack.count
        let nCount = needle.count
        guard nCount <= hCount else { return nil }

        var hIdx = 0
        var nIdx = 0
        var firstMatchIdx = -1
        var lastMatchIdx = -1
        var consecutiveCount = 0

        while hIdx < hCount && nIdx < nCount {
            if haystack[hIdx] == needle[nIdx] {
                if firstMatchIdx == -1 { firstMatchIdx = hIdx }
                if lastMatchIdx == hIdx - 1 {
                    consecutiveCount += 1
                }
                lastMatchIdx = hIdx
                nIdx += 1
            }
            hIdx += 1
        }

        guard nIdx == nCount else { return nil }
        let span = lastMatchIdx - firstMatchIdx + 1
        if span > nCount * 3 + 4 { return nil }
        return max(60, 220 + (consecutiveCount * 25) - (span - nCount) * 12 - firstMatchIdx * 3)
    }

    @inline(__always)
    private static func hasOneTypoSubstringMatch(haystack: [UInt8], needle: [UInt8]) -> Bool {
        let hLen = haystack.count
        let nLen = needle.count
        guard nLen >= 5, hLen >= nLen - 1 else { return false }

        let maxStart = max(0, hLen - (nLen - 1))
        for start in 0...maxStart {
            var i = start
            var j = 0
            var edits = 0

            while i < hLen && j < nLen {
                if haystack[i] == needle[j] {
                    i += 1
                    j += 1
                } else {
                    edits += 1
                    if edits > 1 { break }

                    if i + 1 < hLen && j + 1 < nLen &&
                       haystack[i] == needle[j + 1] && haystack[i + 1] == needle[j] {
                        i += 2
                        j += 2
                    } else if i + 1 < hLen && haystack[i + 1] == needle[j] {
                        i += 1
                    } else if j + 1 < nLen && haystack[i] == needle[j + 1] {
                        j += 1
                    } else {
                        i += 1
                        j += 1
                    }
                }
            }
            let remainingNeedle = nLen - j
            if edits + remainingNeedle <= 1 {
                return true
            }
        }
        return false
    }

    // MARK: - Memory-Mapped Content Grep with 64-bit Trigram Bloom Filter Cache

    private func grepFileContentWithTrigramCache(
        path: String,
        mtimeEpoch: Int64,
        pattern: String,
        needleTrigramMask: UInt64
    ) -> GrepMatchSnippet? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return nil
        }

        let checkCount = min(data.count, 512)
        for idx in 0..<checkCount {
            if data[idx] == 0 { return nil }
        }

        let needleBytes = Array(pattern.lowercased().utf8)
        guard !needleBytes.isEmpty else { return nil }
        let nLen = needleBytes.count

        return data.withUnsafeBytes { rawBuffer -> GrepMatchSnippet? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let count = rawBuffer.count
            guard count >= nLen else { return nil }

            // Compute and cache 64-bit trigram Bloom filter for files <= 256KB
            if needleTrigramMask != 0 && count <= 262_144 && count >= 3 {
                var fileMask: UInt64 = 0
                let triLimit = count - 2
                var k = 0
                while k < triLimit {
                    let b0 = (base[k] >= 65 && base[k] <= 90) ? (base[k] + 32) : base[k]
                    let b1 = (base[k + 1] >= 65 && base[k + 1] <= 90) ? (base[k + 1] + 32) : base[k + 1]
                    let b2 = (base[k + 2] >= 65 && base[k + 2] <= 90) ? (base[k + 2] + 32) : base[k + 2]
                    let hash = (UInt32(b0) &* 31 &+ UInt32(b1)) &* 31 &+ UInt32(b2)
                    fileMask |= (1 << UInt64(hash & 63)) | (1 << UInt64((hash >> 6) & 63))
                    k += 1
                }
                self.trigramLock.lock()
                if self.trigramBloomCache.count > 25_000 {
                    self.trigramBloomCache.removeAll(keepingCapacity: true)
                }
                self.trigramBloomCache[path] = (mtimeEpoch, fileMask)
                self.trigramLock.unlock()

                if (fileMask & needleTrigramMask) != needleTrigramMask {
                    return nil
                }
            }

            let firstLower = needleBytes[0]
            let firstUpper = (firstLower >= 97 && firstLower <= 122) ? (firstLower - 32) : firstLower
            let limit = count - nLen

            var i = 0
            while i <= limit {
                let b = base[i]
                if b == firstLower || b == firstUpper {
                    var matched = true
                    for j in 1..<nLen {
                        let c = base[i + j]
                        let cl = (c >= 65 && c <= 90) ? (c + 32) : c
                        if cl != needleBytes[j] {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        var lineNum = 1
                        var lineStart = i
                        while lineStart > 0 && base[lineStart - 1] != 10 && base[lineStart - 1] != 13 {
                            lineStart -= 1
                        }
                        for k in 0..<lineStart {
                            if base[k] == 10 { lineNum += 1 }
                        }
                        var lineEnd = i + nLen
                        while lineEnd < count && base[lineEnd] != 10 && base[lineEnd] != 13 && (lineEnd - lineStart) < 220 {
                            lineEnd += 1
                        }
                        let slice = UnsafeBufferPointer(start: base.advanced(by: lineStart), count: lineEnd - lineStart)
                        let lineStr = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                        return GrepMatchSnippet(
                            lineNumber: lineNum,
                            lineText: lineStr,
                            matchRangeLower: max(0, i - lineStart),
                            matchRangeUpper: max(0, i - lineStart + nLen)
                        )
                    }
                }
                i += 1
            }
            return nil
        }
    }

    // MARK: - macOS FSEvents Real-Time Differential Index Watcher

    private func startFSEvents(watching paths: [String]) {
        stopFSEvents()
        guard !paths.isEmpty else { return }

        let cfPaths = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, numEvents, eventPaths, _, _) in
            guard let info = clientCallBackInfo else { return }
            let engine = Unmanaged<FSearchIndex>.fromOpaque(info).takeUnretainedValue()
            guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

            var modifiedDirs = Set<String>()
            for i in 0..<min(numEvents, pathsArray.count) {
                let p = pathsArray[i]
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    modifiedDirs.insert(p)
                } else {
                    let parent = (p as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        modifiedDirs.insert(parent)
                    }
                }
            }

            for dir in modifiedDirs {
                engine.refreshDirectoryInIndex(dir)
            }
            if !modifiedDirs.isEmpty {
                engine.onDirectoryChangedOnDisk?(modifiedDirs)
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        if let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.12,
            flags
        ) {
            eventStream = stream
            FSEventStreamSetDispatchQueue(stream, fseventsQueue)
            FSEventStreamStart(stream)
        }
    }

    private func stopFSEvents() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    // MARK: - Optional Bridge to External `noahdunnagan/fsearch` Unix Socket

    private func queryExternalFSearchSocket(rawQuery: String, limit: Int) -> [FileItem]? {
        let socketPath = ("~/Library/Application Support/FSearch/fsearch.sock" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (idx, b) in pathBytes.enumerated() {
                ptr[idx] = UInt8(bitPattern: b)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let payload: [String: Any] = ["q": rawQuery, "limit": limit, "offset": 0]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              var lineData = String(data: jsonData, encoding: .utf8)?.data(using: .utf8) else {
            return nil
        }
        lineData.append(0x0A)

        _ = lineData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, ptr.count)
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return nil }
        responseData.append(buffer, count: bytesRead)

        guard let text = String(data: responseData, encoding: .utf8) else { return nil }
        var items: [FileItem] = []
        for line in text.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = obj["results"] as? [[String: Any]] {
                for r in results {
                    if let p = r["path"] as? String {
                        let url = URL(fileURLWithPath: p)
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                        items.append(FileItem(
                            url: url,
                            name: url.lastPathComponent,
                            path: p,
                            parentPath: url.deletingLastPathComponent().path,
                            fileExtension: url.pathExtension.lowercased(),
                            isDirectory: isDir.boolValue,
                            isHidden: url.lastPathComponent.hasPrefix("."),
                            size: (r["size"] as? Int64) ?? 0,
                            modificationDate: Date()
                        ))
                    }
                }
            }
        }
        return items.isEmpty ? nil : items
    }
}
