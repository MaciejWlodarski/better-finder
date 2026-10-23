import SwiftUI
import AppKit
import Darwin

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
                await broadScenes(window: window, base: base, fixture: fixture)
                let summary = "PASS native window, initial focus, arrow/Shift selection, rename sheet, tabs, search, text Command-A, compact/dual/light/dark layouts"
                try? summary.write(to: base.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
                print(summary)
                fflush(stdout)
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
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

extension NativePreview {
    // These actions target our own in-process hierarchy only. They do not use
    // AXUIElement, global events, permission grants, or another application's UI.
    @MainActor static func accessible(_ root: Any, label: String) -> (any NSAccessibilityProtocol)? {
        var queue: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        var count = 0
        while !queue.isEmpty && count < 2048 {
            let object = queue.removeFirst()
            guard let item = object as? any NSAccessibilityProtocol else { continue }
            let identity = ObjectIdentifier(item)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            if item.accessibilityLabel() == label { return item }
            queue.append(contentsOf: item.accessibilityChildren() ?? [])
        }
        return nil
    }

    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(180))
    }

    @MainActor static func scene(_ name: String, window: NSWindow, base: URL) async {
        await settle()
        capture(window, to: base.appendingPathComponent(name + ".png"))
    }

    @MainActor static func addressFields(_ view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var fields: [NSTextField] = []
        if let field = view as? NSTextField, field.accessibilityIdentifier() == "folder.address" { fields.append(field) }
        for child in view.subviews { fields.append(contentsOf: addressFields(child)) }
        return fields
    }

    @MainActor static func broadScenes(window: NSWindow, base: URL, fixture: URL) async {
        #if BETTERFINDER_TESTING
        let state = AppState.shared
        let pane = state.leftTab
        state.isDualPane = false
        state.activePaneSide = .left
        state.showSidebar = true
        state.showInspector = false
        pane.clearSearch()
        pane.viewMode = .list
        pane.selectedPaths = []
        window.setContentSize(NSSize(width: 1180, height: 730))
        let favoriteRows = [
            SidebarLocationItem(title: "Projekty — ręcznie jako pierwsze", iconName: "folder", url: fixture.appendingPathComponent("Projekty"), isCustomBookmark: true),
            SidebarLocationItem(title: "Bardzo długa własna nazwa folderu roboczego do kontroli obcinania", iconName: "folder", url: fixture.appendingPathComponent("Dokumenty"), isCustomBookmark: true),
            SidebarLocationItem(title: "Fotografie", iconName: "photo", url: fixture.appendingPathComponent("Fotografie"), isCustomBookmark: true)
        ]
        state.favorites = favoriteRows
        let server = NetworkServerIdentity.parse(remountURL: URL(string: "smb://studio-preview.invalid"))
        require(server != nil, "broad synthetic server identity")
        let volumes = [
            VolumeInfoItem(name: "Dysk testowy", url: fixture, totalBytes: 1000, freeBytes: 600, isRemovable: false),
            VolumeInfoItem(name: "Dokumenty", url: fixture.appendingPathComponent("Dokumenty"), totalBytes: nil, freeBytes: nil, isRemovable: false, isNetwork: true, networkServer: server),
            VolumeInfoItem(name: "Projekty z długą nazwą udziału", url: fixture.appendingPathComponent("Projekty"), totalBytes: 1000, freeBytes: 0, isRemovable: false, isNetwork: true, networkServer: server),
            VolumeInfoItem(name: "Nieznany serwer", url: fixture.appendingPathComponent("Archiwum"), totalBytes: nil, freeBytes: nil, isRemovable: false, isNetwork: true)
        ]
        state.installVolumeFixturesForTesting(volumes)
        require(state.networkServerGroups.count == 2 && volumes[1].usedFraction == nil && volumes[2].usedFraction == 1,
                "broad network grouping and unknown capacity")
        NSApp.appearance = NSAppearance(named: .aqua)
        await scene("sidebar-full-light", window: window, base: base)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await scene("sidebar-full-dark", window: window, base: base)
        state.favorites = []
        await scene("sidebar-empty", window: window, base: base)
        state.favorites = Array(favoriteRows.reversed())
        require(state.favorites.map(\.id) == favoriteRows.reversed().map(\.id), "broad manual favorite order")
        await scene("sidebar-reordered", window: window, base: base)
        let disclosureLabel = "Serwer studio-preview.invalid, 2 udziałów"
        guard let disclosure = accessible(window, label: disclosureLabel) else {
            require(false, "broad network disclosure exposed"); return
        }
        require(disclosure.accessibilityPerformPress(), "broad network disclosure action")
        await settle()
        require((accessible(window, label: disclosureLabel)?.accessibilityValue() as? String) == "Rozwinięty",
                "broad network disclosure expanded")
        await scene("network-expanded-dark", window: window, base: base)
        NSApp.appearance = NSAppearance(named: .aqua)
        await scene("network-expanded-light", window: window, base: base)

        pane.viewMode = .columns
        await scene("columns", window: window, base: base)
        pane.viewMode = .list
        state.showInspector = true
        pane.selectedPaths = [fixture.appendingPathComponent("README.md").path]
        await scene("inspector-single", window: window, base: base)
        state.showInspector = false
        pane.selectedPaths = []

        state.showSettingsSheet = true
        await settle()
        guard let settings = window.attachedSheet else { require(false, "broad settings sheet exposed"); return }
        settings.setContentSize(NSSize(width: 620, height: 540))
        await scene("settings-short-light", window: settings, base: base)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await scene("settings-short-dark", window: settings, base: base)
        state.showSettingsSheet = false
        await settle()
        NSApp.appearance = NSAppearance(named: .aqua)
        state.showNewFolderSheet = true
        await settle()
        guard let folderSheet = window.attachedSheet else { require(false, "broad folder sheet exposed"); return }
        await scene("new-folder", window: folderSheet, base: base)
        state.showNewFolderSheet = false
        await settle()

        state.isDualPane = true
        state.rightPane.navigate(to: fixture.appendingPathComponent("Projekty"))
        window.setContentSize(NSSize(width: 1360, height: 760))
        await settle()
        let leftBefore = pane.currentURL
        let rightBefore = state.rightPane.currentURL
        for side in [PaneSide.left, .right] {
            state.activePaneSide = side
            let target = state.activeTab
            target.requestPathEditing()
            await settle()
            guard let editor = window.firstResponder as? NSTextView else { require(false, "broad address editor focused"); return }
            require(editor.string == target.currentURL.path && editor.selectedRange().length == editor.string.utf16.count,
                    "broad address selects correct pane path")
            await scene(side == .left ? "address-edit-left" : "address-edit-right", window: window, base: base)
            postKey(53, "\u{1b}", window: window)
            await settle()
            require(!target.isEditingPathBar && pane.currentURL == leftBefore && state.rightPane.currentURL == rightBefore,
                    "broad address Escape preserves both panes")
        }
        state.activePaneSide = .left
        let historyBefore = pane.historyBack
        pane.requestPathEditing()
        await settle()
        guard let editor = window.firstResponder as? NSTextView else { require(false, "broad address editor focused"); return }
        editor.insertText(fixture.appendingPathComponent("Nieistniejący folder testowy").path, replacementRange: editor.selectedRange())
        postKey(36, "\r", window: window)
        await settle()
        require(pane.currentURL == leftBefore && pane.historyBack == historyBefore && state.rightPane.currentURL == rightBefore && pane.isEditingPathBar,
                "broad invalid address retains navigation")
        await scene("address-invalid", window: window, base: base)
        postKey(53, "\u{1b}", window: window)
        await settle()

        state.isDualPane = false
        let oldReader = pane.navigationDirectoryReader
        let oldURL = pane.currentURL
        pane.navigationDirectoryReader = { _, _ in
            BulkCrawler.DirectoryReadResult(entries: [], isComplete: false, errorCode: EPERM)
        }
        pane.navigate(to: fixture.appendingPathComponent("Dokumenty"))
        require(pane.navigationFailureIsPermissionDenied && pane.currentURL == oldURL,
                "broad permission failure preserves folder")
        window.setContentSize(NSSize(width: 880, height: 650))
        await scene("permission-banner", window: window, base: base)
        let longTarget = fixture.appendingPathComponent(String(repeating: "dlugi-test-", count: 20), isDirectory: true)
        do { try FileManager.default.createDirectory(at: longTarget, withIntermediateDirectories: true) }
        catch { require(false, "broad long synthetic directory created"); return }
        pane.navigationDirectoryReader = { _, _ in
            BulkCrawler.DirectoryReadResult(entries: [], isComplete: false, errorCode: EIO)
        }
        pane.navigate(to: longTarget)
        require(!pane.navigationFailureIsPermissionDenied && pane.navigationDiagnostic != nil && pane.currentURL == oldURL,
                "broad transient failure preserves folder")
        let narrow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        narrow.contentView = NSHostingView(rootView: FilePaneView(appState: state, pane: pane, paneSide: .left, isFocusedPane: true)
            .frame(width: 260, height: 650))
        narrow.orderFront(nil)
        await scene("transient-error-narrow", window: narrow, base: base)
        narrow.orderOut(nil)
        narrow.close()
        window.makeKeyAndOrderFront(nil)
        pane.navigationDirectoryReader = oldReader
        if let failure = pane.navigationFailureID { pane.dismissNavigationFailure(expectedFailureID: failure) }
        state.favorites = [SidebarLocationItem(title: "Kosz systemowy", iconName: "trash", url: state.systemTrashURL, isCustomBookmark: true)]
        var fakeOpened = false
        let outcome = SystemTrashNavigation.open(state.systemTrashURL, systemTrashURL: state.systemTrashURL,
            openInFinder: { target in fakeOpened = target == state.systemTrashURL; return true },
            navigate: { _ in require(false, "broad Trash must not navigate") })
        require(outcome == .openedInFinder && fakeOpened && pane.currentURL == oldURL,
                "broad synthetic Trash handoff")
        await scene("trash-sidebar", window: window, base: base)
        state.favorites = favoriteRows
        state.showTerminalDrawer = true
        window.setContentSize(NSSize(width: 1180, height: 730))
        await settle()
        require((accessible(window, label: "Wysokość terminala")?.accessibilityValue() as? String) == "220 punktów",
                "broad terminal default height")
        await scene("terminal-default", window: window, base: base)
        for _ in 0..<3 {
            guard let handle = accessible(window, label: "Wysokość terminala") else { require(false, "broad terminal resize exposed"); return }
            require(handle.accessibilityPerformDecrement(), "broad terminal resize action")
            await settle()
        }
        require((accessible(window, label: "Wysokość terminala")?.accessibilityValue() as? String) == "180 punktów",
                "broad terminal minimum height")
        await scene("terminal-min", window: window, base: base)
        state.terminalWorkspace.ensureInitial(directory: fixture)
        guard let runningPresentation = state.terminalWorkspace.selected else { require(false, "broad terminal tabs created"); return }
        runningPresentation.setRunningPresentationForTesting(true)
        await settle()
        require(accessible(window, label: "Przerwij") != nil, "broad terminal running Stop exposed")
        await scene("terminal-running-min", window: window, base: base)
        runningPresentation.setRunningPresentationForTesting(false)
        for _ in 0..<12 {
            guard let handle = accessible(window, label: "Wysokość terminala") else { require(false, "broad terminal resize exposed"); return }
            require(handle.accessibilityPerformIncrement(), "broad terminal resize action")
            await settle()
        }
        guard let maximumHandle = accessible(window, label: "Wysokość terminala"),
              let maximumValue = maximumHandle.accessibilityValue() as? String else {
            require(false, "broad terminal resize exposed"); return
        }
        require(maximumHandle.accessibilityPerformIncrement(), "broad terminal resize action")
        await settle()
        require((accessible(window, label: "Wysokość terminala")?.accessibilityValue() as? String) == maximumValue && maximumValue != "180 punktów",
                "broad terminal maximum clamps")
        await scene("terminal-max", window: window, base: base)
        let workspace = state.terminalWorkspace
        workspace.ensureInitial(directory: fixture)
        guard let firstTerminal = workspace.selected,
              let secondTerminal = workspace.add(directory: fixture.appendingPathComponent("Projekty")) else {
            require(false, "broad terminal tabs created"); return
        }
        firstTerminal.commandInput = "pierwszy szkic — nie uruchamiać"
        secondTerminal.commandInput = "drugi szkic — nie uruchamiać"
        workspace.select(firstTerminal.id)
        await scene("terminal-tabs", window: window, base: base)
        require(workspace.tabs.count == 2 && firstTerminal.commandInput != secondTerminal.commandInput &&
                workspace.tabs.allSatisfy { !$0.isRunning }, "broad terminal tabs idle and independent")
        workspace.close(secondTerminal.id)
        require(workspace.selectedID == firstTerminal.id, "broad terminal tabs retain selection")
        for _ in 0..<7 { _ = workspace.add(directory: fixture.appendingPathComponent("Projekty")) }
        require(workspace.tabs.count == TerminalWorkspace.tabLimit && workspace.tabs.allSatisfy { !$0.isRunning },
                "broad terminal tab limit idle")
        window.setContentSize(NSSize(width: 880, height: 650))
        await scene("terminal-many-tabs", window: window, base: base)
        for id in workspace.tabs.map(\.id) { workspace.close(id) }
        await settle()
        require(workspace.tabs.isEmpty && accessible(window, label: "Ukryj terminal") != nil,
                "broad empty terminal retains hide")
        await scene("terminal-empty", window: window, base: base)
        state.showTerminalDrawer = false
        pane.viewMode = .wiztree
        await scene("analysis", window: window, base: base)
        pane.viewMode = .list

        // Paused pane constructors deliberately avoid filesystem reads. No resume.
        let pausedLeft = PaneTabState(initialURL: fixture.appendingPathComponent("Dokumenty"), loadImmediately: false)
        let pausedRight = PaneTabState(initialURL: fixture.appendingPathComponent("Projekty"), loadImmediately: false)
        state.tabs = [pausedLeft]
        state.activeTabId = pausedLeft.id
        state.rightPane = pausedRight
        state.isDualPane = true
        state.activePaneSide = .left
        window.setContentSize(NSSize(width: 1080, height: 650))
        require(pausedLeft.isSessionBrowsingPaused && pausedRight.isSessionBrowsingPaused, "broad panes remain paused")
        await scene("paused-dual", window: window, base: base)
        require(pausedLeft.isSessionBrowsingPaused && pausedRight.isSessionBrowsingPaused, "broad panes remain paused")
        #endif
    }
}
