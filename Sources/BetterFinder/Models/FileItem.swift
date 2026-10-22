import Foundation
import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

public enum FinderTagColor: String, CaseIterable, Identifiable, Sendable {
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case blue = "blue"
    case purple = "purple"
    case gray = "gray"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .red: return "Czerwony"
        case .orange: return "Pomarańczowy"
        case .yellow: return "Żółty"
        case .green: return "Zielony"
        case .blue: return "Niebieski"
        case .purple: return "Fioletowy"
        case .gray: return "Szary"
        }
    }

    public var systemTagName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    public static func from(rawTagName: String) -> FinderTagColor? {
        let lower = rawTagName.lowercased()
        switch lower {
        case "red", "czerwony": return .red
        case "orange", "pomarańczowy", "pomaranczowy": return .orange
        case "yellow", "żółty", "zolty": return .yellow
        case "green", "zielony": return .green
        case "blue", "niebieski": return .blue
        case "purple", "fioletowy": return .purple
        case "gray", "grey", "szary": return .gray
        default: return nil
        }
    }

    public static func readTags(for url: URL) -> [FinderTagColor] {
        guard let rawNames = try? readTagNames(for: url) else { return [] }
        return rawNames.compactMap { from(rawTagName: $0) }
    }

    public static func readTagNames(for url: URL) throws -> [String] {
        try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// Change the built-in colors while preserving custom tags and existing localized names.
    static func tagNames(replacingColorsWith tags: [FinderTagColor], in original: [String]) -> [String] {
        var names = original.filter { name in
            guard let color = from(rawTagName: name) else { return true }
            return tags.contains(color)
        }
        for color in tags where !names.contains(where: { from(rawTagName: $0) == color }) {
            names.append(color.systemTagName)
        }
        return names
    }

    public static func writeTags(_ tags: [FinderTagColor], to url: URL) throws {
        let names = tagNames(replacingColorsWith: tags, in: try readTagNames(for: url))
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    public static func clearAllTags(for url: URL) throws {
        try (url as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
    }
}

public enum FileKindCategory: String, CaseIterable, Sendable {
    case folder = "Folder"
    case code = "Code"
    case document = "Document"
    case image = "Image"
    case audio = "Audio"
    case video = "Video"
    case archive = "Archive"
    case executable = "Executable"
    case other = "File"

    public var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text.fill"
        case .image: return "photo.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .archive: return "doc.zipper"
        case .executable: return "terminal.fill"
        case .other: return "doc.fill"
        }
    }

    public var treemapColor: Color {
        switch self {
        case .folder: return .blue
        case .code: return .indigo
        case .document: return .teal
        case .image: return .pink
        case .audio: return .mint
        case .video: return .orange
        case .archive: return .yellow
        case .executable: return .red
        case .other: return .cyan
        }
    }

    public static func detect(extension ext: String, isDirectory: Bool) -> FileKindCategory {
        if isDirectory { return .folder }
        switch ext.lowercased() {
        case "swift", "rs", "py", "js", "ts", "tsx", "jsx", "c", "cpp", "h", "hpp", "m", "mm",
             "go", "java", "kt", "rb", "php", "cs", "sh", "zsh", "bash", "fish", "sql", "html",
             "css", "scss", "json", "yaml", "yml", "toml", "xml", "zig", "lua", "vue", "svelte":
            return .code
        case "md", "txt", "rtf", "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers",
             "ppt", "pptx", "key", "csv", "log", "org", "tex":
            return .document
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp", "ico", "icns", "psd", "raw":
            return .image
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff":
            return .audio
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .video
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg":
            return .archive
        case "app", "bin", "out", "dylib", "so", "wasm":
            return .executable
        default:
            return .other
        }
    }
}

public enum GitFileStatus: String, Sendable {
    case modified = "M"
    case staged = "A"
    case untracked = "?"
    case deleted = "D"
    case renamed = "R"

    public var badgeDescription: String {
        switch self {
        case .modified: return "Modified"
        case .staged: return "Staged"
        case .untracked: return "Untracked"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }
}

public struct GrepMatchSnippet: Sendable, Hashable {
    public let lineNumber: Int
    public let lineText: String
    public let matchRangeLower: Int
    public let matchRangeUpper: Int

    public init(lineNumber: Int, lineText: String, matchRangeLower: Int = 0, matchRangeUpper: Int = 0) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeLower = matchRangeLower
        self.matchRangeUpper = matchRangeUpper
    }
}

public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let url: URL
    public let name: String
    public let path: String
    public let parentPath: String
    public let fileExtension: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let kindCategory: FileKindCategory
    public var gitStatus: GitFileStatus?
    public var grepMatch: GrepMatchSnippet?
    public var tags: [FinderTagColor]
    public var treeDepth: Int
    public var searchScore: Int

    public init(
        url: URL,
        name: String,
        path: String,
        parentPath: String,
        fileExtension: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        isHidden: Bool,
        size: Int64,
        modificationDate: Date,
        creationDate: Date = .distantPast,
        kindCategory: FileKindCategory? = nil,
        gitStatus: GitFileStatus? = nil,
        grepMatch: GrepMatchSnippet? = nil,
        tags: [FinderTagColor] = [],
        treeDepth: Int = 0,
        searchScore: Int = 0
    ) {
        self.url = url
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.fileExtension = fileExtension
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.kindCategory = kindCategory ?? FileKindCategory.detect(extension: fileExtension, isDirectory: isDirectory)
        self.gitStatus = gitStatus
        self.grepMatch = grepMatch
        self.tags = tags
        self.treeDepth = treeDepth
        self.searchScore = searchScore
    }

    public var isExtractableArchive: Bool {
        guard !isDirectory else { return false }
        let ext = fileExtension.lowercased()
        return ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "dmg"].contains(ext)
    }

    public var supportsRichThumbnail: Bool {
        guard !isDirectory else { return false }
        switch kindCategory {
        case .image, .video:
            return true
        case .document:
            return ["pdf", "pages", "key", "numbers", "doc", "docx", "rtf"].contains(fileExtension.lowercased())
        default:
            return false
        }
    }

    public var kindDisplayString: String {
        if isSymlink { return "Dowiązanie" }
        if isDirectory {
            return fileExtension.lowercased() == "app" ? "Aplikacja" : "Folder"
        }
        let category: String
        switch kindCategory {
        case .folder: category = "Folder"
        case .code: category = "Kod źródłowy"
        case .document: category = "Dokument"
        case .image: category = "Obraz"
        case .audio: category = "Dźwięk"
        case .video: category = "Wideo"
        case .archive: category = "Archiwum"
        case .executable: category = "Plik wykonywalny"
        case .other: category = "Plik"
        }
        return fileExtension.isEmpty ? category : "\(category) \(fileExtension.uppercased())"
    }

    public static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.path == rhs.path &&
        lhs.modificationDate == rhs.modificationDate &&
        lhs.size == rhs.size &&
        lhs.gitStatus == rhs.gitStatus &&
        lhs.grepMatch == rhs.grepMatch &&
        lhs.tags == rhs.tags &&
        lhs.treeDepth == rhs.treeDepth
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

/// Fast thread-safe icon & QuickLook thumbnail cache (`QLThumbnailGenerator`) for native macOS previews
@MainActor
public final class FileIconCache: ObservableObject {
    public static let shared = FileIconCache()
    @Published private var cache: [String: NSImage] = [:]
    private var genericIcons: [String: NSImage] = [:]
    private var pendingIcons: Set<String> = []
    private let iconQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.betterfinder.file-icons"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    @Published public private(set) var thumbnails: [String: NSImage] = [:]
    private var inFlightThumbnails: Set<String> = []

    private init() {}

    public func icon(for item: FileItem, preferThumbnail: Bool = true) -> NSImage {
        if preferThumbnail, let thumb = thumbnails[item.path] {
            return thumb
        }
        if preferThumbnail && item.supportsRichThumbnail {
            requestThumbnailIfNeeded(for: item)
        }
        let cacheKey = item.isDirectory || item.fileExtension.isEmpty
            ? item.path : "ext:\(item.fileExtension.lowercased()):\(item.isSymlink)"
        if let cached = cache[cacheKey] { return cached }
        if !pendingIcons.contains(cacheKey), pendingIcons.count < 256 {
            pendingIcons.insert(cacheKey)
            let path = item.path
            iconQueue.addOperation { [weak self] in
                let image = NSWorkspace.shared.icon(forFile: path)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingIcons.remove(cacheKey)
                    if self.cache.count > 2500 { self.cache.removeAll(keepingCapacity: true) }
                    self.cache[cacheKey] = image
                }
            }
        }
        // Type icons don't inspect the file or wait for its metadata provider.
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        if let generic = genericIcons[type.identifier] { return generic }
        let generic = NSWorkspace.shared.icon(for: type)
        genericIcons[type.identifier] = generic
        return generic
    }

    public func requestThumbnailIfNeeded(for item: FileItem) {
        let path = item.path
        guard thumbnails[path] == nil, !inFlightThumbnails.contains(path) else { return }
        inFlightThumbnails.insert(path)

        let req = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 160, height: 160),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let nsImg = rep?.nsImage else {
                Task { @MainActor in
                    self?.inFlightThumbnails.remove(path)
                }
                return
            }
            Task { @MainActor in
                guard let self = self else { return }
                if self.thumbnails.count > 800 {
                    self.thumbnails.removeAll(keepingCapacity: true)
                }
                self.thumbnails[path] = nsImg
                self.inFlightThumbnails.remove(path)
            }
        }
    }
}
