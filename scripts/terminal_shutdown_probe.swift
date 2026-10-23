import SwiftUI
import AppKit
import Darwin

// Prepared once on main before App.main; never mutated afterward. A nonisolated
// emitter avoids changing the production delegate's actor annotations.
final class ProbeTerminationMarker: @unchecked Sendable {
    static let shared = ProbeTerminationMarker()
    private var fd: Int32 = -1
    private var bytes = [UInt8]()
    func prepare(fd: Int32, bytes: [UInt8]) {
        precondition(self.fd == -1)
        self.fd = fd; self.bytes = bytes
    }
    func emit() {
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }
}

// Compiled only into the separate probe; no normal application lifecycle changes.
@MainActor enum ShutdownProbe {
    private static var fd: Int32 = -1
    private static var token = ""
    private static var caseID = ""
    private static var command = ""
    private static var root = URL(fileURLWithPath: "/")
    private static var phase = "waiting"
    private static var launched = false
    private static var input = [UInt8]()
    private static var timer: DispatchSourceTimer?

    static func fail() -> Never { fatalError("shutdown-probe-fixed-failure") }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func canonical(_ path: String) -> URL { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL }
    static func send(_ kind: String) {
        let bytes = Array("\(kind) \(token) \(caseID)\n".utf8)
        let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == bytes.count else { fail() }
    }
    static func appeared(run: (String) -> Void) {
        guard !launched else { fail() }
        let state = AppState.shared
        guard phase == "waiting", state.activeTab.currentURL.resolvingSymlinksInPath().standardizedFileURL == root,
              state.rightPane.currentURL.resolvingSymlinksInPath().standardizedFileURL == root,
              !state.activeTab.wasRestoredFromSession, !state.activeTab.isSessionBrowsingPaused,
              !state.rightPane.wasRestoredFromSession, !state.rightPane.isSessionBrowsingPaused, !state.restoreSessionEnabled,
              FSearchIndex.shared.configuredRoots == [root.path], !FSearchIndex.shared.usePersistentMMapCache else { fail() }
        launched = true; phase = "running"
        run(command)
        send("STARTED")
    }
    static func disappeared() {
        if phase == "running" || phase == "waiting" { phase = "invalid"; send("PREMATURE") }
        else if phase == "hide" { send("HIDDEN") }
        // Quit-related disappearance is deliberately not required or attributed.
    }
    static func prepare() {
        guard Thread.isMainThread else { fail() }
        let env = ProcessInfo.processInfo.environment
        guard env["BF_PROBE_APPROVED_RUNNER"] == "1",
              let home = env["HOME"], env["CFFIXED_USER_HOME"] == home,
              let fixture = env["BETTERFINDER_TEST_ROOT"], let socketPath = env["BF_PROBE_APP_SOCKET"],
              let fixtureSocket = env["BF_PROBE_FIXTURE_SOCKET"], let helper = env["BF_PROBE_HELPER"],
              let nonce = env["BF_PROBE_NONCE"], let name = env["BF_PROBE_CASE"], let mode = env["BF_PROBE_MODE"],
              nonce.count == 32, name.count <= 32, ["default", "resistant"].contains(mode) else { fail() }
        guard canonical(NSHomeDirectory()) == canonical(home),
              canonical(FileManager.default.homeDirectoryForCurrentUser.path) == canonical(home),
              FileManager.default.fileExists(atPath: fixture) else { fail() }
        token = nonce; caseID = name; root = canonical(fixture)
        command = ["exec", quote(helper), quote(fixtureSocket), quote(nonce), quote(name), quote(mode), "fixture-v1"].joined(separator: " ")
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { fail() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketPath.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail() }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Private local listener is established before launch; fail closed on asynchronous connect.
        guard connected == 0 else { fail() }
        ProbeTerminationMarker.shared.prepare(fd: fd, bytes: Array("TERMINATED \(token) \(caseID)\n".utf8))
        send("APP")
        UserDefaults.standard.setVolatileDomain(["bf.restoreSession": false], forName: UserDefaults.argumentDomain)
        FSearchIndex.shared.configuredRoots = [root.path]
        FSearchIndex.shared.usePersistentMMapCache = false
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.setEventHandler { receive() }
        source.resume(); timer = source
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard phase == "waiting" else { fail() }
                AppState.shared.showTerminalDrawer = true
            }
        }
    }
    static func receive() {
        var bytes = [UInt8](repeating: 0, count: 256)
        let size = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        if size < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            fail()
        }
        guard size > 0 else { fail() }
        input.append(contentsOf: bytes.prefix(size))
        guard input.count <= 256, !input.contains(0), !input.contains(13) else { fail() }
        guard input.last == 10, input.filter({ $0 == 10 }).count == 1 else {
            if input.contains(10) { fail() }; return
        }
        guard let text = String(bytes: input.dropLast(), encoding: .utf8) else { fail() }
        input.removeAll(keepingCapacity: true)
        if text == "HIDE \(token) \(caseID)" {
            guard phase == "running" else { fail() }
            phase = "hide" // Set on the main thread before synchronous view mutation.
            send("HIDE"); AppState.shared.showTerminalDrawer = false
        } else if text == "QUIT \(token) \(caseID)" {
            guard phase == "running" || phase == "hide" else { fail() }
            phase = "quit"; send("QUIT")
            NSApp.terminate(nil)
        } else { fail() }
    }
}

@main struct TerminalShutdownProbe {
    @MainActor static func main() {
        ShutdownProbe.prepare()
        BetterFinderApp.main()
    }
}
