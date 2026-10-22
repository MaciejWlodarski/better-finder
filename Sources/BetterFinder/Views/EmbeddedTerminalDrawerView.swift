import SwiftUI
import AppKit

public struct TerminalOutputLine: Identifiable {
    public let id = UUID()
    public let text: String
    public let isCommand: Bool
    public let isError: Bool
}

public struct EmbeddedTerminalDrawerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var commandInput: String = ""
    @ViewState private var outputLines: [TerminalOutputLine] = [
        TerminalOutputLine(
            text: "BetterFinder Terminal (Zsh) — zsynchronizowany z aktywną kartą. Wpisz polecenie (np. ls -la, git status, cd ..)",
            isCommand: false,
            isError: false
        )
    ]
    @ViewState private var commandHistory: [String] = []
    @ViewState private var isRunning: Bool = false
    @FocusState private var isInputFocused: Bool

    private let quickCommands = ["git status -sb", "ls -la", "du -sh * | sort -h", "git log -n 5 --oneline"]

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Terminal Header Bar
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)

                Text("Terminal")
                    .font(.system(size: 11.5, weight: .bold))

                Text(activeTab.currentURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)

                Divider()
                    .frame(height: 12)

                // Quick Command Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(quickCommands, id: \.self) { cmd in
                            Button(cmd) {
                                executeCommand(cmd)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }

                Spacer()

                Button {
                    outputLines.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Wyczyść wyjście terminala")

                Button {
                    FileOperationsManager.shared.openInTerminal(at: activeTab.currentURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Otwórz w zewnętrznym Terminalu / iTerm2")

                Button {
                    appState.showTerminalDrawer = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Ukryj panel terminala (Ctrl+`)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Output Scroll Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(outputLines) { line in
                            Text(line.text)
                                .font(.system(size: 11.5, weight: line.isCommand ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(
                                    line.isCommand
                                    ? Color.accentColor
                                    : (line.isError ? Color.orange : Color.primary.opacity(0.9))
                                )
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: outputLines.count) { _, _ in
                    if let last = outputLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Prompt Input Row
            HStack(spacing: 8) {
                Text("\(activeTab.currentURL.lastPathComponent) %")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)

                TextField("Wpisz polecenie zsh i naciśnij Enter (np. cd .., ls -la, git status)...", text: $commandInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isInputFocused)
                    .onSubmit {
                        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cmd.isEmpty else { return }
                        commandInput = ""
                        executeCommand(cmd)
                    }

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(height: 185)
        .onAppear {
            isInputFocused = true
        }
    }

    private func executeCommand(_ rawCmd: String) {
        let dirURL = activeTab.currentURL
        outputLines.append(TerminalOutputLine(
            text: "[\(dirURL.lastPathComponent)] % \(rawCmd)",
            isCommand: true,
            isError: false
        ))
        commandHistory.append(rawCmd)

        if rawCmd == "clear" {
            outputLines.removeAll()
            return
        }

        // Built-in `cd` handling synchronized with BetterFinder active tab!
        if rawCmd == "cd" || rawCmd.hasPrefix("cd ") {
            let arg = rawCmd == "cd" ? "~" : String(rawCmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let targetPath: String
            if arg.hasPrefix("~") {
                targetPath = (arg as NSString).expandingTildeInPath
            } else if arg.hasPrefix("/") {
                targetPath = arg
            } else {
                targetPath = dirURL.appendingPathComponent(arg).standardizedFileURL.path
            }
            let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue {
                activeTab.navigate(to: targetURL)
                outputLines.append(TerminalOutputLine(text: "→ \(targetURL.path)", isCommand: false, isError: false))
            } else {
                outputLines.append(TerminalOutputLine(text: "cd: brak takiego katalogu: \(arg)", isCommand: false, isError: true))
            }
            return
        }

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.currentDirectoryURL = dirURL
            proc.arguments = ["-c", rawCmd]

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                Task { @MainActor in
                    for line in outStr.split(separator: "\n", omittingEmptySubsequences: false) {
                        if !line.isEmpty {
                            self.outputLines.append(TerminalOutputLine(text: String(line), isCommand: false, isError: false))
                        }
                    }
                    for line in errStr.split(separator: "\n", omittingEmptySubsequences: false) {
                        if !line.isEmpty {
                            self.outputLines.append(TerminalOutputLine(text: String(line), isCommand: false, isError: true))
                        }
                    }
                    self.isRunning = false
                    FSearchIndex.shared.refreshDirectoryInIndex(dirURL.path)
                    self.activeTab.reloadDirectory()
                }
            } catch {
                Task { @MainActor in
                    self.outputLines.append(TerminalOutputLine(text: "Błąd wykonania: \(error.localizedDescription)", isCommand: false, isError: true))
                    self.isRunning = false
                }
            }
        }
    }
}
