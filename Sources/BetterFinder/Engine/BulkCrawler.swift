import Foundation
import Darwin

/// Compact indexed entry stored in contiguous memory for sub-millisecond fsearch queries
public struct IndexedFileEntry: Sendable {
    public let name: String
    public let lowerNameUTF8: [UInt8]
    public let parentPath: String
    public let ext: String
    public let charMask: UInt64
    public let size: Int64
    public let mtimeEpoch: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool

    public init(
        name: String,
        lowerNameUTF8: [UInt8],
        parentPath: String,
        ext: String,
        charMask: UInt64,
        size: Int64,
        mtimeEpoch: Int64,
        isDirectory: Bool,
        isSymlink: Bool,
        isHidden: Bool
    ) {
        self.name = name
        self.lowerNameUTF8 = lowerNameUTF8
        self.parentPath = parentPath
        self.ext = ext
        self.charMask = charMask
        self.size = size
        self.mtimeEpoch = mtimeEpoch
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
    }

    public var fullPath: String {
        if parentPath == "/" {
            return "/\(name)"
        }
        return "\(parentPath)/\(name)"
    }

    public func toFileItem(
        grepMatch: GrepMatchSnippet? = nil,
        gitStatus: GitFileStatus? = nil,
        treeDepth: Int = 0,
        score: Int = 0,
        loadTags: Bool = true
    ) -> FileItem {
        let p = fullPath
        let url = URL(fileURLWithPath: p, isDirectory: isDirectory)
        let modDate = Date(timeIntervalSince1970: TimeInterval(mtimeEpoch))
        let tags = loadTags ? FinderTagColor.readTags(for: url) : []
        return FileItem(
            url: url,
            name: name,
            path: p,
            parentPath: parentPath,
            fileExtension: ext,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isHidden: isHidden,
            size: size,
            modificationDate: modDate,
            creationDate: modDate,
            gitStatus: gitStatus,
            grepMatch: grepMatch,
            tags: tags,
            treeDepth: treeDepth,
            searchScore: score
        )
    }
}

/// High-speed macOS kernel `getattrlistbulk` directory reader (same underlying syscall used by noahdunnagan/fsearch)
public enum BulkCrawler {
    public static let defaultSkippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", ".Trash",
        "Caches", "CloudKit", "CoreSimulator", ".swiftpm", "target", "__pycache__",
        ".venv", "venv", ".next", ".nuxt", ".cache", ".cargo", ".rustup"
    ]

    /// Fast bulk listing of a single directory using Darwin `getattrlistbulk`
    public static func readDirectoryFast(at path: String, includeHidden: Bool = true) -> [IndexedFileEntry] {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) |
            attrgroup_t(ATTR_CMN_NAME) |
            attrgroup_t(ATTR_CMN_OBJTYPE) |
            attrgroup_t(ATTR_CMN_MODTIME)
        attrList.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)

        let bufSize = 128 * 1024
        let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { rawBuf.deallocate() }

        var results: [IndexedFileEntry] = []
        results.reserveCapacity(128)

        let normalizedParent = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path

        while true {
            let count = getattrlistbulk(fd, &attrList, rawBuf, bufSize, 0)
            if count <= 0 {
                break
            }

            var entryPtr = rawBuf
            for _ in 0..<count {
                let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                if entryLength <= 0 { break }

                var cursor = entryPtr.advanced(by: 4)
                let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

                var entryName: String? = nil
                if (returned.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                    let nameRef = cursor.loadUnaligned(as: attrreference_t.self)
                    let namePtr = cursor.advanced(by: Int(nameRef.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self)
                    entryName = String(cString: namePtr)
                    cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                }

                var objType: UInt32 = 0
                if (returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                    objType = cursor.loadUnaligned(as: UInt32.self)
                    cursor = cursor.advanced(by: 4)
                }

                var mtimeSec: Int64 = 0
                if (returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME)) != 0 {
                    mtimeSec = cursor.loadUnaligned(as: Int64.self)
                    cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                }

                var fileSize: Int64 = 0
                if (returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE)) != 0 {
                    fileSize = cursor.loadUnaligned(as: Int64.self)
                    cursor = cursor.advanced(by: 8)
                }

                if let name = entryName, name != "." && name != ".." {
                    let isHidden = name.hasPrefix(".")
                    if includeHidden || !isHidden {
                        let isDir = (objType == 2)
                        let isSymlink = (objType == 5)
                        let ext: String
                        if let dotIdx = name.lastIndex(of: "."), dotIdx != name.startIndex {
                            ext = String(name[name.index(after: dotIdx)...]).lowercased()
                        } else {
                            ext = ""
                        }
                        let lowerBytes = Array(name.lowercased().utf8)
                        let mask = ParsedFSearchQuery.computeAsciiBitmask(lowerBytes)

                        results.append(IndexedFileEntry(
                            name: name,
                            lowerNameUTF8: lowerBytes,
                            parentPath: normalizedParent,
                            ext: ext,
                            charMask: mask,
                            size: isDir ? 0 : fileSize,
                            mtimeEpoch: mtimeSec,
                            isDirectory: isDir,
                            isSymlink: isSymlink,
                            isHidden: isHidden
                        ))
                    }
                }

                entryPtr = entryPtr.advanced(by: entryLength)
            }
        }

        return results
    }

    /// Parallel multi-threaded recursive crawl using `getattrlistbulk`
    public static func crawlTree(
        roots: [String],
        skipHeavyDevDirs: Bool = true,
        customSkippedDirs: Set<String>? = nil,
        maxEntries: Int = 600_000,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [IndexedFileEntry] {
        let skippedSet = customSkippedDirs ?? defaultSkippedDirectoryNames
        var allEntries: [IndexedFileEntry] = []
        allEntries.reserveCapacity(min(maxEntries, 150_000))

        var queue: [String] = roots
        var head = 0

        while head < queue.count && allEntries.count < maxEntries {
            let batchEnd = min(head + 64, queue.count)
            let currentBatch = Array(queue[head..<batchEnd])
            head = batchEnd

            let batchCount = currentBatch.count
            let lock = NSLock()
            var batchEntries: [IndexedFileEntry] = []
            var newDirs: [String] = []

            DispatchQueue.concurrentPerform(iterations: batchCount) { i in
                let dirPath = currentBatch[i]
                let items = readDirectoryFast(at: dirPath, includeHidden: true)
                if items.isEmpty { return }

                var localSubdirs: [String] = []
                for item in items where item.isDirectory && !item.isSymlink {
                    if skipHeavyDevDirs && skippedSet.contains(item.name) {
                        continue
                    }
                    if item.name == "Library" && item.parentPath == NSHomeDirectory() {
                        continue
                    }
                    localSubdirs.append(item.fullPath)
                }

                lock.lock()
                batchEntries.append(contentsOf: items)
                newDirs.append(contentsOf: localSubdirs)
                lock.unlock()
            }

            allEntries.append(contentsOf: batchEntries)
            queue.append(contentsOf: newDirs)
            progress?(allEntries.count)
        }

        return allEntries
    }
}
