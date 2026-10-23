import SwiftUI
import AppKit
import Darwin

@main
struct NativePreview {
    @MainActor static var captureSequence = 0
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
                if ProcessInfo.processInfo.environment["BETTERFINDER_PREVIEW_MODE"] == "interaction" {
                    await interactionChecks(window: window, base: base, fixture: fixture)
                    let summary = "PASS native keyboard/address subset; AX disclosure and resize not verified"
                    try? summary.write(to: base.appendingPathComponent("interaction-verification.txt"), atomically: true, encoding: .utf8)
                    print(summary)
                    exit(0)
                }
                // Visual fixture preparation is not an interaction assertion.
                pane.renamingItemPath = fixture.appendingPathComponent("README.md").path
                await settle()
                guard let rename = window.attachedSheet else { require(false, "visual rename sheet exposed"); return }
                capture(rename, to: base.appendingPathComponent("rename.png"))
                pane.renamingItemPath = nil
                await settle()
                pane.selectedPaths = []
                capture(window, to: base.appendingPathComponent("light.png"))
                pane.searchScope = .currentFolder
                pane.searchQuery = "^README"
                pane.triggerSearch()
                await settle()
                capture(window, to: base.appendingPathComponent("search.png"))
                pane.clearSearch()
                window.setContentSize(NSSize(width: 900, height: 650))
                await settle()
                capture(window, to: base.appendingPathComponent("compact.png"))
                window.setContentSize(NSSize(width: 1180, height: 730))
                state.showInspector = true
                pane.selectAll()
                await settle()
                capture(window, to: base.appendingPathComponent("inspector.png"))
                state.showInspector = false
                state.showSidebar = false
                state.isDualPane = true
                state.rightPane.navigate(to: fixture.appendingPathComponent("Projekty"))
                await settle()
                capture(window, to: base.appendingPathComponent("dual-pane.png"))
                state.isDualPane = false
                state.showSidebar = true
                pane.viewMode = .icons
                pane.selectedPaths = []
                NSApp.appearance = NSAppearance(named: .darkAqua)
                await settle()
                capture(window, to: base.appendingPathComponent("dark-icons.png"))
                await broadScenes(window: window, base: base, fixture: fixture)
                let summary = "PASS visual-fixtures-only: 33 synthetic scenes; AX disclosure/resize interactions not verified"
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
        if ProcessInfo.processInfo.environment["BETTERFINDER_PREVIEW_MODE"] == "interaction" { return }
        guard let view = window.contentView?.superview else { require(false, "missing window content"); return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { require(false, "cannot render window"); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { require(false, "cannot encode window render"); return }
        do { try png.write(to: url) }
        catch { require(false, "cannot write window render"); return }
        #if BETTERFINDER_TESTING
        if ProcessInfo.processInfo.environment["BETTERFINDER_PREVIEW_MODE"] == "visual" {
            require(NSApp.windows.contains { $0 === window } && window.windowNumber > 0,
                    "visual capture must target owned window")
            let output = url.deletingLastPathComponent()
            if url.lastPathComponent == "light.png" {
                do { try png.write(to: output.appendingPathComponent("light-cacheDisplay.png")) }
                catch { require(false, "cannot write window render"); return }
            }
            let response = output.appendingPathComponent("capture-response.json")
            try? FileManager.default.removeItem(at: response)
            let originalWindowNumber = window.windowNumber
            guard let token = ProcessInfo.processInfo.environment["BETTERFINDER_CAPTURE_TOKEN"],
                  token.count == 32, token.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                require(false, "visual capture token invalid"); return
            }
            captureSequence += 1
            let sequence = captureSequence
            require((1...33).contains(sequence), "visual capture sequence invalid")
            let request: [String: Any] = ["scene": url.lastPathComponent, "window": originalWindowNumber,
                "pid": ProcessInfo.processInfo.processIdentifier, "sequence": sequence, "token": token]
            do {
                let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
                try data.write(to: output.appendingPathComponent("capture-request.json"), options: .atomic)
            } catch { require(false, "visual capture request failed"); return }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var received = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if FileManager.default.fileExists(atPath: response.path) {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: response.path),
                          attrs[.type] as? FileAttributeType == .typeRegular,
                          let size = attrs[.size] as? NSNumber, size.intValue <= 512,
                          let data = try? Data(contentsOf: response),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          Set(object.keys) == Set(["scene", "status", "sequence", "token"]),
                          let reply = try? JSONDecoder().decode(NativeCaptureResponse.self, from: data),
                          reply.scene == url.lastPathComponent, reply.sequence == sequence, reply.token == token,
                          ["composited", "unsupported"].contains(reply.status) else {
                        require(false, "visual capture response invalid"); return
                    }
                    require(NSApp.windows.contains { $0 === window } && window.windowNumber == originalWindowNumber,
                            "visual capture window changed")
                    if reply.status == "composited" {
                        let composite = output.appendingPathComponent("composited-" + url.lastPathComponent)
                        guard let attrs = try? FileManager.default.attributesOfItem(atPath: composite.path),
                              attrs[.type] as? FileAttributeType == .typeRegular,
                              let size = attrs[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024,
                              let data = try? Data(contentsOf: composite),
                              data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else {
                            require(false, "visual capture composite invalid"); return
                        }
                        do { try data.write(to: url, options: .atomic) }
                        catch { require(false, "cannot write window render"); return }
                    }
                    received = true
                    break
                }
                CFRunLoopRunInMode(.defaultMode, 0.01, false)
            }
            require(received, "visual capture response timeout")
        }
        #endif
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
            let identity = ObjectIdentifier(object as AnyObject)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            // AppKit hosting views can bridge SwiftUI accessibility descendants
            // without exposing them directly through the window's AX children.
            if let window = object as? NSWindow, let content = window.contentView,
               queue.count < 2048 { queue.append(content) }
            if let view = object as? NSView {
                for child in view.subviews.prefix(max(0, 2048 - queue.count)) { queue.append(child) }
            }
            if let item = object as? any NSAccessibilityProtocol {
                if item.accessibilityLabel() == label { return item }
                queue.append(contentsOf: (item.accessibilityChildren() ?? []).prefix(max(0, 2048 - queue.count)))
            }
        }
        return nil
    }

    // Failure-only fixed-category counts from this isolated application's own UI.
    // Never print accessibility text, values, paths, class names or other applications.
    @MainActor static func networkExposureDiagnostic(window: NSWindow, expected: String, output: URL) -> String {
        let state = AppState.shared
        let groups = state.networkServerGroups
        let fixturePresent = groups.contains { $0.title == "studio-preview.invalid" && $0.volumes.count == 2 }
        var queue: [Any] = [window]
        if let content = window.contentView { queue.append(content) }
        var visited = Set<ObjectIdentifier>()
        var inspected = 0
        var truncated = false
        var exactLabels = 0, fixtureLabels = 0, exactTitles = 0
        var sidebar = false, favorite = false, tag = false
        while !queue.isEmpty && inspected < 2048 {
            let object = queue.removeFirst()
            let identity = ObjectIdentifier(object as AnyObject)
            guard visited.insert(identity).inserted else { continue }
            inspected += 1
            if let view = object as? NSView {
                let children = view.subviews
                let remaining = max(0, 2048 - queue.count)
                truncated = truncated || children.count > remaining
                for child in children.prefix(remaining) { queue.append(child) }
            }
            if let item = object as? any NSAccessibilityProtocol {
                let label = item.accessibilityLabel() ?? ""
                sidebar = sidebar || label == "Pasek boczny"
                favorite = favorite || label == "Projekty — ręcznie jako pierwsze"
                tag = tag || FinderTagColor.allCases.contains { label == "Tag: " + $0.displayName }
                if label == expected { exactLabels += 1 }
                if item.accessibilityTitle() == expected { exactTitles += 1 }
                if label.contains("studio-preview.invalid") { fixtureLabels += 1 }
                let children = item.accessibilityChildren() ?? []
                let remaining = max(0, 2048 - queue.count)
                truncated = truncated || children.count > remaining
                for child in children.prefix(remaining) { queue.append(child) }
            }
        }
        let metadata: [String: Any] = [
            "sidebar": sidebar, "favorite": favorite, "tag": tag,
            "exactLabel": exactLabels > 0, "exactTitle": exactTitles > 0,
            "visited": inspected, "truncated": truncated || !queue.isEmpty,
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            try? encoded.write(to: output.appendingPathComponent("diagnostic-network-ax.json"), options: .atomic)
        }
        if !fixturePresent { return "broad network exposure: fixture missing" }
        if exactLabels > 0 { return "broad network exposure: exact label in view-seeded hierarchy" }
        if exactTitles > 0 { return "broad network exposure: exact native title without label" }
        if fixtureLabels > 0 { return "broad network exposure: fixture label differs" }
        if truncated || !queue.isEmpty { return "broad network exposure: traversal capped" }
        return "broad network exposure: fixture present without accessible label"
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

    @MainActor static func interactionChecks(window: NSWindow, base: URL, fixture: URL) async {
        let state = AppState.shared
        let pane = state.leftTab
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
        NativePreviewFixtureConfig.shared.tagsExpanded = true
        await scene("sidebar-full-dark", window: window, base: base)
        NativePreviewFixtureConfig.shared.tagsExpanded = false
        state.favorites = []
        await scene("sidebar-empty", window: window, base: base)
        state.favorites = Array(favoriteRows.reversed())
        require(state.favorites.map(\.id) == favoriteRows.reversed().map(\.id), "broad manual favorite order")
        await scene("sidebar-reordered", window: window, base: base)
        NativePreviewFixtureConfig.shared.expandedServers = ["server:smb://studio-preview.invalid"]
        NativePreviewFixtureConfig.shared.tagsExpanded = false
        await settle()
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
        for side in [PaneSide.left, .right] {
            state.activePaneSide = side
            let target = state.activeTab
            NativePreviewFixtureConfig.shared.addresses = [target.id: FolderAddressVisualFixture(
                draft: target.currentURL.path, validationMessage: nil, isFocused: true)]
            await scene(side == .left ? "address-edit-left" : "address-edit-right", window: window, base: base)
        }
        state.activePaneSide = .left
        NativePreviewFixtureConfig.shared.addresses = [pane.id: FolderAddressVisualFixture(
            draft: fixture.appendingPathComponent("Nieistniejący folder testowy").path,
            validationMessage: "Nie można otworzyć folderu testowego.", isFocused: true)]
        await scene("address-invalid", window: window, base: base)
        NativePreviewFixtureConfig.shared.addresses = [:]
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
        NativePreviewFixtureConfig.shared.terminalHeight = 220
        await scene("terminal-default", window: window, base: base)
        NativePreviewFixtureConfig.shared.terminalHeight = 180
        await scene("terminal-min", window: window, base: base)
        state.terminalWorkspace.ensureInitial(directory: fixture)
        guard let runningPresentation = state.terminalWorkspace.selected else { require(false, "broad terminal tabs created"); return }
        runningPresentation.setRunningPresentationForTesting(true)
        await scene("terminal-running-min", window: window, base: base)
        runningPresentation.setRunningPresentationForTesting(false)
        NativePreviewFixtureConfig.shared.terminalHeight = 9999
        await scene("terminal-max", window: window, base: base)
        NativePreviewFixtureConfig.shared.terminalHeight = 220
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
        require(workspace.tabs.isEmpty,
                "visual terminal tabs empty")
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

#if BETTERFINDER_TESTING
@MainActor final class NativePreviewFixtureConfig: ObservableObject {
    static let shared = NativePreviewFixtureConfig()
    @Published var expandedServers: Set<String> = []
    @Published var tagsExpanded: Bool? = nil
    @Published var terminalHeight: CGFloat? = nil
    @Published var addresses: [UUID: FolderAddressVisualFixture] = [:]
}
@MainActor struct NativePreviewRootView: View {
    @ObservedObject private var fixtures = NativePreviewFixtureConfig.shared
    var body: some View {
        MainWindowView()
            .environment(\.sidebarPreviewExpandedServerIDs, fixtures.expandedServers)
            .environment(\.sidebarPreviewTagsExpanded, fixtures.tagsExpanded)
            .environment(\.terminalPreviewRequestedHeight, fixtures.terminalHeight)
            .environment(\.folderAddressVisualFixtures, fixtures.addresses)
    }
}
#else
struct NativePreviewRootView: View {
    var body: some View { MainWindowView() }
}
#endif

private struct NativeCaptureResponse: Decodable {
    let scene: String
    let status: String
    let sequence: Int
    let token: String
}
