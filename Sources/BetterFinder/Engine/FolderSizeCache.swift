import Foundation

/// Bytes observed during a bounded walk. Incomplete walks are lower bounds,
/// never exact sizes; unreadable directories and entry limits remain explicit.
public struct FolderSizeResult: Sendable, Equatable {
    public let bytes: Int64
    public let isComplete: Bool
    public let skippedDirectoryCount: Int
    public let unreadableDirectoryCount: Int

    public init(bytes: Int64, isComplete: Bool, skippedDirectoryCount: Int = 0, unreadableDirectoryCount: Int = 0) {
        self.bytes = bytes
        self.isComplete = isComplete
        self.skippedDirectoryCount = skippedDirectoryCount
        self.unreadableDirectoryCount = unreadableDirectoryCount
    }
}

@MainActor
public final class FolderSizeCache: ObservableObject {
    public static let shared = FolderSizeCache()

    @Published public private(set) var sizes: [String: Int64] = [:]
    @Published public private(set) var results: [String: FolderSizeResult] = [:]
    private var inFlight: [String: UUID] = [:]
    private let workerQueue = DispatchQueue(label: "com.betterfinder.foldersize", qos: .utility, attributes: .concurrent)
    private let calculator: @Sendable (String) -> FolderSizeResult

    init(calculator: @escaping @Sendable (String) -> FolderSizeResult = {
        FolderSizeCache.calculateFolderSize(at: $0, maxEntries: 15_000)
    }) {
        self.calculator = calculator
    }

    /// Only an exact result can enter callers' exact totals and size comparisons.
    public func size(for folderPath: String) -> Int64? { sizes[folderPath] }
    public func result(for folderPath: String) -> FolderSizeResult? { results[folderPath] }

    public func displaySize(for folderPath: String) -> String? {
        guard let result = results[folderPath] else { return nil }
        return (result.isComplete ? "" : "≥ ") + FormatHelpers.formatBytes(result.bytes)
    }

    public func requestSizeIfNeeded(for folderPath: String) {
        guard results[folderPath] == nil, inFlight[folderPath] == nil else { return }
        let requestID = UUID()
        inFlight[folderPath] = requestID
        let calculate = calculator
        workerQueue.async {
            let computed = calculate(folderPath)
            Task { @MainActor in
                guard self.inFlight[folderPath] == requestID else { return }
                self.results[folderPath] = computed
                self.sizes[folderPath] = computed.isComplete ? computed.bytes : nil
                self.inFlight.removeValue(forKey: folderPath)
            }
        }
    }

    public func invalidate(_ folderPath: String) {
        sizes.removeValue(forKey: folderPath)
        results.removeValue(forKey: folderPath)
        inFlight.removeValue(forKey: folderPath)
    }

    public func invalidate(containing changedPath: String) {
        let normalized = URL(fileURLWithPath: changedPath).standardizedFileURL.path
        let affected = Set(results.keys).union(inFlight.keys).filter { cached in
            cached == normalized || normalized.hasPrefix(cached == "/" ? "/" : cached + "/")
                || cached.hasPrefix(normalized == "/" ? "/" : normalized + "/")
        }
        for path in affected { invalidate(path) }
    }

    nonisolated static func calculateFolderSize(at rootPath: String, maxEntries: Int) -> FolderSizeResult {
        let crawl = BulkCrawler.crawlTreeResult(roots: [rootPath], skipHeavyDevDirs: false,
                                                maxEntries: maxEntries, includeHidden: true)
        var total: Int64 = 0
        var overflowed = false
        for entry in crawl.entries where !entry.isDirectory || entry.isSymlink {
            let (sum, overflow) = total.addingReportingOverflow(max(0, entry.size))
            if overflow { total = .max; overflowed = true; break }
            total = sum
        }
        return FolderSizeResult(bytes: total, isComplete: crawl.isComplete && !overflowed,
            skippedDirectoryCount: crawl.skippedDirectoryCount,
            unreadableDirectoryCount: crawl.unreadableDirectoryCount)
    }
}
