import SwiftUI
import AppKit

@main
struct NativePreview {
    @MainActor static func main() {
        guard let outputPath = ProcessInfo.processInfo.environment["BETTERFINDER_PREVIEW_OUTPUT"],
              outputPath.hasPrefix("/") else {
            require(false, "bootstrap output path missing or invalid"); return
        }
        let base = URL(fileURLWithPath: outputPath, isDirectory: true)
        markStage("native-entry")
        let fixture = base.appendingPathComponent("Pracownia", isDirectory: true)
        #if BETTERFINDER_TESTING
        // Keep each original isolation check; emit only fixed failure labels.
        // Never include actual home paths or environment values in diagnostics.
        let env = ProcessInfo.processInfo.environment
        require(env["BETTERFINDER_PREVIEW_CI"] == "1", "bootstrap CI mode missing")
        guard let home = env["CFFIXED_USER_HOME"] else {
            require(false, "bootstrap fixed home missing"); return
        }
        require(env["HOME"] == home, "bootstrap HOME differs from fixed home")
        markStage("check-ns-home")
        require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path,
                "bootstrap NSHomeDirectory isolation mismatch")
        markStage("check-file-manager-home")
        require(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path,
                "bootstrap FileManager home isolation mismatch")
        require(env["BETTERFINDER_TEST_ROOT"] == fixture.path, "bootstrap fixture root mismatch")
        #endif
        markStage("create-fixture-directories")
        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            for folder in ["Dokumenty", "Fotografie", "Projekty", "Archiwum"] {
                try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
        } catch { require(false, "bootstrap fixture directory creation failed"); return }
        markStage("write-fixture-files")
        do {
            for name in ["Notatki ze spotkania.md", "Plan projektu.txt", "README.md", "Szkice.svg", "Zestawienie.csv"] {
                var content = "BetterFinder preview\n"
                #if BETTERFINDER_TESTING
                // A valid static SVG exercises native thumbnails, not a parser-error fixture.
                // Keep non-CI preview fixture contents unchanged.
                if name == "Szkice.svg" {
                    content = ##"<svg xmlns="http://www.w3.org/2000/svg" width="160" height="120" viewBox="0 0 160 120"><rect width="160" height="120" fill="#eef2f7"/><rect x="20" y="20" width="70" height="80" rx="8" fill="#3975d5"/><circle cx="112" cy="60" r="24" fill="#edb94b"/></svg>"## + "\n"
                }
                #endif
                try Data(content.utf8).write(to: fixture.appendingPathComponent(name))
            }
        } catch { require(false, "bootstrap fixture file write failed"); return }
        markStage("configure-defaults")
        var previewDefaults: [String: Any] = [
            "bf.openTabPaths": [fixture.path], "bf.showInspector": false,
            "bf.showSidebar": true, "bf.isDualPane": false
        ]
        #if BETTERFINDER_TESTING
        // This scenario tests keyboard interaction in a freshly loaded fixture,
        // not session restoration. Legacy tab paths deliberately restore PAUSED
        // panes; the test root already supplies the fresh fixture startup URL.
        previewDefaults.removeValue(forKey: "bf.openTabPaths")
        previewDefaults["bf.restoreSession"] = false
        #endif
        UserDefaults.standard.setVolatileDomain(previewDefaults, forName: UserDefaults.argumentDomain)
        markStage("configure-index")
        FSearchIndex.shared.configuredRoots = [fixture.path]
        FSearchIndex.shared.usePersistentMMapCache = false
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                markStage("did-finish-launching")
                try? await Task.sleep(for: .seconds(2))
                var candidate: NSWindow?
                for _ in 0..<50 {
                    candidate = NSApp.windows.first(where: { !($0 is NSPanel) })
                    if candidate != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let window = candidate else {
                    print("WINDOWS: \(NSApp.windows.map { "\($0.title): visible=\($0.isVisible), class=\(type(of: $0))" })")
                    require(false, "no app window after launch"); return
                }
                markStage("activate-window")
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.setContentSize(NSSize(width: 1180, height: 730))
                NSApp.appearance = NSAppearance(named: .aqua)
                try? await Task.sleep(for: .milliseconds(400))
                markStage("native-assertions")
                let state = AppState.shared
                let pane = state.activeTab
                #if BETTERFINDER_TESTING
                require(pane.currentURL.standardizedFileURL == fixture.standardizedFileURL &&
                        state.rightPane.currentURL.standardizedFileURL == fixture.standardizedFileURL,
                        "both panes must stay in the synthetic fixture at startup")
                require(FSearchIndex.shared.configuredRoots == [fixture.path], "index roots must stay isolated")
                require(!pane.wasRestoredFromSession && !pane.isSessionBrowsingPaused,
                        "keyboard fixture must be freshly loaded rather than session-paused")
                let expectedNames: Set<String> = ["Dokumenty", "Fotografie", "Projekty", "Archiwum",
                    "Notatki ze spotkania.md", "Plan projektu.txt", "README.md", "Szkice.svg", "Zestawienie.csv"]
                require(Set(pane.displayedItems.map(\.name)) == expectedNames && pane.selectableItems.count == 9,
                        "keyboard fixture must expose all nine synthetic entries")
                require(pane.selectedPaths.isEmpty, "keyboard fixture must start without preselected items")
                #endif
                require(window.isKeyWindow && NSApp.keyWindow === window,
                        "keyboard event target must be the key window")
                require(window.firstResponder is FileDragSourceView, "file pane must receive initial keyboard focus")
                postKey(125, "\u{f701}", window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require(pane.selectedItems.count == 1, "Down must select a file")
                postKey(125, "\u{f701}", modifiers: [.shift], window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require(pane.selectedItems.count == 2, "Shift-Down must extend selection")
                postKey(36, "\r", window: window)
                try? await Task.sleep(for: .milliseconds(250))
                require(window.attachedSheet != nil && pane.renamingItemPath != nil, "Return must open the native rename sheet")
                if let sheet = window.attachedSheet { capture(sheet, to: base.appendingPathComponent("rename.png")) }
                pane.renamingItemPath = nil
                try? await Task.sleep(for: .milliseconds(250))
                pane.selectedPaths = []
                capture(window, to: base.appendingPathComponent("light.png"))

                state.addNewTab(at: fixture.appendingPathComponent("Projekty"))
                let createdID = state.activeTabId
                state.closeTab(createdID)
                state.reopenClosedTab()
                require(state.activeTabId == createdID, "reopened tab must restore the closed tab")
                state.closeTab(createdID)
                pane.searchScope = .currentFolder
                pane.searchQuery = "^README"
                pane.triggerSearch()
                state.focusSearchFieldTrigger += 1
                try? await Task.sleep(for: .milliseconds(300))
                require(pane.displayedItems.map(\.name) == ["README.md"], "search must match the fixture")
                require(window.firstResponder is NSTextView, "programmatic search-focus trigger must reach search text")
                postKey(0, "a", modifiers: [.command], window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require((window.firstResponder as? NSTextView)?.selectedRange().length == pane.searchQuery.utf16.count,
                        "Command-A in search must select text")
                require(pane.selectedItems.isEmpty, "text editing must not select underlying files")
                capture(window, to: base.appendingPathComponent("search.png"))
                pane.clearSearch()
                if let responder = fileResponder(in: window.contentView) { window.makeFirstResponder(responder) }
                window.setContentSize(NSSize(width: 900, height: 650))
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("compact.png"))
                window.setContentSize(NSSize(width: 1180, height: 730))
                state.showInspector = true
                pane.selectAll()
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("inspector.png"))
                state.showInspector = false
                state.showSidebar = false
                state.toggleDualPane()
                state.rightPane.navigate(to: fixture.appendingPathComponent("Projekty"))
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("dual-pane.png"))
                state.toggleDualPane()
                state.showSidebar = true
                pane.viewMode = .icons
                pane.selectedPaths = []
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("dark-icons.png"))
                let summary = "PASS native window, initial focus, arrow/Shift selection, rename sheet, tabs, search, text Command-A, compact/dual/light/dark layouts"
                try? summary.write(to: base.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
                print(summary)
                fflush(stdout)
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            require(false, "native preview timed out; a graphical macOS session is required")
        }
        require(Thread.isMainThread, "bootstrap App.main requires the main thread")
        markStage("enter-app-main")
        BetterFinderApp.main()
    }

    // Best-effort diagnostics cannot throw out of main or print paths/errors.
    @MainActor static func writeDiagnostic(_ value: String, file: String) {
        guard let path = ProcessInfo.processInfo.environment["BETTERFINDER_PREVIEW_OUTPUT"],
              path.hasPrefix("/") else { return }
        let target = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(file)
        try? value.write(to: target, atomically: true, encoding: .utf8)
    }

    @MainActor static func markStage(_ stage: String) {
        writeDiagnostic(stage, file: "stage.txt")
    }

    @MainActor static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            let summary = "FAIL: \(message)"
            writeDiagnostic(summary, file: "verification.txt")
            fputs("PREVIEW \(summary)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func postKey(_ code: UInt16, _ characters: String,
                                   modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else {
            require(false, "cannot construct native key event"); return
        }
        require(event.window === window, "native key event must resolve to the target window")
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor static func fileResponder(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is FileDragSourceView { return view }
        for subview in view.subviews { if let found = fileResponder(in: subview) { return found } }
        return nil
    }

    @MainActor static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview else { require(false, "missing window content"); return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { require(false, "cannot render window"); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { require(false, "cannot encode window render"); return }
        do { try png.write(to: url) }
        catch { require(false, "cannot write window render"); return }
        print("CAPTURE \(url.path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
