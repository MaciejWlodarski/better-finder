import SwiftUI

struct RenameItemSheet: View {
    let item: FileItem
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var iconCache = FileIconCache.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @ViewState private var draft: String
    @ViewState private var errorMessage: String?

    init(item: FileItem, pane: PaneTabState) {
        self.item = item
        self.pane = pane
        self._draft = ViewState(wrappedValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: FileIconCache.shared.icon(for: item))
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Zmień nazwę").font(.headline)
                    Text(item.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("Nazwa", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(rename)
                .onChange(of: draft) { _, _ in errorMessage = nil }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zmień nazwę", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == item.name)
            }
        }
        .padding(24)
        .frame(width: 390)
        .onAppear { isNameFocused = true }
    }

    private func rename() {
        guard draft != item.name else { dismiss(); return }
        if let url = FileOperationsManager.shared.renameItem(item, to: draft) {
            pane.renamingItemPath = nil
            pane.refresh()
            pane.selectedPaths = [url.path]
            pane.selectionCursorPath = url.path
            dismiss()
        } else {
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? "Nie udało się zmienić nazwy."
        }
    }
}
