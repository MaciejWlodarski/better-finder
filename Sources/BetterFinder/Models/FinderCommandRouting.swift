import AppKit

/// Commands can be evaluated without a live application or key window.
/// Read the optional NSApp global; never create NSApplication as a side effect
/// of checking whether a command is enabled.
@MainActor
enum FinderCommandRouting {
    static var isEditingText: Bool {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    static var canUseFileCommands: Bool {
        guard let window = NSApp?.keyWindow else { return false }
        return !isEditingText && !(window is NSPanel) &&
            window.attachedSheet == nil && window.sheetParent == nil
    }

    static func routeTextAction(_ action: Selector) -> Bool {
        guard let application = NSApp,
              let responder = application.keyWindow?.firstResponder,
              responder is NSTextView || responder is NSTextField else { return false }
        // Preserve consumption semantics: a text editor owns the command even
        // when its responder does not implement that particular action.
        _ = application.sendAction(action, to: responder, from: nil)
        return true
    }
}
