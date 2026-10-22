import SwiftUI
import AppKit
import Darwin

struct TerminalCommandResult: Sendable {
    let output: String
    /// Exit code, or 128 + terminating signal (shell convention), never raw waitpid bits.
    let status: Int32
    let wasCancelled: Bool
    let wasTruncated: Bool
    /// Diagnostic count used to verify bounded waiting after pipe EOF.
    let waitIterations: Int
}

/// One bounded merged output pipe removes the stdout/stderr dependency cycle.
/// A dedicated POSIX process group allows cancellation of the shell and ordinary
/// pipeline children while the session is running. Background jobs may outlive a
/// completed shell; deliberately detached children can also leave its process group.
final class TerminalCommandSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let outputLimit: Int
    init(outputLimit: Int = 1_048_576) { self.outputLimit = max(1, outputLimit) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(command: String, directory: URL, shell: String = "/bin/zsh") throws -> TerminalCommandResult {
        if isCancelled { return TerminalCommandResult(output: "", status: 0, wasCancelled: true, wasTruncated: false, waitIterations: 0) }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixError(errno) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { Darwin.close(readFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionError = posix_spawn_file_actions_init(&actions)
        guard actionError == 0 else { Darwin.close(writeFD); throw posixError(actionError) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        actionError = posix_spawnattr_init(&attributes)
        guard actionError == 0 else { Darwin.close(writeFD); throw posixError(actionError) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Do not expose app stdin; noninteractive readers must see EOF.
        let setupErrors = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, readFD),
            posix_spawn_file_actions_addclose(&actions, writeFD),
            posix_spawn_file_actions_addchdir_np(&actions, directory.path),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0)
        ]
        if let error = setupErrors.first(where: { $0 != 0 }) { Darwin.close(writeFD); throw posixError(error) }
        var argv = [strdup(shell), strdup("-c"), strdup(command), nil]
        defer { for pointer in argv { if let pointer { free(pointer) } } }
        // Own a stable environment snapshot through the spawn call instead of
        // relying on the C environment accessor unavailable in this Swift toolchain.
        var environment: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in environment { if let pointer { free(pointer) } } }
        for (key, value) in ProcessInfo.processInfo.environment {
            guard let entry = strdup("\(key)=\(value)") else {
                Darwin.close(writeFD)
                throw posixError(ENOMEM)
            }
            environment.append(entry)
        }
        environment.append(nil)
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, shell, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        Darwin.close(writeFD)
        guard spawnError == 0 else { throw posixError(spawnError) }
        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let savedError = errno
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw posixError(savedError)
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var status: Int32 = 0
        var truncated = false
        var cancellationStarted: UInt64?
        var killed = false
        var exited = false
        var outputEOF = false
        var waitIterations = 0
        while !exited {
            if isCancelled && cancellationStarted == nil {
                cancellationStarted = DispatchTime.now().uptimeNanoseconds
                kill(-pid, SIGTERM)
            }
            if let started = cancellationStarted, !killed,
               DispatchTime.now().uptimeNanoseconds - started >= 500_000_000 {
                // Escalate before reaping the leader, so its group ID cannot be reused.
                kill(-pid, SIGKILL)
                killed = true
            }
            // POLLHUP stays ready forever after EOF. Ignore that descriptor and
            // retain the bounded 50ms wait while the child remains alive.
            waitIterations += 1
            var event = pollfd(fd: outputEOF ? -1 : readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&event, 1, 50)
            // Drain in bounded chunks even after the display limit is reached.
            for _ in 0..<(outputEOF ? 0 : 32) {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
                if count == 0 { outputEOF = true; break }
                if count < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { outputEOF = true }
                    break
                }
                let remaining = max(0, outputLimit - output.count)
                output.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { truncated = true }
            }
            // Keep the shell unreaped until cancellation escalation has finished.
            if cancellationStarted == nil || killed {
                let waited = waitpid(pid, &status, WNOHANG)
                exited = waited == pid || (waited < 0 && errno == ECHILD)
            }
        }
        // Consume bytes already buffered, without waiting for EOF from detached children.
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
            if count <= 0 { break }
            let remaining = max(0, outputLimit - output.count)
            output.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining { truncated = true }
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return TerminalCommandResult(output: String(decoding: output, as: UTF8.self), status: exitCode,
            wasCancelled: isCancelled, wasTruncated: truncated, waitIterations: waitIterations)
    }

    private func posixError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}

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
    @ViewState private var session: TerminalCommandSession?
    @FocusState private var isInputFocused: Bool

    private let quickCommands = ["git status -sb", "ls -la", "du -sh * | sort -h", "git log -n 5 --oneline"]

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FinderUI.rowSpacing) {
                Label("Terminal", systemImage: "terminal")
                    .font(FinderUI.titleFont)
                    .fixedSize()

                Text(activeTab.currentURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(FinderUI.detailFont.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .help(activeTab.currentURL.path)
                    .accessibilityLabel("Bieżący folder: \(activeTab.currentURL.path)")

                terminalIconButton("Wyczyść wyjście terminala", icon: "trash") {
                    outputLines.removeAll()
                }
                .disabled(outputLines.isEmpty)

                terminalIconButton("Otwórz folder w zewnętrznym terminalu", icon: "arrow.up.forward.app") {
                    FileOperationsManager.shared.openInTerminal(at: activeTab.currentURL)
                }

                terminalIconButton("Ukryj terminal (Ctrl+`)", icon: "xmark") {
                    session?.cancel()
                    appState.showTerminalDrawer = false
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, FinderUI.compactSpacing)
            .background(Color(nsColor: .windowBackgroundColor))

            // A separate horizontal strip keeps shortcuts from squeezing the path and controls.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FinderUI.compactSpacing) {
                    ForEach(quickCommands, id: \.self) { cmd in
                        Button(cmd) { executeCommand(cmd) }
                            .font(FinderUI.detailFont.monospaced())
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRunning)
                            .help("Uruchom w bieżącym folderze: \(cmd)")
                            .accessibilityLabel("Uruchom polecenie: \(cmd)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, FinderUI.compactSpacing)
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                        if outputLines.isEmpty {
                            Text(isRunning ? "Polecenie jest wykonywane…" : "Brak wyjścia. Wpisz polecenie poniżej lub wybierz skrót.")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(outputLines) { line in
                            Text(line.text)
                                .font(FinderUI.detailFont.monospaced().weight(line.isCommand ? .semibold : .regular))
                                .foregroundStyle(
                                    line.isCommand
                                    ? Color.accentColor
                                    : (line.isError ? Color.red : Color.primary)
                                )
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, FinderUI.rowSpacing)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: outputLines.count) { _, _ in
                    if let last = outputLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: FinderUI.rowSpacing) {
                Text("\(activeTab.currentURL.lastPathComponent) %")
                    .font(FinderUI.detailFont.monospaced().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 100, alignment: .leading)
                    .help(activeTab.currentURL.path)
                    .accessibilityHidden(true)

                TextField("Wpisz polecenie zsh…", text: $commandInput)
                    .textFieldStyle(.plain)
                    .font(FinderUI.bodyFont.monospaced())
                    .focused($isInputFocused)
                    .disabled(isRunning)
                    .accessibilityLabel("Polecenie terminala")
                    .help("Naciśnij Return, aby uruchomić polecenie w bieżącym folderze. Polecenia interaktywne wymagają zewnętrznego terminala.")
                    .onSubmit {
                        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !isRunning, !cmd.isEmpty else { return }
                        commandInput = ""
                        executeCommand(cmd)
                    }

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Wykonywanie polecenia")
                    Button("Przerwij") { session?.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Przerwij bieżące polecenie")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, FinderUI.rowSpacing)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(height: 220)
        .onAppear { isInputFocused = true }
        .onDisappear {
            session?.cancel()
            session = nil
            isRunning = false
        }
    }

    private func terminalIconButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(FinderUI.detailFont)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func executeCommand(_ rawCmd: String) {
        guard !isRunning else { return }
        let dirURL = activeTab.currentURL
        outputLines.append(TerminalOutputLine(
            text: "[\(dirURL.lastPathComponent)] % \(rawCmd)",
            isCommand: true,
            isError: false
        ))
        commandHistory.append(rawCmd)
        commandHistory = Array(commandHistory.suffix(100))
        outputLines = Array(outputLines.suffix(2_000))

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
        let current = TerminalCommandSession()
        session = current
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try current.run(command: rawCmd, directory: dirURL)
                Task { @MainActor in
                    guard self.session === current else { return }
                    // stdout/stderr are intentionally merged in their observed arrival order.
                    for line in result.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(2_000) {
                        self.outputLines.append(TerminalOutputLine(text: String(line), isCommand: false, isError: false))
                    }
                    if result.wasTruncated {
                        self.outputLines.append(TerminalOutputLine(text: "[Wyjście ograniczone do 1 MiB; dalsze dane odczytano i pominięto.]", isCommand: false, isError: false))
                    }
                    if result.wasCancelled || result.status != 0 {
                        self.outputLines.append(TerminalOutputLine(text: result.wasCancelled ? "[Polecenie przerwane]" : "[Polecenie zakończone błędem]", isCommand: false, isError: true))
                    }
                    self.outputLines = Array(self.outputLines.suffix(2_000))
                    self.isRunning = false
                    self.session = nil
                    FSearchIndex.shared.enqueueDirectoryRefresh(dirURL.path)
                    if self.activeTab.currentURL.path == dirURL.path { self.activeTab.reloadDirectory() }
                }
            } catch {
                Task { @MainActor in
                    guard self.session === current else { return }
                    self.outputLines.append(TerminalOutputLine(text: "Błąd wykonania: \(error.localizedDescription)", isCommand: false, isError: true))
                    self.isRunning = false
                    self.session = nil
                }
            }
        }
    }
}
