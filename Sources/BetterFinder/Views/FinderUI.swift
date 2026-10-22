import SwiftUI

/// Shared native desktop metrics. System fonts and semantic colors follow macOS settings.
enum FinderUI {
    static let sheetPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 6
    static let iconButtonSize: CGFloat = 28
    static let bodyFont: Font = .body
    static let detailFont: Font = .callout
    static let captionFont: Font = .caption
    static let titleFont: Font = .headline
}

/// The status bar must describe the same projection that commands can act on.
struct FinderSelectionSummary: Equatable {
    let totalCount: Int
    let selectedCount: Int
    let isSearching: Bool
    let isAnalysis: Bool

    @MainActor init(pane: PaneTabState) {
        totalCount = pane.selectableItems.count
        selectedCount = pane.selectedItems.count
        isSearching = pane.isSearching
        isAnalysis = pane.viewMode == .wiztree && pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var countDescription: String {
        if isSearching { return "Wyszukiwanie…" }
        if selectedCount > 0 { return "Zaznaczono \(selectedCount.formatted()) z \(totalCount.formatted())" }
        if isAnalysis { return "Elementy analizy: \(totalCount.formatted())" }
        return "Elementy: \(totalCount.formatted())"
    }
}
