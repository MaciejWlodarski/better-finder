import Foundation

/// Exercises production matching separately from intentional subsequence fallback,
/// then verifies admission/ranking through crawler-backed and populated-index search.
struct SearchMatchingPrecisionRegressionTests {
    static func runAll() throws {
        #if BETTERFINDER_TESTING
        try oneEditAndAdmission()
        try fractionalModificationAge()
        print("PASS one-edit alternatives, mask admission, subsequence separation and fractional mtime")
        #endif
    }

    #if BETTERFINDER_TESTING
    private static func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-matching-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func engine(_ root: URL) -> FSearchIndex {
        let index = FSearchIndex(roots: [root.path], enableMonitoring: false)
        index.usePersistentMMapCache = false
        index.skipHeavyDevDirs = false
        return index
    }

    private static func oneEditAndAdmission() throws {
        // Each case runs alone, so no unrelated result can satisfy the assertion.
        // Typo expectations are checked directly to prevent subsequence rescue.
        let cases: [(name: String, term: String, typo: Bool, fuzzy: Bool, score: Int?)] = [
            ("abcde", "abcde", true, true, 1100), // exact
            ("abcdex", "abcde", true, true, 744), // prefix ranking unchanged
            ("abcxde", "abcde", true, true, 380), // extra haystack byte
            ("abde", "abcde", true, true, 340), // missing needle byte; missing mask bit
            ("abcxe", "abcde", true, true, 340), // substitution; missing mask bit
            ("abdce", "abcde", true, true, 380), // existing transposition
            ("abaaa.txt", "aaaaa", true, true, 380), // deletion/substitution ambiguity
            ("abbba", "ababa", true, true, 380), // needle-skip/substitution ambiguity
            ("aabaa", "aaaaa", true, true, 380), // repeated internal substitution
            ("aabaaa", "aaaaa", true, true, 380), // repeated insertion
            ("aaaa", "aabaa", true, true, 340), // repeated deletion
            ("abbaa", "ababa", true, true, 380), // repeated transposition
            ("abcd", "abcde", true, true, 340), // missing final byte
            ("zabcdeq", "abcde", true, true, 496), // substring ranking unchanged
            ("abxxe", "abcde", false, false, nil), // two substitutions; two missing bits
            ("axxaa", "abbaa", false, false, nil), // two edits with only one missing bit
            ("bbaaa", "ababa", false, false, nil), // two edits despite complete character mask
            ("cafèx", "caféx", true, true, 340), // one UTF-8 byte differs
            ("cafea", "cafeé", false, false, nil), // one character but two byte edits
            ("abcca", "abcde", false, false, nil), // two edits, no subsequence
            ("axbcxde", "abcde", false, true, nil), // two insertions, intentional subsequence
            ("abxcd", "abcd", false, true, nil), // <5: only subsequence, not typo
            ("abxd", "abcd", false, false, nil) // <5: substitution remains disabled
        ]
        for test in cases {
            try expect(FSearchIndex.oneTypoSubstringMatchesForTesting(test.name, test.term) == test.typo)
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data().write(to: root.appendingPathComponent(test.name))
            let index = engine(root)
            index.refreshDirectoryInIndex(root.path)
            for scope in [SearchScopeMode.currentFolder, .recursiveFolder, .wholeIndex] {
                let result = index.search(rawQuery: test.term, scope: scope, scopeDirectory: root.path,
                                          includeHidden: true, fuzzyEnabled: true)
                let expectedNames = test.fuzzy ? [test.name] : []
                guard result.items.map(\.name) == expectedNames else {
                    let crawled = BulkCrawler.readDirectoryFast(at: root.path).map {
                        "name=\($0.name.debugDescription), bytes=\($0.lowerNameUTF8), mask=\($0.charMask)"
                    }
                    throw RegressionFailure(description: "Matching case name=\(test.name.debugDescription), term=\(test.term.debugDescription), scope=\(scope), expected=\(expectedNames), actual=\(result.items.map(\.name)), queryBytes=\(Array(test.term.lowercased().utf8)), crawled=\(crawled), diagnostic=\(String(describing: result.diagnostic))")
                }
                if let score = test.score { try expect(result.items.first?.searchScore == score) }
                let strict = index.search(rawQuery: test.term, scope: scope, scopeDirectory: root.path,
                                          includeHidden: true, fuzzyEnabled: false)
                try expect(strict.items.map(\.name) == (test.name.contains(test.term) ? [test.name] : []))
                let cancelled = index.search(rawQuery: test.term, scope: scope, scopeDirectory: root.path,
                                             includeHidden: true, isCancelled: { true })
                try expect(cancelled.items.isEmpty && cancelled.isPartial)
            }
        }
    }

    private static func fractionalModificationAge() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch: Int64 = 1_700_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(epoch) + 1)
        let values: [(String, Int64)] = [("below", 750_000_000), ("equal", 500_000_000), ("above", 250_000_000)]
        for (name, nanos) in values {
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.modificationDate:
                Date(timeIntervalSince1970: TimeInterval(epoch) + TimeInterval(nanos) / 1_000_000_000)], ofItemAtPath: url.path)
        }
        let index = engine(root)
        index.searchDateForTesting = now
        index.refreshDirectoryInIndex(root.path)
        let entries = BulkCrawler.readDirectoryFast(at: root.path)
        try expect(entries.count == values.count)
        for (name, nanos) in values {
            let entry = entries.first { $0.name == name }
            try expect(entry?.mtimeEpoch == epoch && entry?.mtimeNanoseconds == nanos)
        }
        guard let decoded = index.decodeIndexCache(index.encodeIndexCache(entries)) else {
            throw RegressionFailure(description: "Timestamp cache round trip failed")
        }
        try expect(decoded.count == entries.count)
        try expect(Set(decoded.map(\.name)) == Set(entries.map(\.name)))
        for collection in [entries, decoded] {
            for entry in collection {
                let nanos = values.first { $0.0 == entry.name }!.1
                try expect(entry.mtimeEpoch == epoch && entry.mtimeNanoseconds == nanos)
                try expect(entry.toFileItem(loadTags: false).modificationDate == entry.modificationDate)
                try expect(FSearchIndex.ageFilteredEntryMatchesForTesting(entry, rawQuery: "mtime:<0.5s", now: now)
                           == (entry.name != "above"))
                try expect(FSearchIndex.ageFilteredEntryMatchesForTesting(entry, rawQuery: "mtime:>0.5s", now: now)
                           == (entry.name == "above"))
            }
        }
        for scope in [SearchScopeMode.currentFolder, .recursiveFolder, .wholeIndex] {
            let within = index.search(rawQuery: "mtime:<0.5s", scope: scope, scopeDirectory: root.path, includeHidden: true)
            let older = index.search(rawQuery: "mtime:>0.5s", scope: scope, scopeDirectory: root.path, includeHidden: true)
            try expect(Set(within.items.map(\.name)) == Set(["below", "equal"]))
            try expect(older.items.map(\.name) == ["above"])
        }
    }
    #endif
}
