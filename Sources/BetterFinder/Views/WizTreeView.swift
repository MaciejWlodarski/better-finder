import SwiftUI
import AppKit
import CryptoKit

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

    public var wastedBytes: Int64 {
        fileSize * Int64(max(0, files.count - 1))
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
    @ViewState private var hoveredBlock: TreemapPlacedBlock? = nil
    @ViewState private var selectedNodePath: String? = nil

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

            // Main Content
            if isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Skanowanie drzewa przez getattrlistbulk (\(pane.currentURL.lastPathComponent))...")
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
            runWizTreeScan(for: pane.currentURL)
        }
        .onChange(of: pane.currentURL.path) { _, _ in
            runWizTreeScan(for: pane.currentURL)
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
            .onChange(of: subMode) { _, newMode in
                if newMode == .duplicates && duplicateGroups.isEmpty {
                    runDuplicatesScan(for: pane.currentURL)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Text("Łącznie: \(FormatHelpers.formatBytes(totalScannedBytes))")
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
                runWizTreeScan(for: pane.currentURL)
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
                        let isSelected = (selectedNodePath == node.path)

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
                                selectedNodePath = node.path
                                pane.selectedPaths = [node.path]
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
                    ZStack(alignment: .topLeading) {
                        ForEach(blocks) { block in
                            treemapBlockView(block)
                        }
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
        let isSelected = (selectedNodePath == block.node.path)
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
                    selectedNodePath = block.node.path
                    pane.selectedPaths = [block.node.path]
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
                    FileOperationsManager.shared.moveToTrash([block.node.toFileItem()])
                    runWizTreeScan(for: pane.currentURL)
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
                            FileOperationsManager.shared.moveToTrash([item])
                            runWizTreeScan(for: pane.currentURL)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Przenieś do Kosza")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }
        }
    }

    // MARK: - Duplicate Files View (SHA-256)

    private var duplicatesScannerView: some View {
        VStack(spacing: 0) {
            if duplicateGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("Brak zduplikowanych plików w tym drzewie katalogów")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Skanowanie grupuje pliki o tym samym rozmiarze i weryfikuje pełny hash SHA-256")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let totalWasted = duplicateGroups.reduce(Int64(0)) { $0 + $1.wastedBytes }
                HStack {
                    Text("Znaleziono \(duplicateGroups.count) grup duplikatów · Możliwe do odzyskania: \(FormatHelpers.formatBytes(totalWasted))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Usuń nadmiarowe kopie do Kosza (zachowaj po 1 oryginale)") {
                        var redundant: [FileItem] = []
                        for group in duplicateGroups {
                            redundant.append(contentsOf: group.files.dropFirst())
                        }
                        FileOperationsManager.shared.moveToTrash(redundant)
                        runDuplicatesScan(for: pane.currentURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))

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
                                    Text("Zajmuje nadmiarowo: \(FormatHelpers.formatBytes(group.wastedBytes))")
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
                                        Button("Kosz", role: .destructive) {
                                            FileOperationsManager.shared.moveToTrash([file])
                                            runDuplicatesScan(for: pane.currentURL)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
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

    // MARK: - Fast Multi-Threaded `getattrlistbulk` WizTree Scanner

    private func runWizTreeScan(for rootURL: URL) {
        isScanning = true
        let rootPath = rootURL.path
        let showHidden = pane.showHiddenFiles

        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let topEntries = BulkCrawler.readDirectoryFast(at: rootPath, includeHidden: showHidden)

            var branches: [WizTreeNode] = []
            var allFiles: [FileItem] = []
            var catMap: [FileKindCategory: (Int64, Int)] = [:]
            var totalBytes: Int64 = 0
            var totalFiles = 0

            for entry in topEntries {
                if entry.isDirectory && !entry.isSymlink {
                    let subEntries = BulkCrawler.crawlTree(
                        roots: [entry.fullPath],
                        skipHeavyDevDirs: false,
                        maxEntries: 60_000
                    )
                    var folderBytes: Int64 = 0
                    var folderFiles = 0
                    var childLeafs: [WizTreeNode] = []

                    for sub in subEntries where !sub.isDirectory {
                        folderBytes += sub.size
                        folderFiles += 1
                        let cat = FileKindCategory.detect(extension: sub.ext, isDirectory: false)
                        let prev = catMap[cat] ?? (0, 0)
                        catMap[cat] = (prev.0 + sub.size, prev.1 + 1)

                        let fi = sub.toFileItem()
                        allFiles.append(fi)
                        childLeafs.append(WizTreeNode(
                            name: sub.name,
                            path: sub.fullPath,
                            url: fi.url,
                            isDirectory: false,
                            size: sub.size,
                            fileCount: 1,
                            kindCategory: cat,
                            modificationDate: fi.modificationDate,
                            children: []
                        ))
                    }
                    childLeafs.sort { $0.size > $1.size }
                    totalBytes += folderBytes
                    totalFiles += folderFiles

                    branches.append(WizTreeNode(
                        name: entry.name,
                        path: entry.fullPath,
                        url: URL(fileURLWithPath: entry.fullPath, isDirectory: true),
                        isDirectory: true,
                        size: folderBytes,
                        fileCount: max(1, folderFiles),
                        kindCategory: .folder,
                        modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.mtimeEpoch)),
                        children: Array(childLeafs.prefix(32))
                    ))
                } else {
                    let cat = FileKindCategory.detect(extension: entry.ext, isDirectory: false)
                    let prev = catMap[cat] ?? (0, 0)
                    catMap[cat] = (prev.0 + entry.size, prev.1 + 1)
                    totalBytes += entry.size
                    totalFiles += 1

                    let fi = entry.toFileItem()
                    allFiles.append(fi)
                    branches.append(WizTreeNode(
                        name: entry.name,
                        path: entry.fullPath,
                        url: fi.url,
                        isDirectory: false,
                        size: entry.size,
                        fileCount: 1,
                        kindCategory: cat,
                        modificationDate: fi.modificationDate,
                        children: []
                    ))
                }
            }

            branches.sort { $0.size > $1.size }
            allFiles.sort { $0.size > $1.size }
            let sortedCats = catMap.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }
            let topLargest = Array(allFiles.prefix(150))

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0

            Task { @MainActor in
                self.topBranches = branches
                self.largestFiles = topLargest
                self.categoryStats = sortedCats
                self.totalScannedBytes = totalBytes
                self.totalScannedFiles = totalFiles
                self.scanDurationMs = elapsedMs
                self.isScanning = false
            }
        }
    }

    private func runDuplicatesScan(for rootURL: URL) {
        let rootPath = rootURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = BulkCrawler.crawlTree(roots: [rootPath], skipHeavyDevDirs: true, maxEntries: 50_000)
            var bySize: [Int64: [IndexedFileEntry]] = [:]
            for e in entries where !e.isDirectory && !e.isSymlink && e.size > 0 && e.size <= 50 * 1024 * 1024 {
                bySize[e.size, default: []].append(e)
            }

            var groups: [DuplicateFileGroup] = []
            for (size, sameSizeList) in bySize where sameSizeList.count > 1 {
                var byHash: [String: [FileItem]] = [:]
                for entry in sameSizeList {
                    let url = URL(fileURLWithPath: entry.fullPath)
                    if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        byHash[hash, default: []].append(entry.toFileItem())
                    }
                }
                for (hash, files) in byHash where files.count > 1 {
                    groups.append(DuplicateFileGroup(id: hash, sha256: hash, fileSize: size, files: files))
                }
            }
            groups.sort { $0.wastedBytes > $1.wastedBytes }

            Task { @MainActor in
                self.duplicateGroups = groups
            }
        }
    }
}
