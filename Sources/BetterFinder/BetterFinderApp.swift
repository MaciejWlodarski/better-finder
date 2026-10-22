import SwiftUI
import AppKit

@main
struct BetterFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var fileOps = FileOperationsManager.shared

    var body: some Scene {
        WindowGroup("BetterFinder") {
            MainWindowView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 760)
        .commands {
            // App Settings (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Ustawienia BetterFinder & fsearch...") {
                    appState.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // File Menu Additions
            CommandGroup(replacing: .newItem) {
                Button("Nowa karta") {
                    appState.addNewTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("Otwórz ponownie zamkniętą kartę") { appState.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(appState.recentlyClosedTabs.isEmpty)

                Button("Nowy folder...") {
                    appState.showNewFolderSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Nowy plik z szablonu...") {
                    appState.showNewFileSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Zamknij kartę") {
                    if appState.isDualPane && appState.activePaneSide == .right {
                        appState.toggleDualPane()
                    } else if appState.tabs.count > 1 {
                        appState.closeTab(appState.activeTabId)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // Undo / Redo File Operations
            CommandGroup(replacing: .undoRedo) {
                Button(fileOps.undoLabel) {
                    if isEditingText { NSApp.keyWindow?.firstResponder?.undoManager?.undo() }
                    else { fileOps.undoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!isEditingText && (!fileOps.canUndo || fileOps.isBusy))

                Button(fileOps.redoLabel) {
                    if isEditingText { NSApp.keyWindow?.firstResponder?.undoManager?.redo() }
                    else { fileOps.redoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!isEditingText && (!fileOps.canRedo || fileOps.isBusy))
            }

            // Edit / File Operations Menu
            CommandGroup(replacing: .pasteboard) {
                Divider()

                Button("Wytnij pliki (Cut)") {
                    if !routeTextAction(#selector(NSText.cut(_:))), canUseFileCommands { fileOps.cutItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("x", modifiers: [.command])

                Button("Kopiuj pliki") {
                    if !routeTextAction(#selector(NSText.copy(_:))), canUseFileCommands { fileOps.copyItems(appState.activeTab.selectedItems) }
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("Wklej / Przenieś tutaj") {
                    if !routeTextAction(#selector(NSText.paste(_:))), canUseFileCommands {
                        fileOps.paste(into: appState.activeTab.currentURL)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command])

                Button("Zaznacz wszystko") {
                    if !routeTextAction(#selector(NSText.selectAll(_:))), canUseFileCommands { appState.activeTab.selectAll() }
                }
                .keyboardShortcut("a", modifiers: [.command])

                Divider()

                Button("Kopiuj pełną ścieżkę") {
                    let sel = appState.activeTab.selectedItems
                    if sel.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.activeTab.currentURL.path, forType: .string)
                    } else {
                        fileOps.copyPaths(sel)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Duplikuj zaznaczone") {
                    guard canUseFileCommands else { return }
                    fileOps.duplicateItems(appState.activeTab.selectedItems)
                    appState.activeTab.reloadDirectory()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy)

                Button("Przenieś do Kosza") {
                    if routeTextAction(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                    guard canUseFileCommands else { return }
                    fileOps.moveToTrash(appState.activeTab.selectedItems)
                    appState.activeTab.reloadDirectory()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!isEditingText && (!canUseFileCommands || appState.activeTab.selectedItems.isEmpty || fileOps.isBusy))
            }

            // fsearch & Navigation Menu
            CommandMenu("Przejdź") {
                Button("Szukaj na pasku fsearch") {
                    appState.focusSearchFieldTrigger += 1
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Błyskawiczne okno Spotlight fsearch...") {
                    appState.showQuickFSearchModal.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Divider()

                Button("Edytuj pasek ścieżki") {
                    appState.activeTab.isEditingPathBar.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Button("Idź do folderu…") { appState.activeTab.isEditingPathBar = true }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Folder domowy") {
                    appState.activeTab.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Odśwież") { appState.activeTab.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])

                Button("Wstecz") {
                    appState.activeTab.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(appState.activeTab.historyBack.isEmpty)

                Button("Dalej") {
                    appState.activeTab.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(appState.activeTab.historyForward.isEmpty)

                Button("Folder nadrzędny") {
                    appState.activeTab.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("Otwórz zaznaczony element") {
                    if let item = appState.activeTab.primarySelectedItem {
                        if item.isDirectory && item.fileExtension.lowercased() != "app" {
                            appState.activeTab.navigate(to: item.url)
                        } else {
                            NSWorkspace.shared.open(item.url)
                        }
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(appState.activeTab.selectedItems.isEmpty)

                Divider()

                Button("Przebuduj indeks RAM/mmap fsearch") {
                    appState.isIndexing = true
                    FSearchIndex.shared.startIndexing()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // View Menu Additions
            CommandGroup(after: .toolbar) {
                Button(appState.showSidebar ? "Ukryj pasek boczny" : "Pokaż pasek boczny") { appState.showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("Widok listy") {
                    appState.activeTab.viewMode = .list
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Widok ikon") {
                    appState.activeTab.viewMode = .icons
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Widok kolumn (Miller Columns)") {
                    appState.activeTab.viewMode = .columns
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("Widok WizTree Treemap & Analizator dysku") {
                    appState.activeTab.viewMode = .wiztree
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Button("Przełącz widok dwupanelowy (Dual-Pane)") {
                    appState.toggleDualPane()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Wbudowany dolny panel Terminala") {
                    appState.showTerminalDrawer.toggle()
                }
                .keyboardShortcut("`", modifiers: [.control])

                Button("Pokaż/ukryj pliki ukryte") {
                    appState.activeTab.showHiddenFiles.toggle()
                    appState.activeTab.refresh()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("Pokaż/ukryj Inspektora") {
                    appState.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Quick Look (Podgląd)") {
                    appState.toggleQuickLook()
                }
                .keyboardShortcut("y", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Następna karta") { appState.selectAdjacentTab(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(appState.tabs.count < 2)
                Button("Poprzednia karta") { appState.selectAdjacentTab(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(appState.tabs.count < 2)
            }
        }
    }

    private var canUseFileCommands: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return !isEditingText && !(window is NSPanel) && window.attachedSheet == nil && window.sheetParent == nil
    }

    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView || NSApp.keyWindow?.firstResponder is NSTextField
    }

    private func routeTextAction(_ action: Selector) -> Bool {
        guard isEditingText, let responder = NSApp.keyWindow?.firstResponder else { return false }
        _ = NSApp.sendAction(action, to: responder, from: nil)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }

            guard let window = event.window, !(window is NSPanel), window.sheetParent == nil,
                  window.attachedSheet == nil else { return event }
            let appState = AppState.shared
            if appState.showQuickFSearchModal || appState.showNewFileSheet ||
               appState.showNewFolderSheet || appState.showCompareSheet ||
               appState.showSettingsSheet {
                return event
            }

            let tab = appState.activeTab

            // Spacebar (keyCode 49) -> Toggle Quick Look
            if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if !tab.selectedPaths.isEmpty {
                    appState.toggleQuickLook()
                    return nil
                }
            }

            // Right Arrow (124) / Left Arrow (123) in List View -> Expand / Collapse folder tree inline
            if tab.viewMode == .list && (event.keyCode == 124 || event.keyCode == 123) &&
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if let item = tab.primarySelectedItem, item.isDirectory {
                    let expand = (event.keyCode == 124)
                    if expand != tab.isExpanded(item.path) {
                        tab.toggleFolderExpansion(for: item)
                        return nil
                    }
                }
            }

            // Down Arrow (125) / Up Arrow (126) -> Move selection in file list
            if (event.keyCode == 125 || event.keyCode == 126) &&
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                tab.moveSelection(by: event.keyCode == 125 ? 1 : -1, extending: event.modifierFlags.contains(.shift))
                return nil
            }

            if event.keyCode == 36 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               let item = tab.primarySelectedItem {
                tab.renamingItemPath = item.path
                return nil
            }
            if event.keyCode == 53 && !tab.searchQuery.isEmpty {
                tab.clearSearch()
                return nil
            }
            if event.keyCode == 48 && event.modifierFlags.contains(.control) {
                appState.selectAdjacentTab(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.persistTabsState()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
