import SwiftUI
import AppKit

struct FileDragFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// SwiftUI's onDrag exports a single provider. An AppKit dragging session exports
/// one file URL per selected item, so Finder and our own panes receive the batch.
struct NativeFileDragSource: NSViewRepresentable {
    @ObservedObject var pane: PaneTabState
    let frames: [String: CGRect]
    let isActive: Bool
    let activate: () -> Void

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.frames = frames
        view.focusOnAttach = isActive
        if let last = view.lastFocusRequest, last != pane.focusFilePaneTrigger {
            view.window?.makeFirstResponder(view)
        }
        view.lastFocusRequest = pane.focusFilePaneTrigger
        view.itemsForDrag = { path in
            activate()
            guard let item = pane.displayedItems.first(where: { $0.path == path }) else { return [] }
            if !pane.selectedPaths.contains(path) { pane.select(item) }
            return pane.selectedItems
        }
    }
}

final class FileDragSourceView: NSView, NSDraggingSource {
    var frames: [String: CGRect] = [:]
    var itemsForDrag: ((String) -> [FileItem])?
    var focusOnAttach = false
    var lastFocusRequest: UInt64?
    private var monitor: Any?
    private var downPath: String?
    private var downPoint = NSPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusOnAttach, let window = self.window,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                self.downPath = self.bounds.contains(point)
                    ? self.frames.first(where: { $0.value.contains(point) })?.key : nil
                self.downPoint = point
                if self.downPath != nil { self.window?.makeFirstResponder(self) }
            case .leftMouseUp:
                self.downPath = nil
            case .leftMouseDragged:
                guard let path = self.downPath,
                      hypot(point.x - self.downPoint.x, point.y - self.downPoint.y) > 5 else { return event }
                self.downPath = nil
                let files = self.itemsForDrag?(path) ?? []
                guard !files.isEmpty else { return event }
                let items = files.map { file -> NSDraggingItem in
                    let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                    let image = FileIconCache.shared.icon(for: file, preferThumbnail: false)
                    item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 32, height: 32), contents: image)
                    return item
                }
                let session = self.beginDraggingSession(with: items, event: event, source: self)
                session.draggingFormation = .pile
                return nil
            default: break
            }
            return event
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Decode every provider before starting an operation, preserving one progress
/// owner and one conflict sheet for drops containing several files.
enum FileDropLoader {
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier("public.file-url") }
    }

    @MainActor static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, _ in
                    let url: URL?
                    if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = value as? URL { url = value }
                    else { url = nil }
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }
            if let url, !urls.contains(url) { urls.append(url) }
        }
        return urls
    }
}
