import SwiftUI
import AppKit
import CryptoKit
import Darwin

public struct WizTreeNode: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let fileCount: Int
    public let kindCategory: FileKindCategory
    public let modificationDate: Date
    public var children: [WizTreeNode]

    public func toFileItem() -> FileItem {
        FileItem(
            url: url,
            name: name,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            fileExtension: url.pathExtension.lowercased(),
            isDirectory: isDirectory,
            isHidden: name.hasPrefix("."),
            size: size,
            modificationDate: modificationDate,
            kindCategory: kindCategory
        )
    }
}

public struct DuplicateFileGroup: Identifiable, Sendable {
    public let id: String
    public let sha256: String
    public let fileSize: Int64
    public let files: [FileItem]
    let snapshots: [String: DuplicateFileSnapshot]

    public var wastedBytes: Int64 {
        fileSize * Int64(max(0, files.count - 1))
    }
}

// A generation is cancelled on every root/mode change, refresh and disappearance.
// The same predicate protects all publication paths, including empty results.
final class AnalysisRequestToken: @unchecked Sendable {
    let id = UUID()
    let rootPath: String
    private let lock = NSLock()
    private var cancelled = false
    init(rootPath: String) { self.rootPath = rootPath }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func canPublish(active: AnalysisRequestToken?, rootPath: String) -> Bool {
        active === self && self.rootPath == rootPath && !isCancelled
    }
}

struct DuplicateFileSnapshot: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw DuplicateSafetyError.changed }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

enum DuplicateSafetyError: LocalizedError {
    case changed, unreadable, cancelled
    var errorDescription: String? {
        switch self {
        case .changed: return "Plik lub zachowywany oryginał zmienił się. Nic więcej nie usunięto; wykonaj nowy skan."
        case .unreadable: return "Nie można bezpiecznie odczytać pliku. Wykonaj nowy skan."
        case .cancelled: return "Skanowanie anulowano."
        }
    }
}

/// Full streaming SHA-256, with no size ceiling and no symlink/special-file reads.
/// Snapshot checks detect replacement and writes during or after hashing. A filesystem
/// can still change between the final check and a path-based Trash operation; this is
/// not a transactional filesystem lock and does not claim to prevent hostile races.
enum DuplicateFileSafety {
    static func snapshot(at url: URL) throws -> DuplicateFileSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw DuplicateSafetyError.unreadable }
        return try DuplicateFileSnapshot(info)
    }

    static func hash(at url: URL, isCancelled: () -> Bool = { false }) throws -> (hash: String, snapshot: DuplicateFileSnapshot) {
        let before = try snapshot(at: url)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DuplicateSafetyError.unreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, try DuplicateFileSnapshot(info) == before else { throw DuplicateSafetyError.changed }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            if isCancelled() { throw DuplicateSafetyError.cancelled }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw DuplicateSafetyError.unreadable
            }
            if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count)))
        }
        guard fstat(fd, &info) == 0, try DuplicateFileSnapshot(info) == before,
              try snapshot(at: url) == before else { throw DuplicateSafetyError.changed }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }

    static func validate(_ group: DuplicateFileGroup, isCancelled: () -> Bool = { false }) throws {
        guard group.files.count > 1, group.snapshots.count == group.files.count else { throw DuplicateSafetyError.changed }
        var identities = Set<String>()
        for item in group.files {
            let current = try hash(at: item.url, isCancelled: isCancelled)
            guard current.hash == group.sha256, current.snapshot == group.snapshots[item.path],
                  identities.insert("\(current.snapshot.device):\(current.snapshot.inode)").inserted else {
                throw DuplicateSafetyError.changed
            }
        }
    }

    // Called immediately before each candidate enters the Trash, not just once per scan.
    static func validateBeforeTrash(_ item: FileItem, in group: DuplicateFileGroup) throws {
        guard let keeper = group.files.first, keeper.path != item.path,
              let kept = group.snapshots[keeper.path], let candidate = group.snapshots[item.path],
              try snapshot(at: keeper.url) == kept,
              try snapshot(at: item.url) == candidate else { throw DuplicateSafetyError.changed }
    }

    static func groups(from entries: [IndexedFileEntry], token: AnalysisRequestToken) -> (groups: [DuplicateFileGroup], failed: Int) {
        var bySize: [Int64: [IndexedFileEntry]] = [:]
        for entry in entries where !entry.isDirectory && !entry.isSymlink {
            bySize[entry.size, default: []].append(entry)
        }
        var groups: [DuplicateFileGroup] = []
        var failed = 0
        for sameSize in bySize.values where sameSize.count > 1 {
            var byHash: [String: [(FileItem, DuplicateFileSnapshot)]] = [:]
            var seenIdentities = Set<String>()
            for entry in sameSize.sorted(by: { $0.fullPath < $1.fullPath }) {
                if token.isCancelled { return ([], failed) }
                do {
                    let item = entry.toFileItem(loadTags: false)
                    let result = try hash(at: item.url, isCancelled: { token.isCancelled })
                    guard result.snapshot.size == entry.size else { failed += 1; continue }
                    // Hard links are one physical file, not reclaimable duplicate storage.
                    guard seenIdentities.insert("\(result.snapshot.device):\(result.snapshot.inode)").inserted else { continue }
                    byHash[result.hash, default: []].append((item, result.snapshot))
                } catch { failed += 1 }
            }
            for (hash, pairs) in byHash where pairs.count > 1 {
                groups.append(DuplicateFileGroup(id: hash, sha256: hash, fileSize: pairs[0].1.size,
                    files: pairs.map { $0.0 }, snapshots: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.path, $0.1) })))
            }
        }
        return (groups.sorted { $0.wastedBytes > $1.wastedBytes }, failed)
    }
}

public struct TreemapPlacedBlock: Identifiable {
    public let id: String
    public let node: WizTreeNode
    public let rect: CGRect
    public let isGroupContainer: Bool
    public let parentFolderName: String?
}

/// Squarified Treemap Algorithm (Bruls, Huizing, van Wijk) for WizTree-style rectangular visualization
public enum SquarifiedTreemapLayout {
    public static func computeHierarchicalBlocks(
        nodes: [WizTreeNode],
        in bounds: CGRect,
        maxBlocks: Int = 65
    ) -> [TreemapPlacedBlock] {
        guard bounds.width > 16, bounds.height > 16, !nodes.isEmpty else { return [] }
        let positiveNodes = Array(nodes.filter { $0.size > 0 }.prefix(maxBlocks))
        guard !positiveNodes.isEmpty else { return [] }

        let topRects = squarify(nodes: positiveNodes, in: bounds.insetBy(dx: 2, dy: 2))
        var result: [TreemapPlacedBlock] = []

        for (node, rect) in topRects {
            guard rect.width >= 4 && rect.height >= 4 else { continue }
            let insetRect = rect.insetBy(dx: 1.5, dy: 1.5)
            guard insetRect.width >= 3 && insetRect.height >= 3 else { continue }

            if node.isDirectory && !node.children.isEmpty && insetRect.width > 46 && insetRect.height > 38 {
                result.append(TreemapPlacedBlock(
                    id: "group:\(node.path)",
                    node: node,
                    rect: insetRect,
                    isGroupContainer: true,
                    parentFolderName: nil
                ))
                let headerHeight: CGFloat = min(18, max(14, insetRect.height * 0.16))
                let innerRect = CGRect(
                    x: insetRect.minX + 3,
                    y: insetRect.minY + headerHeight + 2,
                    width: insetRect.width - 6,
                    height: insetRect.height - headerHeight - 5
                )
                if innerRect.width > 12 && innerRect.height > 12 {
                    let subChildren = Array(node.children.filter { $0.size > 0 }.prefix(28))
                    let childRects = squarify(nodes: subChildren, in: innerRect)
                    for (child, cRect) in childRects where cRect.width >= 4 && cRect.height >= 4 {
                        result.append(TreemapPlacedBlock(
                            id: child.path,
                            node: child,
                            rect: cRect.insetBy(dx: 1, dy: 1),
                            isGroupContainer: false,
                            parentFolderName: node.name
                        ))
                    }
                }
            } else {
                result.append(TreemapPlacedBlock(
                    id: node.path,
                    node: node,
                    rect: insetRect,
                    isGroupContainer: false,
                    parentFolderName: nil
                ))
            }
        }
        return result
    }

    private static func squarify(nodes: [WizTreeNode], in rect: CGRect) -> [(WizTreeNode, CGRect)] {
        let totalSize = nodes.reduce(0.0) { $0 + Double(max(1, $1.size)) }
        guard totalSize > 0, rect.width > 1, rect.height > 1 else { return [] }

        let totalArea = Double(rect.width * rect.height)
        let scaledAreas = nodes.map { Double(max(1, $0.size)) / totalSize * totalArea }

        var output: [(WizTreeNode, CGRect)] = []
        output.reserveCapacity(nodes.count)

        var currentRect = rect
        var rowIndices: [Int] = []
        var rowAreaSum: Double = 0

        for idx in nodes.indices {
            let area = scaledAreas[idx]
            if rowIndices.isEmpty {
                rowIndices.append(idx)
                rowAreaSum = area
                continue
            }

            let shortSide = Double(min(currentRect.width, currentRect.height))
            let currentWorst = worstAspectRatio(
                rowIndices: rowIndices,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum,
                sideLength: shortSide
            )
            var candidateRow = rowIndices
            candidateRow.append(idx)
            let nextWorst = worstAspectRatio(
                rowIndices: candidateRow,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum + area,
                sideLength: shortSide
            )

            if nextWorst <= currentWorst {
                rowIndices.append(idx)
                rowAreaSum += area
            } else {
                currentRect = layoutRow(
                    rowIndices: rowIndices,
                    nodes: nodes,
                    areas: scaledAreas,
                    rowAreaSum: rowAreaSum,
                    in: currentRect,
                    output: &output
                )
                rowIndices = [idx]
                rowAreaSum = area
            }
        }

        if !rowIndices.isEmpty {
            _ = layoutRow(
                rowIndices: rowIndices,
                nodes: nodes,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum,
                in: currentRect,
                output: &output
            )
        }

        return output
    }

    private static func worstAspectRatio(
        rowIndices: [Int],
        areas: [Double],
        rowAreaSum: Double,
        sideLength: Double
    ) -> Double {
        guard sideLength > 0, rowAreaSum > 0 else { return .greatestFiniteMagnitude }
        var minArea = Double.greatestFiniteMagnitude
        var maxArea = 0.0
        for i in rowIndices {
            let a = areas[i]
            if a < minArea { minArea = a }
            if a > maxArea { maxArea = a }
        }
        guard minArea > 0 else { return .greatestFiniteMagnitude }
        let s2 = rowAreaSum * rowAreaSum
        let w2 = sideLength * sideLength
        return max((w2 * maxArea) / s2, s2 / (w2 * minArea))
    }

    private static func layoutRow(
        rowIndices: [Int],
        nodes: [WizTreeNode],
        areas: [Double],
        rowAreaSum: Double,
        in rect: CGRect,
        output: inout [(WizTreeNode, CGRect)]
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0, rowAreaSum > 0 else { return rect }
        let horizontalSplit = rect.width >= rect.height

        if horizontalSplit {
            // Stack items vertically in a strip of width `stripWidth` on the left of `rect`
            let stripWidth = CGFloat(min(Double(rect.width), rowAreaSum / Double(rect.height)))
            var yCursor = rect.minY
            for i in rowIndices {
                let itemHeight = stripWidth > 0 ? CGFloat(areas[i]) / stripWidth : 0
                let itemRect = CGRect(x: rect.minX, y: yCursor, width: stripWidth, height: max(0, itemHeight))
                output.append((nodes[i], itemRect))
                yCursor += itemHeight
            }
            return CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            // Stack items horizontally in a strip of height `stripHeight` on the top of `rect`
            let stripHeight = CGFloat(min(Double(rect.height), rowAreaSum / Double(rect.width)))
            var xCursor = rect.minX
            for i in rowIndices {
                let itemWidth = stripHeight > 0 ? CGFloat(areas[i]) / stripHeight : 0
                let itemRect = CGRect(x: xCursor, y: rect.minY, width: max(0, itemWidth), height: stripHeight)
                output.append((nodes[i], itemRect))
                xCursor += itemWidth
            }
            return CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }
}

public enum WizTreeSubMode: String, CaseIterable, Identifiable {
    case treemap = "WizTree Treemap & Drzewo"
    case largestFiles = "Największe pliki"
    case duplicates = "Duplikaty (SHA-256)"

    public var id: String { rawValue }
}

/// Shared production projection builder: keyboard selection uses displayed rows
/// and rendered tiles, never an arbitrary last-clicked singleton or hidden subtree.
enum WizTreeSelectionProjection {
    static func items(mode: WizTreeSubMode, branches: [WizTreeNode], largestFiles: [FileItem],
                      duplicateGroups: [DuplicateFileGroup], visibleBlocks: [TreemapPlacedBlock] = []) -> [FileItem] {
        let candidates: [FileItem]
        switch mode {
        case .treemap: candidates = branches.map { $0.toFileItem() } + visibleBlocks.map { $0.node.toFileItem() }
        case .largestFiles: candidates = largestFiles
        case .duplicates: candidates = duplicateGroups.flatMap(\.files)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

public struct WizTreeAnalyzerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var iconCache = FileIconCache.shared

    @ViewState private var subMode: WizTreeSubMode = .treemap
    @ViewState private var isScanning: Bool = false
    @ViewState private var scanDurationMs: Double = 0
    @ViewState private var totalScannedBytes: Int64 = 0
    @ViewState private var totalScannedFiles: Int = 0
    @ViewState private var topBranches: [WizTreeNode] = []
    @ViewState private var largestFiles: [FileItem] = []
    @ViewState private var categoryStats: [(FileKindCategory, Int64, Int)] = []
    @ViewState private var duplicateGroups: [DuplicateFileGroup] = []
    @ViewState private var scanToken: AnalysisRequestToken?
    @ViewState private var scanTask: Task<Void, Never>?
    @ViewState private var scanIsComplete = false
    @ViewState private var scanDiagnostic: String?
    @ViewState private var duplicateActionError: String?
    @ViewState private var isValidatingDuplicates = false
    @ViewState private var hoveredBlock: TreemapPlacedBlock? = nil

    public init(appState: AppState, pane: PaneTabState) {
        self.appState = appState
        self.pane = pane
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top WizTree Control & Telemetry Bar
            analyzerHeaderBar

            Divider()

            // Category Distribution Strip
            if !categoryStats.isEmpty {
                categoryBreakdownStrip
                Divider()
            }

            if let diagnostic = scanDiagnostic {
                Text(diagnostic).font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.vertical, 5)
            }
            if let error = duplicateActionError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 5)
            }
            Text("Zakres: \(pane.showHiddenFiles ? "z ukrytymi plikami" : "bez ukrytych plików"), bez śledzenia dowiązań. Limit: 60 000 wpisów.")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14)
            // Main Content
            if isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Skanowanie i weryfikacja drzewa (\(pane.currentURL.lastPathComponent))...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch subMode {
                case .treemap:
                    wizTreeSplitWorkspace
                case .largestFiles:
                    largestFilesTableView
                case .duplicates:
                    duplicatesScannerView
                }
            }
        }
        .onAppear {
            runActiveScan(for: pane.currentURL)
        }
        .onChange(of: pane.currentURL.path) { _, _ in runActiveScan(for: pane.currentURL) }
        .onChange(of: pane.showHiddenFiles) { _, _ in runActiveScan(for: pane.currentURL) }
        .onChange(of: pane.directoryRevision) { _, _ in runActiveScan(for: pane.currentURL) }
        .onDisappear {
            scanToken?.cancel()
            scanTask?.cancel()
            pane.clearAnalysisSelection()
        }
    }

    // MARK: - Top Control Bar

    private var analyzerHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text("WizTree macOS")
                    .font(.system(size: 13, weight: .bold))
            }

            Picker("", selection: $subMode) {
                ForEach(WizTreeSubMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)
            .onChange(of: subMode) { _, _ in
                runActiveScan(for: pane.currentURL)
            }

            Spacer()

            HStack(spacing: 8) {
                Text("\(scanIsComplete ? "Łącznie" : "Co najmniej"): \(FormatHelpers.formatBytes(totalScannedBytes))")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                Text("· \(totalScannedFiles.formatted()) plików")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if scanDurationMs > 0 {
                    Text("· ⚡ \(FormatHelpers.formatLatency(scanDurationMs))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.05), in: Capsule())

            Button {
                runActiveScan(for: pane.currentURL)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Odśwież skan WizTree")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Category Legend & Proportional Bar

    private var categoryBreakdownStrip: some View {
        VStack(spacing: 6) {
            // Proportional Multi-Color Bar
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(categoryStats, id: \.0.rawValue) { cat, bytes, _ in
                        let frac = totalScannedBytes > 0 ? CGFloat(bytes) / CGFloat(totalScannedBytes) : 0
                        if frac > 0.005 {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(cat.treemapColor.gradient)
                                .frame(width: max(4, geo.size.width * frac))
                        }
                    }
                }
            }
            .frame(height: 7)

            // Legend Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(categoryStats.prefix(7), id: \.0.rawValue) { cat, bytes, count in
                        let pct = totalScannedBytes > 0 ? Double(bytes) * 100.0 / Double(totalScannedBytes) : 0
                        HStack(spacing: 5) {
                            Circle()
                                .fill(cat.treemapColor)
                                .frame(width: 8, height: 8)
                            Text(cat.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                            Text("\(FormatHelpers.formatBytes(bytes)) (\(String(format: "%.1f%%", pct)))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("[\(count)]")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Split Workspace: Ranked Tree Table + Interactive Squarified Treemap

    private var wizTreeSplitWorkspace: some View {
        VStack(spacing: 0) {
            // Upper Ranked Folder/File Breakdown Table
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(topBranches.enumerated()), id: \.element.id) { idx, node in
                        let pct = totalScannedBytes > 0 ? Double(node.size) / Double(totalScannedBytes) : 0
                        let isSelected = pane.selectedPaths.contains(node.path)

                        HStack(spacing: 10) {
                            Image(nsImage: iconCache.icon(for: node.toFileItem(), preferThumbnail: false))
                                .resizable()
                                .frame(width: 18, height: 18)

                            Text(node.name)
                                .font(.system(size: 12, weight: node.isDirectory ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .lineLimit(1)
                                .frame(width: 210, alignment: .leading)

                            // Visual Usage Bar (WizTree style)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.07))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(node.kindCategory.treemapColor.gradient)
                                        .frame(width: max(3, geo.size.width * CGFloat(pct)))
                                }
                            }
                            .frame(width: 150, height: 11)

                            Text(String(format: "%5.1f%%", pct * 100.0))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                                .frame(width: 56, alignment: .trailing)

                            Text(FormatHelpers.formatBytes(node.size))
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? .white : .primary)
                                .frame(width: 90, alignment: .trailing)

                            Text("\(node.fileCount) plików")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                                .frame(width: 85, alignment: .trailing)

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4.5)
                        .background(
                            isSelected
                            ? Color.accentColor
                            : (idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if node.isDirectory {
                                    pane.navigate(to: node.url)
                                } else {
                                    NSWorkspace.shared.open(node.url)
                                }
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                pane.setAnalysisSelection([node.toFileItem()], rootPath: pane.currentURL.path)
                            }
                        )
                    }
                }
            }
            .frame(height: 175)

            Divider()

            // Interactive Squarified Treemap Canvas
            VStack(spacing: 0) {
                // Live Hover / Selection HUD Bar
                treemapHudBar

                GeometryReader { geo in
                    let blocks = SquarifiedTreemapLayout.computeHierarchicalBlocks(
                        nodes: topBranches,
                        in: CGRect(origin: .zero, size: geo.size)
                    )
                    let generation = scanToken
                    ZStack(alignment: .topLeading) {
                        ForEach(blocks) { block in
                            treemapBlockView(block)
                        }
                    }
                    .onAppear { publishTreemapProjection(blocks, token: generation) }
                    .onChange(of: blocks.map(\.id)) { _, _ in
                        publishTreemapProjection(blocks, token: generation)
                    }
                }
                .padding(6)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
            }
        }
    }

    private var treemapHudBar: some View {
        HStack(spacing: 8) {
            if let hov = hoveredBlock {
                Circle()
                    .fill(hov.node.kindCategory.treemapColor)
                    .frame(width: 9, height: 9)
                Text(hov.node.name)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                if let parent = hov.parentFolderName {
                    Text("w \(parent)/")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("· \(FormatHelpers.formatBytes(hov.node.size))")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                if totalScannedBytes > 0 {
                    let pct = Double(hov.node.size) * 100.0 / Double(totalScannedBytes)
                    Text("(\(String(format: "%.1f%%", pct)))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text("Najedź na kafelek Treemap, kliknij aby zbadać w Inspektorze, kliknij dwukrotnie folder aby wejść głębiej")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func treemapBlockView(_ block: TreemapPlacedBlock) -> some View {
        let isHovered = (hoveredBlock?.id == block.id)
        let isSelected = pane.selectedPaths.contains(block.node.path)
        let baseColor = block.node.kindCategory.treemapColor

        if block.isGroupContainer {
            // Folder Group Container Frame (WizTree style)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.white : baseColor.opacity(0.55),
                        lineWidth: isSelected ? 2 : 1
                    )
                if block.rect.width > 55 {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(baseColor)
                        Text("\(block.node.name) · \(FormatHelpers.formatBytes(block.node.size))")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 2)
                }
            }
            .frame(width: block.rect.width, height: block.rect.height)
            .offset(x: block.rect.minX, y: block.rect.minY)
            .onTapGesture(count: 2) {
                pane.navigate(to: block.node.url)
            }
        } else {
            // Individual File or Leaf Folder Tile
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        LinearGradient(
                            colors: [
                                baseColor.opacity(isHovered ? 0.92 : 0.78),
                                baseColor.opacity(isHovered ? 0.72 : 0.52)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected || isHovered ? Color.white : Color.white.opacity(0.22),
                        lineWidth: isSelected ? 2.0 : (isHovered ? 1.5 : 0.6)
                    )

                if block.rect.width > 42 && block.rect.height > 24 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.node.name)
                            .font(.system(size: block.rect.width > 90 ? 11 : 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)

                        if block.rect.height > 36 {
                            Text(FormatHelpers.formatBytes(block.node.size))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .padding(5)
                }
            }
            .frame(width: block.rect.width, height: block.rect.height)
            .offset(x: block.rect.minX, y: block.rect.minY)
            .onHover { hovering in
                if hovering {
                    hoveredBlock = block
                } else if hoveredBlock?.id == block.id {
                    hoveredBlock = nil
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if block.node.isDirectory {
                        pane.navigate(to: block.node.url)
                    } else {
                        NSWorkspace.shared.open(block.node.url)
                    }
                }
            )
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    pane.setAnalysisSelection([block.node.toFileItem()], rootPath: pane.currentURL.path)
                }
            )
            .contextMenu {
                if block.node.isDirectory {
                    Button {
                        pane.navigate(to: block.node.url)
                    } label: {
                        Label("Wejdź do tego folderu w WizTree", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                Button {
                    pane.viewMode = .list
                    pane.navigate(to: block.node.isDirectory ? block.node.url : block.node.url.deletingLastPathComponent())
                    pane.selectedPaths = [block.node.path]
                } label: {
                    Label("Pokaż na liście plików", systemImage: "list.bullet")
                }
                Button {
                    QuickLookCoordinator.shared.preview(urls: [block.node.url])
                } label: {
                    Label("Quick Look (Spacja)", systemImage: "eye")
                }
                Button {
                    FileOperationsManager.shared.openInTerminal(at: block.node.url)
                } label: {
                    Label("Otwórz w Terminalu", systemImage: "terminal")
                }
                Divider()
                Button(role: .destructive) {
                    trashAnalyzedItem(block.node.toFileItem())
                } label: {
                    Label("Przenieś do Kosza", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Largest Files Table View

    private var largestFilesTableView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(largestFiles.enumerated()), id: \.element.id) { idx, item in
                    let pct = totalScannedBytes > 0 ? Double(item.size) / Double(totalScannedBytes) : 0
                    HStack(spacing: 10) {
                        Text("#\(idx + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)

                        Image(nsImage: FileIconCache.shared.icon(for: item))
                            .resizable()
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(String(format: "%.1f%%", pct * 100.0))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(FormatHelpers.formatBytes(item.size))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .frame(width: 95, alignment: .trailing)

                        Button(role: .destructive) {
                            trashAnalyzedItem(item)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Przenieś do Kosza")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(pane.selectedPaths.contains(item.path) ? Color.accentColor.opacity(0.18) : (idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025)))
                    .contentShape(Rectangle())
                    .onTapGesture { pane.setAnalysisSelection([item], rootPath: pane.currentURL.path) }
                }
            }
        }
    }

    // MARK: - Duplicate Files View (SHA-256)

    private var duplicatesScannerView: some View {
        VStack(spacing: 0) {
            if duplicateGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: scanIsComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(scanIsComplete ? Color.green : Color.orange)
                    Text(scanIsComplete ? "Nie znaleziono duplikatów w przeskanowanym zakresie" : "Nie znaleziono duplikatów w częściowo sprawdzonym zakresie")
                        .font(.system(size: 13, weight: .semibold))
                    Text("SHA-256 pełnej treści, także plików pustych i dużych. Dowiązania symboliczne nie są śledzone. Ukryte pliki zależą od ustawienia widoku.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let totalWasted = duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
                HStack {
                    Text("Znaleziono \(duplicateGroups.count) grup duplikatów · Logiczny rozmiar nadmiarowych kopii: \(FormatHelpers.formatBytes(totalWasted))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Usuń nadmiarowe kopie do Kosza (zachowaj po 1 oryginale)") {
                        trashDuplicates(duplicateGroups)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isValidatingDuplicates)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))

                Text("To suma rozmiarów logicznych, nie gwarantowane odzyskane miejsce. Dowiązania twarde, klony APFS i kompresja mogą współdzielić dane.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 4)
                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(duplicateGroups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(group.files.count)× kopie · \(FormatHelpers.formatBytes(group.fileSize)) każdy")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("SHA-256: \(group.sha256.prefix(16))...")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Nadmiarowe dane logiczne: \(FormatHelpers.formatBytes(group.wastedBytes))")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                                ForEach(group.files) { file in
                                    HStack {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.system(size: 11.5, design: .monospaced))
                                        Spacer()
                                        Button(file.path == group.files.first?.path ? "Zachowywany oryginał" : "Kosz", role: .destructive) {
                                            trashDuplicates([group], onlyPath: file.path)
                                        }
                                        .disabled(file.path == group.files.first?.path || isValidatingDuplicates)
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                    .background(pane.selectedPaths.contains(file.path) ? Color.accentColor.opacity(0.18) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { pane.setAnalysisSelection([file], rootPath: pane.currentURL.path) }
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Generation-bound, bounded scans

    private func runActiveScan(for rootURL: URL) {
        scanToken?.cancel()
        scanTask?.cancel()
        let token = AnalysisRequestToken(rootPath: rootURL.path)
        scanToken = token
        isScanning = true
        scanIsComplete = false
        scanDiagnostic = nil
        topBranches = []
        largestFiles = []
        duplicateGroups = []
        categoryStats = []
        totalScannedBytes = 0
        totalScannedFiles = 0
        scanDurationMs = 0
        hoveredBlock = nil
        pane.beginAnalysisProjection(rootPath: rootURL.path, generation: token.id)
        let showHidden = pane.showHiddenFiles
        let mode = subMode
        scanTask = Task.detached(priority: .userInitiated) {
            let started = DispatchTime.now().uptimeNanoseconds
            let scan = BulkCrawler.crawlTreeResult(roots: [rootURL.path], skipHeavyDevDirs: false,
                maxEntries: 60_000, includeHidden: showHidden, isCancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            var groups: [DuplicateFileGroup] = []
            var failedHashes = 0
            if mode == .duplicates {
                let result = DuplicateFileSafety.groups(from: scan.entries, token: token)
                groups = result.groups
                failedHashes = result.failed
            }
            let files = scan.entries.filter { !$0.isDirectory && !$0.isSymlink }.map { $0.toFileItem(loadTags: false) }
            var categoryMap: [FileKindCategory: (Int64, Int)] = [:]
            for item in files {
                let previous = categoryMap[item.kindCategory] ?? (0, 0)
                categoryMap[item.kindCategory] = (previous.0 + item.size, previous.1 + 1)
            }
            let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
            var filesByBranch: [String: [FileItem]] = [:]
            for item in files {
                let relative = item.path.dropFirst(rootPrefix.count)
                let first = String(relative.split(separator: "/", maxSplits: 1).first ?? "")
                filesByBranch[first, default: []].append(item)
            }
            var branches: [WizTreeNode] = []
            for entry in scan.entries where entry.parentPath == rootURL.path && !entry.isSymlink {
                let branchFiles = filesByBranch[entry.name] ?? []
                let item = entry.toFileItem(loadTags: false)
                let children = branchFiles.sorted { $0.size > $1.size }.prefix(32).map { leaf in
                    WizTreeNode(name: leaf.name, path: leaf.path, url: leaf.url, isDirectory: false,
                        size: leaf.size, fileCount: 1, kindCategory: leaf.kindCategory,
                        modificationDate: leaf.modificationDate, children: [])
                }
                branches.append(WizTreeNode(name: entry.name, path: entry.fullPath, url: item.url,
                    isDirectory: entry.isDirectory, size: entry.isDirectory ? branchFiles.reduce(0) { $0 + $1.size } : item.size,
                    fileCount: entry.isDirectory ? branchFiles.count : 1, kindCategory: item.kindCategory,
                    modificationDate: item.modificationDate, children: entry.isDirectory ? children : []))
            }
            let complete = scan.isComplete && failedHashes == 0
            var messages: [String] = []
            if scan.reachedEntryLimit { messages.append("Wyniki częściowe: osiągnięto limit 60 000 wpisów.") }
            if scan.skippedDirectoryCount > 0 { messages.append("Pominięte katalogi: \(scan.skippedDirectoryCount).") }
            if scan.unreadableDirectoryCount > 0 { messages.append("Nieodczytane katalogi: \(scan.unreadableDirectoryCount).") }
            if failedHashes > 0 { messages.append("Pliki zmienione lub nieodczytane: \(failedHashes).") }
            if !complete && messages.isEmpty { messages.append("Skan niepełny; suma jest dolnym oszacowaniem.") }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            await MainActor.run { [branches, groups, categoryMap, messages] in
                guard token.canPublish(active: self.scanToken, rootPath: self.pane.currentURL.path) else { return }
                self.topBranches = branches.sorted { $0.size > $1.size }
                self.largestFiles = Array(files.sorted { $0.size > $1.size }.prefix(150))
                self.duplicateGroups = groups
                self.categoryStats = categoryMap.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }
                self.totalScannedBytes = files.reduce(0) { $0 + $1.size }
                self.totalScannedFiles = files.count
                self.scanDurationMs = elapsed
                self.scanIsComplete = complete
                self.scanDiagnostic = messages.isEmpty ? nil : messages.joined(separator: " ")
                self.isScanning = false
                // Publish the entire ordered visible projection independently of selection.
                let visible = WizTreeSelectionProjection.items(mode: mode, branches: self.topBranches,
                    largestFiles: self.largestFiles, duplicateGroups: self.duplicateGroups)
                self.pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
            }
        }
    }

    private func publishTreemapProjection(_ blocks: [TreemapPlacedBlock], token: AnalysisRequestToken?) {
        guard let token, token.canPublish(active: scanToken, rootPath: pane.currentURL.path),
              !isScanning, subMode == .treemap else { return }
        // Ranked rows are visible in the scrollable list. Only rendered tiles, not
        // children hidden by geometry/max-block limits, join the keyboard projection.
        let visible = WizTreeSelectionProjection.items(mode: .treemap, branches: topBranches,
            largestFiles: largestFiles, duplicateGroups: duplicateGroups, visibleBlocks: blocks)
        pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
    }

    private func trashAnalyzedItem(_ item: FileItem) {
        let root = pane.currentURL.path
        guard let token = scanToken, token.canPublish(active: scanToken, rootPath: root), !isScanning,
              item.path.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        FileOperationsManager.shared.moveToTrash([item])
        runActiveScan(for: pane.currentURL)
    }

    private func trashDuplicates(_ groups: [DuplicateFileGroup], onlyPath: String? = nil) {
        guard let token = scanToken, token.canPublish(active: scanToken, rootPath: pane.currentURL.path),
              !isScanning, !isValidatingDuplicates else { return }
        isValidatingDuplicates = true
        duplicateActionError = nil
        Task.detached(priority: .userInitiated) {
            do {
                // Validate all content before starting; final per-file checks run in the mutation path.
                for group in groups { try DuplicateFileSafety.validate(group, isCancelled: { token.isCancelled }) }
                await MainActor.run {
                    defer { self.isValidatingDuplicates = false }
                    guard token.canPublish(active: self.scanToken, rootPath: self.pane.currentURL.path) else { return }
                    for group in groups {
                        let candidates = group.files.dropFirst().filter { onlyPath == nil || $0.path == onlyPath }
                        FileOperationsManager.shared.moveToTrash(Array(candidates), validating: { item in
                            guard !token.isCancelled else { throw DuplicateSafetyError.cancelled }
                            try DuplicateFileSafety.validateBeforeTrash(item, in: group)
                        })
                    }
                    self.runActiveScan(for: self.pane.currentURL)
                }
            } catch {
                await MainActor.run {
                    self.isValidatingDuplicates = false
                    guard token.canPublish(active: self.scanToken, rootPath: self.pane.currentURL.path) else { return }
                    self.duplicateActionError = error.localizedDescription
                    self.runActiveScan(for: self.pane.currentURL)
                }
            }
        }
    }
}
