import SwiftUI
import AppKit

struct TerminalResizeHandle: View {
    let height: CGFloat
    let onIncrease: () -> Void
    let onDecrease: () -> Void
    let onReset: () -> Void
    @FocusState private var hasFocus: Bool
    @ViewState private var isHovered = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Capsule()
                .fill(hasFocus ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.8 : 0.45))
                .frame(width: 34, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: TerminalDrawerLayout.dividerHeight)
        .contentShape(Rectangle())
        .background(TerminalResizeCursor())
        .onHover { isHovered = $0 }
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { onIncrease(); return .handled }
        .onKeyPress(.downArrow) { onDecrease(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wysokość terminala")
        .accessibilityValue("\(Int(height)) punktów")
        .accessibilityHint("Przeciągnij w górę lub w dół. Po zaznaczeniu użyj strzałek, aby zmienić wysokość.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIncrease()
            case .decrement: onDecrease()
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Przywróć domyślną wysokość"), onReset)
        .contextMenu {
            Button("Powiększ terminal", action: onIncrease)
            Button("Zmniejsz terminal", action: onDecrease)
            Divider()
            Button("Domyślna wysokość", action: onReset)
        }
        .help("Przeciągnij, aby zmienić wysokość terminala. Strzałki ↑/↓ zmieniają wysokość po zaznaczeniu separatora.")
    }
}

/// Cursor rectangles follow geometry/lifetime without an unbalanced global push/pop.
private struct TerminalResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
    final class CursorView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
