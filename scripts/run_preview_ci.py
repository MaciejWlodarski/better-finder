#!/usr/bin/env python3
"""Bounded, synthetic-only execution of the existing native preview harness.

This is not desktop capture, Accessibility automation, or a permission grant.
Run only on an ephemeral GitHub-hosted macOS runner after code gates pass.
"""
import os
import ctypes
import errno
import hashlib
import select
import threading
import time
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FILES = ('rename.png', 'light.png', 'search.png', 'compact.png', 'inspector.png', 'dual-pane.png', 'dark-icons.png', 'sidebar-full-light.png', 'sidebar-full-dark.png', 'sidebar-empty.png', 'sidebar-reordered.png', 'network-expanded-dark.png', 'network-expanded-light.png', 'columns.png', 'inspector-single.png', 'settings-short-light.png', 'settings-short-dark.png', 'new-folder.png', 'address-invalid.png', 'permission-banner.png', 'transient-error-narrow.png', 'trash-sidebar.png', 'terminal-default.png', 'terminal-min.png', 'terminal-running-min.png', 'terminal-max.png', 'terminal-tabs.png', 'terminal-many-tabs.png', 'terminal-empty.png', 'analysis.png', 'paused-dual.png', 'address-edit-left.png', 'address-edit-right.png')
MAX_BYTES = 8 * 1024 * 1024 - 2048  # Reserve 2 KiB for fixed verification; TOTAL <=8 MiB.
DEST = ROOT / ".build" / "previews-ci-artifact"


def last_stage(output):
    # File contents are untrusted: publish only exact fixed stage IDs, at most
    # 128 input bytes. Missing/unreadable markers must not expose raw exceptions.
    allowed = {
        "prepare-bundle", "compile-harness", "sign-harness", "launch-native",
        "native-entry", "check-ns-home", "check-file-manager-home",
        "create-fixture-directories", "write-fixture-files", "configure-defaults",
        "configure-index", "enter-app-main", "did-finish-launching",
        "activate-window", "native-assertions",
    }
    try:
        marker = output / "stage.txt"
        if marker.is_symlink():
            return "unavailable"
        with marker.open("rb") as stream:
            data = stream.read(129)
        if len(data) > 128:
            return "unavailable"
        stage = data.decode("ascii").strip()
        return stage if stage in allowed else "unavailable"
    except (OSError, ValueError):
        return "unavailable"


def log_evidence(path):
    """Return fixed evidence tags, never log text, paths, addresses or values.

    Inspect at most 128 KiB (head/tail) of this invocation's private log. Tags
    mean matching text was observed, not that a cause or missing GUI is proven.
    No raw log is retained or uploaded, including on classifier failure.
    """
    try:
        if path.is_symlink():
            return "unavailable"
        with path.open("rb") as stream:
            head = stream.read(65536)
            stream.seek(0, os.SEEK_END)
            length = stream.tell()
            if length > 65536:
                stream.seek(max(65536, length - 65536))
                tail = stream.read(65536)
            else:
                tail = b""
        text = (head + b"\n" + tail).decode("utf-8", errors="replace").lower()
    except (OSError, ValueError):
        return "unavailable"
    signatures = (
        ("test-preferences-fatal", ("could not create isolated test preferences",)),
        ("test-root-fatal", ("betterfinder_test_root must identify an isolated test directory",)),
        ("explicit-windowserver-connection-error", (
            "failed to connect to windowserver", "failed to connect to the windowserver",
            "unable to connect to window server", "unable to connect to the window server",
            "failed to establish the default connection to the windowserver")),
        ("explicit-main-thread-error", (
            "nsapplication must be initialized on the main thread",
            "app.main() must be called on the main thread")),
        ("uncaught-objective-c-exception", ("terminating app due to uncaught exception",)),
        ("swift-nil-unwrap", ("unexpectedly found nil while unwrapping an optional value",
                              "unexpectedly found nil while implicitly unwrapping an optional value")),
        ("swift-fatal-error", ("fatal error:",)),
        ("dispatch-queue-assertion-symbol", ("_dispatch_assert_queue_fail",)),
        ("application-registration-symbol", ("_registerapplication",)),
        ("appkit-main-symbol", ("nsapplicationmain",)),
        ("swiftui-main-symbol", ("swiftui.app.main",)),
    )
    tags = [tag for tag, needles in signatures if any(needle in text for needle in needles)][:6]
    # These are presence-only framework tokens, NOT a crash-frame attribution.
    frameworks = ("AppKit", "SwiftUI", "HIServices", "SkyLight", "CoreFoundation", "libdispatch", "libswiftCore")
    tags.extend("token-" + name for name in frameworks if name.lower() in text)
    return ",".join(tags[:10]) if tags else "no-known-signature"


class PreviewFailure(RuntimeError):
    """Only locally constructed fixed or strictly allowlisted diagnostics."""
    pass


CANCELLED = False
RETENTION_READY = False
CENSUS = None
END = 0.0
SOURCE_PINS = {
    'scripts/preview_app.sh': 'e2508373f2385a04cd29026a38926197d1b245efa19c18e9bfc5bd2eee3761df',
    'scripts/preview_app.swift': 'cf811394f0d838488bc83e1a6e9a23b36d7af5d9ac6c7db12872da28e04bd67c',
}


def checked(ok, tag):
    if not ok:
        raise PreviewFailure('Native preview ownership: ' + tag + '; no artifact published')


def check_sources():
    for relative, digest in SOURCE_PINS.items():
        path = ROOT / relative
        checked(not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(ROOT.resolve()), 'source-identity')
        checked(hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'source-identity')


def prepare_ownership():
    global RETENTION_READY, CENSUS
    RETENTION_READY = False
    checked(threading.active_count() == 1, 'single-thread-required')
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    signal.siginterrupt(signal.SIGCHLD, False)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGCHLD})
    checked(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, 'sigchld-contract')
    # Immediate private child proves waitable retention, not an arbitrary PID.
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    until = min(time.monotonic() + 2, END - 6)
    while time.monotonic() < until:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            checked(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, 'retention-preflight')
            RETENTION_READY = True
            break
        time.sleep(.005)
    checked(RETENTION_READY, 'retention-preflight')  # Never signal an unverified ID.
    checked(ctypes.sizeof(ctypes.c_int) == 4 and ctypes.sizeof(ctypes.c_int32) == 4, 'native-abi')
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    function = library.proc_listpgrppids
    function.argtypes = [ctypes.c_int32, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_int
    CENSUS = (library, function)


START_SHIM = r'''
import os, sys, signal, select, time
try:
    fd = int(sys.argv[1]); end = float(sys.argv[2]); argv = sys.argv[3:]
    if fd < 3 or argv not in (['/bin/zsh', 'scripts/preview_app.sh'], ['/usr/bin/true']): os._exit(120)
    os.set_inheritable(fd, False); os.set_blocking(fd, False)
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0: os._exit(121)
        try:
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready: os._exit(121)
            token = os.read(fd, 1)
        except (InterruptedError, BlockingIOError):
            continue
        if token != b'G': os._exit(122)
        break
    os.close(fd)
    for name in ('SIGPIPE', 'SIGXFZ', 'SIGXFSZ'):
        sig = getattr(signal, name, None)
        if sig is not None: signal.signal(sig, signal.SIG_DFL)
    if time.monotonic() >= end: os._exit(121)
    os.execv(argv[0], argv)
except BaseException:
    os._exit(123)
'''


class PreviewResources:
    def __init__(self):
        self.owners = []
        self.root = None
        self.staging = None
        self.uncertain = False

    def __enter__(self):
        self.root = Path(tempfile.mkdtemp(prefix='better-finder-preview-ci-'))
        return self.root

    def stage(self, payload):
        checked(not self.owners and not self.uncertain, 'unverified-cleanup')
        checked(not CANCELLED and time.monotonic() < END, 'artifact-budget-or-cancel')
        DEST.parent.mkdir(parents=True, exist_ok=True)
        self.staging = Path(tempfile.mkdtemp(prefix='.preview-pending-', dir=DEST.parent))
        for name, data in payload.items():
            (self.staging / name).write_bytes(data)

    def __exit__(self, kind, value, tb):
        errors = False
        for owner in list(self.owners):
            try: owner.cleanup()
            except BaseException: errors = True
        if self.owners or self.uncertain: errors = True
        if not errors and self.root is not None:
            try: shutil.rmtree(self.root); self.root = None
            except BaseException: errors = True; self.uncertain = True
        # Fixed upload directory appears only after complete disposal and writes.
        if self.staging is not None:
            if kind is None and not errors:
                try:
                    checked(not CANCELLED and time.monotonic() < END, 'artifact-budget-or-cancel')
                    checked(not DEST.exists(), 'artifact-already-exists')
                    self.staging.rename(DEST); self.staging = None
                except BaseException: errors = True
            if self.staging is not None:
                try: shutil.rmtree(self.staging); self.staging = None
                except BaseException: errors = True
        checked(not errors, 'final-cleanup-unverified')
        return False


class OwnedPreview:
    """Trusted synchronous session only; no arbitrary detached-tree claim."""
    def __init__(self, resources):
        self.resources = resources
        self.process = None
        self.queue = None
        self.gate_read = self.gate_write = None
        self.exit_seen = self.reaped = self.verified = self.uncertain = False
        self.attempted = self.cleanup_started = False
        self.code = None
        resources.owners.append(self)  # Before any allocation or partial launch.

    def close_fd(self, name):
        fd = getattr(self, name); setattr(self, name, None)
        if fd is not None:
            try: os.close(fd)
            except BaseException:
                self.uncertain = True
                raise

    def close_gates(self):
        errors = False
        for name in ('gate_read', 'gate_write'):
            try: self.close_fd(name)
            except BaseException: errors = True
        checked(not errors, 'gate-close-unverified')

    def launch(self, argv, env, log, hold=False):
        checked(RETENTION_READY and signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL and threading.active_count() == 1, 'retention-contract')
        checked(argv in (['/bin/zsh', 'scripts/preview_app.sh'], ['/usr/bin/true']), 'target-identity')
        checked(os.path.isabs(sys.executable) and signal.getsignal(signal.SIGPIPE) == signal.SIG_IGN, 'interpreter-contract')
        created = time.monotonic(); release_end = min(created + 1, END - 6); shim_end = min(created + 2, END - 6)
        checked(not CANCELLED and created < release_end, 'launch-budget')
        self.gate_read, self.gate_write = os.pipe()
        os.set_inheritable(self.gate_read, False); os.set_inheritable(self.gate_write, False)
        os.set_blocking(self.gate_write, False)
        self.attempted = True
        self.process = subprocess.Popen([sys.executable, '-I', '-S', '-c', START_SHIM,
                                        str(self.gate_read), repr(shim_end), *argv], cwd=ROOT, env=env,
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                        close_fds=True, pass_fds=(self.gate_read,), start_new_session=True)
        self.close_fd('gate_read')
        self.queue = select.kqueue()
        os.set_inheritable(self.queue.fileno(), False)
        event = select.kevent(self.process.pid, filter=select.KQ_FILTER_PROC,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                             fflags=select.KQ_NOTE_EXIT)
        self.events(self.queue.control([event], 1, 0))
        if hold:
            checked(argv == ['/usr/bin/true'], 'control-target')
            until = time.monotonic() + .05
            while time.monotonic() < until:
                checked(not self.observe() and not CANCELLED and time.monotonic() < release_end, 'gate-hold')
                time.sleep(.005)
        checked(not self.exit_seen and not CANCELLED and time.monotonic() < release_end, 'gate-release')
        checked(os.write(self.gate_write, b'G') == 1, 'gate-release')
        self.close_fd('gate_write')

    def events(self, events):
        for event in events:
            checked(event.ident == self.process.pid and event.filter == select.KQ_FILTER_PROC, 'event-identity')
            checked(not event.flags & select.KQ_EV_ERROR, 'event-error')
            checked(event.fflags & select.KQ_NOTE_EXIT, 'event-missing-exit')
            self.exit_seen = True

    def observe(self):
        checked(not self.reaped, 'already-reaped')
        if self.queue is not None: self.events(self.queue.control([], 1, 0))
        return self.exit_seen

    def census(self):
        # Return multiple only for complete/saturated valid member snapshots.
        # Unknown/error is distinct and sticky, never upgraded by a later sample.
        if (self.reaped or not self.exit_seen or self.process is None or CENSUS is None or
            not RETENTION_READY or signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL or
            threading.active_count() != 1): return 'unknown'
        pid = self.process.pid
        if type(pid) is not int or not 1 < pid <= 2147483647: return 'unknown'
        values = (ctypes.c_int * 2)(0, 0)
        try:
            ctypes.set_errno(0)
            count = CENSUS[1](pid, values, ctypes.sizeof(values))
            error = ctypes.get_errno()
        except BaseException: return 'unknown'
        if error or type(count) is not int: return 'unknown'
        if count == 1 and values[0] == pid: return 'singleton'
        if count == 2 and all(x > 1 for x in values) and values[0] != values[1]: return 'multiple'
        return 'unknown'

    def wait_exit(self, deadline):
        while not self.observe():
            checked(not CANCELLED and time.monotonic() < deadline, 'run-timeout-or-cancel')
            time.sleep(.01)
        checked(not CANCELLED and time.monotonic() < deadline, 'run-timeout-or-cancel')

    def cleanup(self):
        # Every call closes still-owned descriptors, but never signals after reap.
        try: self.close_gates()
        except BaseException: self.uncertain = True
        if self.process is None:
            if self.attempted: self.uncertain = True
            else: self.verified = True
        elif not self.reaped and not self.cleanup_started:
            self.cleanup_started = True
            for sig, grace in ((signal.SIGTERM, .15), (signal.SIGKILL, .05)):
                try: os.killpg(self.process.pid, sig)
                except OSError as error:
                    # EPERM only resolves from already retained exact singleton.
                    if error.errno == errno.EPERM:
                        try:
                            self.observe()  # Retain NOTE_EXIT; never wait/poll here.
                            resolved = self.census() == 'singleton'
                        except BaseException: resolved = False
                        if not resolved: self.uncertain = True
                    else: self.uncertain = True
                until = min(time.monotonic() + grace, END)
                while time.monotonic() < until: time.sleep(.005)
            proof = False
            until = min(time.monotonic() + 3, END - 1)
            while time.monotonic() < until and not self.uncertain:
                try: exited = self.observe()
                except BaseException: self.uncertain = True; break
                if exited:
                    state = self.census()
                    if state == 'singleton': proof = True; break
                    if state == 'unknown': self.uncertain = True; break
                time.sleep(.01)
            self.verified = proof and not self.uncertain
            # Reap only after all signaling/proof attempts; never infer group
            # completion merely from this wait. Uncertainty remains sticky.
            try:
                checked(time.monotonic() < END, 'cleanup-deadline')
                self.code = self.process.wait(timeout=min(1, END - time.monotonic()))
                self.reaped = True
            except BaseException: self.uncertain = True
        elif not self.verified:
            self.uncertain = True
        if self.queue is not None:
            queue = self.queue; self.queue = None  # No blind repeated descriptor close.
            try: queue.close()
            except BaseException: self.uncertain = True
        safe = self.verified and not self.uncertain and (self.process is None or self.reaped)
        if safe and self in self.resources.owners: self.resources.owners.remove(self)
        checked(safe, 'group-cleanup-unverified')


def gate_control(resources, env, log):
    owner = OwnedPreview(resources)
    end = min(time.monotonic() + 2, END - 6)
    try:
        owner.launch(['/usr/bin/true'], env, log, hold=True)
        owner.wait_exit(end)
        owner.cleanup()
        checked(owner.code == 0, 'gate-control-status')
    finally:
        owner.cleanup()


def stop(process):
    if process is not None: process.cleanup()


def interrupted(signum, frame):
    global CANCELLED
    CANCELLED = True


def main():
    global END, CANCELLED
    END = time.monotonic() + 240
    CANCELLED = False
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise PreviewFailure("Use only an ephemeral GitHub-hosted macOS runner")
    if DEST.exists():
        raise PreviewFailure("Artifact directory already exists; use a fresh checkout")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    check_sources()
    prepare_ownership()
    resources = PreviewResources()
    with resources as sandbox:
        home, output = sandbox / "home", sandbox / "renders"
        scratch = sandbox / "tmp"
        for directory in (home, output, scratch):
            directory.mkdir(mode=0o700)
        env = dict(os.environ)
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(scratch) + "/",
                   BETTERFINDER_PREVIEW_CI="1", BETTERFINDER_PREVIEW_OUTPUT=str(output),
                   BETTERFINDER_TEST_ROOT=str(output / "Pracownia"))
        process = None
        try:
            # Do not publish compiler/runtime logs or environment values.
            log_path = sandbox / "native.log"
            with log_path.open("wb") as log:
                gate_control(resources, env, log)
                process = OwnedPreview(resources)
                process.launch(['/bin/zsh', 'scripts/preview_app.sh'], env, log)
                process.wait_exit(END - 6)
                process.cleanup()
                code = process.code
                if code:
                    marker = output / "verification.txt"
                    allowed = {
                        'broad Trash must not navigate',
                        'broad address Escape preserves both panes',
                        'broad address editor focused',
                        'broad address selects correct pane path',
                        'broad empty terminal retains hide',
                        'broad folder sheet exposed',
                        'broad invalid address retains navigation',
                        'broad long synthetic directory created',
                        'broad manual favorite order',
                        'broad network disclosure action',
                        'broad network disclosure expanded',
                        'broad network disclosure exposed',
                        'broad network grouping and unknown capacity',
                        'broad panes remain paused',
                        'broad permission failure preserves folder',
                        'broad settings sheet exposed',
                        'broad synthetic Trash handoff',
                        'broad synthetic server identity',
                        'broad terminal default height',
                        'broad terminal maximum clamps',
                        'broad terminal minimum height',
                        'broad terminal resize action',
                        'broad terminal resize exposed',
                        'broad terminal running Stop exposed',
                        'broad terminal tab limit idle',
                        'broad terminal tabs created',
                        'broad terminal tabs idle and independent',
                        'broad terminal tabs retain selection',
                        'broad transient failure preserves folder',
                        "bootstrap App.main requires the main thread",
                        "bootstrap output path missing or invalid", "bootstrap CI mode missing",
                        "bootstrap fixed home missing", "bootstrap HOME differs from fixed home",
                        "bootstrap NSHomeDirectory isolation mismatch",
                        "bootstrap FileManager home isolation mismatch", "bootstrap fixture root mismatch",
                        "bootstrap fixture directory creation failed", "bootstrap fixture file write failed",
                        "no app window after launch", "file pane must receive initial keyboard focus",
                        "Down must select a file", "Shift-Down must extend selection",
                        "Return must open the native rename sheet", "reopened tab must restore the closed tab",
                        "search must match the fixture", "programmatic search-focus trigger must reach search text",
                        "Command-A in search must select text", "text editing must not select underlying files",
                        "native preview timed out; a graphical macOS session is required",
                        "missing window content", "cannot render window", "cannot encode window render",
                        "cannot write window render", "both panes must stay in the synthetic fixture at startup",
                        "index roots must stay isolated",
                        "keyboard fixture must be freshly loaded rather than session-paused",
                        "keyboard fixture must expose all nine synthetic entries",
                        "keyboard fixture must start without preselected items",
                        "keyboard event target must be the key window",
                        "cannot construct native key event",
                        "native key event must resolve to the target window",
                    }
                    allowed.update({
                        "broad network exposure: fixture missing",
                        "broad network exposure: exact label in view-seeded hierarchy",
                        "broad network exposure: fixture label differs",
                        "broad network exposure: traversal capped",
                        "broad network exposure: fixture present without accessible label",
                    })
                    if marker.is_file() and marker.stat().st_size <= 2048:
                        message = marker.read_text().removeprefix("FAIL: ").strip()
                        if message in allowed:
                            raise PreviewFailure("Native preview assertion: " + message)
                    # Harness-only compilation/bootstrap failures are distinct from
                    # production build/tests; retain the last fixed stage, not logs.
                    raise PreviewFailure("Native preview failed (exit %d); last stage: %s; fixed log evidence: %s; no artifact published" % (code, last_stage(output), log_evidence(log_path)))
        finally:
            stop(process)
        verification = output / "verification.txt"
        if not verification.is_file() or verification.stat().st_size > 2048 or not verification.read_text().startswith("PASS native window,"):
            raise PreviewFailure("Missing native preview PASS marker")
        total = 0
        for name in FILES:
            file = output / name
            if file.is_symlink() or not file.is_file():
                raise PreviewFailure("Missing expected native render: " + name)
            size = file.stat().st_size
            total += size
            if size < 24 or total > MAX_BYTES:
                raise PreviewFailure("Native renders exceed the 8 MiB artifact bound")
            with file.open("rb") as stream:
                header = stream.read(24)
            if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                raise PreviewFailure("Invalid native PNG: " + name)
            width, height = struct.unpack(">II", header[16:24])
            if not (1 <= width <= 3000 and 1 <= height <= 2200):
                raise PreviewFailure("Unexpected render dimensions: " + name)
        payload = {name: (output / name).read_bytes() for name in FILES}
        # Deliberately fixed verification text: never copy logs or environment paths.
        payload["verification.txt"] = (
            "PASS: native app window and in-process keyboard assertions using application-level synthetic-fixture isolation.\n"
            "33 native AppKit view renders from synthetic fixtures.\n"
            "Running terminal scene is test-only presentation; no command executes and Stop behavior is not proven.\n"
            "Test startup uses synthetic pane roots and an isolated preference suite; mounted-volume discovery and automatic indexing are disabled.\n"
            "Not an OS sandbox or proof that all macOS global/preference accesses are blocked; an ephemeral hosted runner is required.\n"
            "In-process native text-key and accessibility actions only; no desktop capture, global keyboard injection or OS permission automation.\n"
            "Not proof of global menu shortcuts, mouse drag, VoiceOver, rename submission, persistence, real network discovery, external drag/drop, Quick Look or thumbnail correctness.\n").encode("utf8")
        resources.stage(payload)
    print("PASS: 33 isolated native view renders; PNG payload %d bytes; total artifact including verification is bounded to 8 MiB." % total)


def cli():
    try:
        main()
        return 0
    except PreviewFailure as error:
        # This type is constructed only from fixed local tags/allowlisted text.
        print("FAIL: " + str(error), file=sys.stderr)
        return 1
    except BaseException:
        # Never stringify arbitrary library exceptions or emit raw tracebacks.
        print("FAIL: native preview failed unexpectedly; no artifact published", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(cli())
