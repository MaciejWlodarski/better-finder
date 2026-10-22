import Foundation

@MainActor
public final class FolderSizeCache: ObservableObject {
    public static let shared = FolderSizeCache()

    @Published public private(set) var sizes: [String: Int64] = [:]
    private var inFlight: [String: UUID] = [:]
    private let workerQueue = DispatchQueue(label: "com.betterfinder.foldersize", qos: .utility, attributes: .concurrent)

    private init() {}

    public func size(for folderPath: String) -> Int64? {
        sizes[folderPath]
    }

    public func requestSizeIfNeeded(for folderPath: String) {
        guard sizes[folderPath] == nil, inFlight[folderPath] == nil else { return }
        let requestID = UUID()
        inFlight[folderPath] = requestID

        workerQueue.async {
            let computed = Self.calculateFolderSizeFast(at: folderPath, maxDepth: 4, maxVisited: 15_000)
            Task { @MainActor in
                guard self.inFlight[folderPath] == requestID else { return }
                self.sizes[folderPath] = computed
                self.inFlight.removeValue(forKey: folderPath)
            }
        }
    }

    public func invalidate(_ folderPath: String) {
        sizes.removeValue(forKey: folderPath)
        inFlight.removeValue(forKey: folderPath)
    }

    public func invalidate(containing changedPath: String) {
        let normalized = URL(fileURLWithPath: changedPath).standardizedFileURL.path
        let affected = Set(sizes.keys).union(inFlight.keys).filter { cached in
            cached == normalized || normalized.hasPrefix(cached == "/" ? "/" : cached + "/")
                || cached.hasPrefix(normalized == "/" ? "/" : normalized + "/")
        }
        for path in affected { invalidate(path) }
    }

    nonisolated private static func calculateFolderSizeFast(at rootPath: String, maxDepth: Int, maxVisited: Int) -> Int64 {
        var total: Int64 = 0
        var visited = 0
        var queue: [(String, Int)] = [(rootPath, 0)]
        var head = 0

        while head < queue.count && visited < maxVisited {
            let (dir, depth) = queue[head]
            head += 1

            let entries = BulkCrawler.readDirectoryFast(at: dir, includeHidden: true)
            visited += entries.count

            for e in entries {
                if e.isDirectory && !e.isSymlink {
                    if depth < maxDepth {
                        queue.append((e.fullPath, depth + 1))
                    }
                } else {
                    total += e.size
                }
            }
        }
        return total
    }
}
