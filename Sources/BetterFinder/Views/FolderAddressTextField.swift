import AppKit
import SwiftUI

/// An ordinary native field gives path editing the platform's selection,
/// clipboard, horizontal scrolling and accessibility behavior. No global
/// first-responder action can select text in the other pane.
struct FolderAddressTextField: NSViewRepresentable {
    @Binding var text: String
    var isEditing: Bool
    var focusRequest: UInt64
    var mayFocus: () -> Bool
    var beginEditing: () -> Void
    var endEditing: () -> Void
    var changed: () -> Void
    var submit: () -> Void
    var cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.placeholderString = "Ścieżka folderu"
        field.setAccessibilityLabel("Ścieżka folderu")
        field.setAccessibilityIdentifier("folder.address")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        context.coordinator.lastRequest = isEditing ? focusRequest &- 1 : focusRequest
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if isEditing && coordinator.lastRequest != focusRequest {
            coordinator.lastRequest = focusRequest
            coordinator.scheduleFocus(field, request: focusRequest)
        } else if !isEditing && field.currentEditor() != nil {
            // Escape/newer navigation must relinquish only this field editor.
            // Defer delegate callbacks until after SwiftUI's update transaction.
            coordinator.scheduleBlur(field)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.alive = false
        coordinator.delivery &+= 1
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FolderAddressTextField
        var lastRequest: UInt64 = 0
        var delivery: UInt64 = 0
        var alive = true
        init(_ parent: FolderAddressTextField) { self.parent = parent }

        func scheduleFocus(_ field: NSTextField, request: UInt64) {
            delivery &+= 1
            let token = delivery
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.alive, self.delivery == token,
                      self.parent.isEditing, self.parent.mayFocus(), self.parent.focusRequest == request,
                      let window = field.window else { return }
                guard window.makeFirstResponder(field) else { return }
                field.currentEditor()?.selectAll(nil)
            }
        }

        func scheduleBlur(_ field: NSTextField) {
            delivery &+= 1
            let token = delivery
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.alive, self.delivery == token,
                      !self.parent.isEditing, let editor = field.currentEditor(),
                      field.window?.firstResponder === editor else { return }
                field.window?.makeFirstResponder(nil)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard alive, let field = notification.object as? NSTextField else { return }
            parent.beginEditing()
            // Selecting on first click mirrors an address bar. Subsequent clicks
            // in the already-focused editor place the caret normally.
            delivery &+= 1
            let token = delivery
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.alive, self.delivery == token, self.parent.mayFocus(),
                      let editor = field.currentEditor(), field.window?.firstResponder === editor else { return }
                editor.selectAll(nil)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard alive, let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.changed()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard alive else { return }
            parent.endEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard alive else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.submit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}
