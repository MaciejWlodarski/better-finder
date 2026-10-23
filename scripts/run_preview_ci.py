#!/usr/bin/env python3
"""Bounded, synthetic-only execution of the existing native preview harness.

Only the retained synthetic app window may be captured; no full-screen capture,
global Accessibility automation, or permission grant.
Run only on an ephemeral GitHub-hosted macOS runner after code gates pass.
"""
import os
import json
import re
import stat
import secrets
import re
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
    # Only compiler error headers for this repository's fixed synthetic harness.
    # Never emit source excerpts, arbitrary file names, quoted values or paths.
    compiler = []
    for match in re.finditer(r"(?:^|\n)(?:[^\n]*[/\\])?preview_app\.swift:([0-9]{1,5}):([0-9]{1,5}): error: ([^\n]{1,1000})", text):
        line, column = int(match.group(1)), int(match.group(2))
        if not (1 <= line <= 10000 and 1 <= column <= 10000):
            continue
        message = match.group(3)
        public_symbols = {"string", "string?", "any", "anyobject", "nsview", "nswindow",
                          "nsaccessibilityprotocol", "accessibilitylabel", "accessibilitychildren",
                          "objectidentifier", "appstate", "networkservergroups", "contentview",
                          "subviews", "mainactor", "nativepreview", "int", "bool"}
        public_symbols.update({"arrayslice<nsview>", "[any]", "[nsview]", "arrayslice<any>"})
        symbols = [part.group(1) or part.group(2) or ""
                   for part in re.finditer(r"'([^']*)'|\"([^\"]*)\"", message)]
        symbols = [symbol for symbol in symbols if symbol in public_symbols][:4]
        categories = (
            ("cannot-convert", ("cannot convert", "requires the types", "requires that")),
            ("no-exact-matches", ("no exact matches",)),
            ("missing-member", ("has no member",)),
            ("missing-symbol", ("cannot find",)),
            ("not-callable", ("cannot call value",)),
            ("optional-unwrapping", ("must be unwrapped",)),
            ("ambiguous-expression", ("ambiguous",)),
            ("typecheck-complexity", ("unable to type-check",)),
            ("actor-isolation", ("actor-isolated", "main actor",)),
        )
        category = next((tag for tag, needles in categories if any(needle in message for needle in needles)), "other")
        compiler.append("preview.swift:%d:%d:%s:symbols=%s" % (line, column, category, ",".join(symbols) or "none"))
        if len(compiler) == 8:
            break
    if compiler:
        return "compiler-errors: " + " | ".join(compiler)
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


# One own-window failure image, never a successful33-scene replacement.
DIAG_DEST = ROOT / '.build' / 'previews-ci-diagnostic'
DIAG_PNG = 'diagnostic-network-disclosure.png'
DIAG_LIMIT = 1024 * 1024  # Total PNG plus reconstructed metadata, stricter than2MiB.
DIAG_FAILURES = {
    'broad network exposure: fixture missing',
    'broad network exposure: exact label in view-seeded hierarchy',
    'broad network exposure: fixture label differs',
    'broad network exposure: traversal capped',
    'broad network exposure: fixture present without accessible label',
    'broad network exposure: exact native title without label',
}


class DiagnosticPreviewFailure(PreviewFailure):
    """Exact network selector failure with validated synthetic diagnostic only."""
    pass


def bounded_regular(path, limit):
    # No symlink or device/pipe; read at most the fixed bound, never raw paths.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        checked(stat.S_ISREG(info.st_mode) and 0 <= info.st_size <= limit, 'diagnostic-file-bound')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(limit + 1)
        checked(len(data) <= limit and len(data) == info.st_size, 'diagnostic-file-bound')
        return data
    finally:
        os.close(fd)


def diagnostic_payload(output, failure):
    checked(failure in DIAG_FAILURES, 'diagnostic-category')
    png = bounded_regular(output / DIAG_PNG, DIAG_LIMIT)
    checked(len(png) >= 24 and png[:8] == b'\x89PNG\r\n\x1a\n' and png[12:16] == b'IHDR', 'diagnostic-png')
    width, height = struct.unpack('>II', png[16:24])
    checked(1 <= width <= 3000 and 1 <= height <= 2200, 'diagnostic-dimensions')
    raw = bounded_regular(output / 'diagnostic-network-ax.json', 1024)
    # Reject duplicate JSON keys rather than silently keeping the last one.
    def pairs(values):
        result = {}
        for key, value in values:
            checked(key not in result, 'diagnostic-schema')
            result[key] = value
        return result
    data = json.loads(raw, object_pairs_hook=pairs)
    flags = {'sidebar', 'favorite', 'tag', 'exactLabel', 'exactTitle', 'truncated'}
    checked(type(data) is dict and set(data) == flags | {'visited'}, 'diagnostic-schema')
    checked(all(type(data[key]) is bool for key in flags), 'diagnostic-schema')
    checked(type(data['visited']) is int and 0 <= data['visited'] <= 2048, 'diagnostic-schema')
    head = os.environ.get('BF_PREVIEW_HEAD_SHA', '')
    run = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    checked(re.fullmatch('[0-9a-f]{40}', head) is not None and
            re.fullmatch('[1-9][0-9]{0,19}', run) is not None and
            re.fullmatch('[1-9][0-9]{0,9}', attempt) is not None, 'diagnostic-provenance')
    metadata = {'schema': 1, 'kind': 'synthetic-ui-failure', 'success': False,
                'failure_category': failure, 'head_sha': head, 'run_id': run,
                'run_attempt': attempt, 'ax': data}
    encoded = (json.dumps(metadata, sort_keys=True, separators=(',', ':')) + '\n').encode('ascii')
    checked(len(encoded) <= 2048 and len(png) + len(encoded) <= DIAG_LIMIT, 'diagnostic-total-bound')
    return {DIAG_PNG: png, 'diagnostic.json': encoded}


def emit_diagnostic_ready():
    # Hosted Actions command file only. Never serialize its private pathname.
    path = os.environ.get('GITHUB_OUTPUT', '')
    checked(os.path.isabs(path), 'diagnostic-output-unavailable')
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        checked(stat.S_ISREG(os.fstat(fd).st_mode), 'diagnostic-output-unavailable')
        token = b'diagnostic_ready=true\n'
        checked(os.write(fd, token) == len(token), 'diagnostic-output-unavailable')
    finally:
        os.close(fd)


CANCELLED = False
RETENTION_READY = False
CENSUS = None
END = 0.0
SOURCE_PINS = {
    'scripts/preview_app.sh': '5d2c32aabf0ad60fa5bd7504a83f1c190b32a3c8a9c9a499fa0acc4c45fff998',
    'scripts/preview_app.swift': '7ad5281e77b79ccdd061c57f1394057d33a738f0777e91c428532a7a44307f4a',
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


def target_valid(argv, env):
    if argv in (['/bin/zsh', 'scripts/preview_app.sh'], ['/usr/bin/true']): return True
    return (len(argv) == 6 and argv[:4] == ['/usr/sbin/screencapture', '-x', '-o', '-l']
            and re.fullmatch(r'[1-9][0-9]{0,9}', argv[4]) is not None
            and int(argv[4]) <= 2147483647
            and argv[5] in [str(Path(env.get('BETTERFINDER_PREVIEW_OUTPUT', '')) / ('composited-' + name)) for name in FILES]
            and os.path.isabs(env.get('BETTERFINDER_PREVIEW_OUTPUT', '')))


START_SHIM = r'''
import os, sys, signal, select, time, re
try:
    fd = int(sys.argv[1]); end = float(sys.argv[2]); argv = sys.argv[3:]
    fixed = argv in (['/bin/zsh', 'scripts/preview_app.sh'], ['/usr/bin/true'])
    names = SCENE_NAMES
    capture = (len(argv) == 6 and argv[:4] == ['/usr/sbin/screencapture', '-x', '-o', '-l']
        and re.fullmatch(r'[1-9][0-9]{0,9}', argv[4]) is not None and int(argv[4]) <= 2147483647
        and os.path.isabs(os.environ.get('BETTERFINDER_PREVIEW_OUTPUT', ''))
        and argv[5] in [os.path.join(os.environ['BETTERFINDER_PREVIEW_OUTPUT'], 'composited-' + name) for name in names])
    if fd < 3 or not (fixed or capture): os._exit(120)
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

START_SHIM = START_SHIM.replace('SCENE_NAMES', repr(FILES))

class PreviewResources:
    def __init__(self):
        self.owners = []
        self.root = None
        self.staging = None
        self.uncertain = False
        self.diagnostic = False

    def __enter__(self):
        self.root = Path(tempfile.mkdtemp(prefix='better-finder-preview-ci-'))
        return self.root

    def stage(self, payload, diagnostic=False):
        checked(not self.owners and not self.uncertain, 'unverified-cleanup')
        checked(not CANCELLED and time.monotonic() < END, 'artifact-budget-or-cancel')
        checked(self.staging is None, "artifact-already-staged")
        self.diagnostic = diagnostic
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
            eligible = (kind is None and not self.diagnostic) or (kind is DiagnosticPreviewFailure and self.diagnostic)
            if eligible and not errors:
                try:
                    checked(not CANCELLED and time.monotonic() < END, 'artifact-budget-or-cancel')
                    destination = DIAG_DEST if self.diagnostic else DEST
                    checked(not destination.exists(), 'artifact-already-exists')
                    self.staging.rename(destination); self.staging = None
                    if self.diagnostic:
                        try:
                            checked(not CANCELLED and time.monotonic() < END, 'artifact-budget-or-cancel')
                            emit_diagnostic_ready()
                        except BaseException:
                            shutil.rmtree(destination)  # Only the directory just committed by us.
                            raise
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
        self.deadline = None
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

    def launch(self, argv, env, log, hold=False, deadline=None):
        checked(RETENTION_READY and signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL and threading.active_count() == 1, 'retention-contract')
        checked(target_valid(argv, env), 'target-identity')
        checked(os.path.isabs(sys.executable) and signal.getsignal(signal.SIGPIPE) == signal.SIG_IGN, 'interpreter-contract')
        created = time.monotonic(); release_end = min(created + 1, END - 6); shim_end = min(created + 2, END - 6)
        if deadline is not None:
            release_end = min(release_end, deadline); shim_end = min(shim_end, deadline)
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
        cleanup_end = min(END, self.deadline) if self.deadline is not None else END
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
                until = min(time.monotonic() + grace, cleanup_end)
                while time.monotonic() < until: time.sleep(.005)
            proof = False
            until = min(time.monotonic() + 3, cleanup_end - (.1 if self.deadline is not None else 1))
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
                checked(time.monotonic() < cleanup_end, 'cleanup-deadline')
                self.code = self.process.wait(timeout=min(1, cleanup_end - time.monotonic()))
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


class CaptureService:
    """Pinned Swift lifetime assurance on ephemeral runner, not atomic OS ownership."""
    def __init__(self, resources, preview, output, env, log, token):
        self.resources, self.preview, self.output = resources, preview, output
        self.env, self.log, self.token = env, log, token
        self.sequence = 0
        self.pid = None
        self.seen = set()
        self.composited = []
        self.disabled = False
        self.spent = 0.0

    def app_alive(self):
        # Targeted bound PID only. No enumeration or signaling. The retained
        # shell may outlive the Swift app while completing its own trap/marker.
        if self.pid is None or self.preview.observe(): return False
        try: return os.getpgid(self.pid) == self.preview.process.pid
        except OSError: return False

    def service(self):
        request = self.output / 'capture-request.json'
        if not request.exists() and not request.is_symlink(): return
        checked(not CANCELLED and time.monotonic() < END - 6, 'capture-budget')
        def pairs(values):
            result = {}
            for key, value in values:
                checked(key not in result, 'capture-request-schema')
                result[key] = value
            return result
        data = json.loads(bounded_regular(request, 1024), object_pairs_hook=pairs)
        checked(type(data) is dict and set(data) == {'scene','window','pid','sequence','token'}, 'capture-request-schema')
        scene, window, pid = data['scene'], data['window'], data['pid']
        checked(type(scene) is str and scene in FILES and scene not in self.seen, 'capture-scene')
        checked(type(window) is int and 0 < window <= 2147483647, 'capture-window')
        checked(type(pid) is int and 1 < pid <= 2147483647, 'capture-app-pid')
        checked(type(data['sequence']) is int and data['sequence'] == self.sequence + 1, 'capture-sequence')
        checked(type(data['token']) is str and data['token'] == self.token, 'capture-token')
        checked(not self.preview.observe(), 'capture-preview-exited')
        checked(os.getpgid(pid) == self.preview.process.pid, 'capture-app-group')
        checked(self.pid is None or self.pid == pid, 'capture-app-identity')
        self.pid = pid; self.sequence += 1; self.seen.add(scene)
        request.unlink()
        destination = self.output / ('composited-' + scene)
        checked(not destination.exists() and not destination.is_symlink(), 'capture-output-exists')
        status = 'unsupported'
        if not self.disabled and 10 - self.spent >= 2:
            begin = time.monotonic()
            end = min(begin + 2, END - 6)
            checked(end - begin >= 2, 'capture-budget')
            owner = OwnedPreview(self.resources)
            owner.deadline = end
            completed = False
            try:
                owner.launch(['/usr/sbin/screencapture','-x','-o','-l',str(window),str(destination)],
                             self.env, self.log, deadline=end - .5)
                while time.monotonic() < end - .5 and not CANCELLED:
                    if self.preview.observe(): break
                    if owner.observe(): completed = True; break
                    time.sleep(.01)
            finally:
                owner.cleanup()  # Unverified cleanup raises, never unsupported.
                self.spent += time.monotonic() - begin
            checked(not CANCELLED and time.monotonic() < end, 'capture-budget-or-cancel')
            if (completed and owner.code == 0 and self.app_alive()
                    and destination.exists() and not destination.is_symlink()):
                # Content is still synthetic; only fixed PNG format/size accepted.
                try:
                    png = bounded_regular(destination, MAX_BYTES)
                    checked(len(png) >= 24 and png[:8] == b'\x89PNG\r\n\x1a\n' and png[12:16] == b'IHDR', 'capture-png')
                    width, height = struct.unpack('>II', png[16:24])
                    checked(1 <= width <= 3000 and 1 <= height <= 2200, 'capture-dimensions')
                    status = 'composited'
                except PreviewFailure:
                    status = 'unsupported'
        if status != 'composited':
            self.disabled = True
            if destination.exists() or destination.is_symlink(): destination.unlink()
        else:
            self.composited.append(scene)
        # App exit observed through service always discards pixels. No claim of
        # atomic crash-proof ID ownership between these checks and native capture.
        if not self.app_alive():
            status = 'unsupported'; self.disabled = True
            if scene in self.composited: self.composited.remove(scene)
            if destination.exists() or destination.is_symlink(): destination.unlink()
        checked(not CANCELLED and time.monotonic() < END - 6, 'capture-budget')
        response = self.output / 'capture-response.json'
        checked(not response.exists() and not response.is_symlink(), 'capture-response-replay')
        temporary = self.output / 'capture-response.pending'
        with temporary.open('xb') as stream:
            stream.write(json.dumps({'scene':scene,'sequence':self.sequence,'token':self.token,'status':status}, sort_keys=True).encode('ascii'))
        temporary.rename(response)


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


def requested_mode():
    args = sys.argv[1:]
    if not args: return 'visual'
    checked(args in (['--mode','visual'], ['--mode','interaction']), 'mode-invalid')
    return args[1]


def main():
    mode = requested_mode()
    global END, CANCELLED
    END = time.monotonic() + 240
    CANCELLED = False
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise PreviewFailure("Use only an ephemeral GitHub-hosted macOS runner")
    if mode == 'visual' and (DEST.exists() or DIAG_DEST.exists()):
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
        token = secrets.token_hex(16)
        env.update(BETTERFINDER_PREVIEW_MODE=mode, BETTERFINDER_CAPTURE_TOKEN=token)
        service = None
        process = None
        try:
            # Do not publish compiler/runtime logs or environment values.
            log_path = sandbox / "native.log"
            with log_path.open("wb") as log:
                gate_control(resources, env, log)
                process = OwnedPreview(resources)
                process.launch(['/bin/zsh', 'scripts/preview_app.sh'], env, log)
                if mode == 'visual':
                    service = CaptureService(resources, process, output, env, log, token)
                    while not process.observe():
                        checked(not CANCELLED and time.monotonic() < END - 6, 'run-timeout-or-cancel')
                        service.service()
                        time.sleep(.01)
                    checked(not CANCELLED and time.monotonic() < END - 6, 'run-timeout-or-cancel')
                else:
                    process.wait_exit(END - 6)
                process.cleanup()
                code = process.code
                if code:
                    marker = output / "verification.txt"
                    allowed = {
                        'visual rename sheet exposed',
                        'visual terminal tabs empty',
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
                        "broad network exposure: exact native title without label",
                    })
                    if marker.is_file() and not marker.is_symlink() and marker.stat().st_size <= 2048:
                        message = bounded_regular(marker, 2048).decode("utf8").removeprefix("FAIL: ").strip()
                        if mode == 'visual' and message in DIAG_FAILURES:
                            try:
                                payload = diagnostic_payload(output, message)
                                resources.stage(payload, diagnostic=True)
                            except Exception:
                                # Missing/invalid capture never replaces the original assertion
                                # with raw metadata, logs or exception text, and never publishes.
                                raise PreviewFailure("Native preview assertion: " + message + "; diagnostic unavailable") from None
                            raise DiagnosticPreviewFailure("Native preview assertion: " + message + "; diagnostic only, preview failed")
                        if message in allowed:
                            raise PreviewFailure("Native preview assertion: " + message)
                    # Harness-only compilation/bootstrap failures are distinct from
                    # production build/tests; retain the last fixed stage, not logs.
                    raise PreviewFailure("Native preview failed (exit %d); last stage: %s; fixed log evidence: %s; no artifact published" % (code, last_stage(output), log_evidence(log_path)))
        finally:
            stop(process)
        if mode == 'interaction':
            marker = bounded_regular(output / 'interaction-verification.txt', 512)
            checked(marker == b'PASS native keyboard/address subset; AX disclosure and resize not verified', 'interaction-marker')
            # No visual staging or destination mutation in this independent phase.
        else:
            verification = bounded_regular(output / 'verification.txt', 512)
            checked(verification == b'PASS visual-fixtures-only: 33 synthetic scenes; AX disclosure/resize interactions not verified', 'visual-marker')
            checked(service is not None and service.seen == set(FILES) and service.sequence == 33, 'capture-scene-completeness')
            payload = {}
            total = 0
            for name in FILES + ('light-cacheDisplay.png',):
                data = bounded_regular(output / name, MAX_BYTES)
                total += len(data)
                checked(len(data) >= 24 and total <= MAX_BYTES, 'render-total-bound')
                checked(data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', 'render-png')
                width, height = struct.unpack('>II', data[16:24])
                checked(1 <= width <= 3000 and 1 <= height <= 2200, 'render-dimensions')
                payload[name] = data
            # Fixed coverage statements; no inferred interaction or toolbar pass.
            payload['verification.txt'] = (
                'PASS visual-fixtures-only: 33 synthetic scenes plus one cacheDisplay comparison.\n'
                'AX disclosure/resize and keyboard/address interactions are NOT verified by this visual phase.\n'
                'Own synthetic NSWindow compositor capture only; no full-screen capture or permission grants.\n'
                'Bitmap fallback means toolbar-unverified; cacheDisplay alone is not evidence of an application defect.\n'
                'Trusted pinned Swift retains each window until acknowledgement; not atomic ownership against abrupt crash/window-ID reuse.\n'
                'Isolated synthetic HOME/preferences; no real network, terminal command, user files or devices.\n'
                'Composited scenes: ' + str(len(service.composited)) + '/33.\n'
                'Separate interaction phase runs after this artifact upload and cannot change this coverage.\n'
            ).encode('ascii')
            payload['capture-coverage.json'] = (json.dumps({'schema':1,'mode':'visual-fixtures-only',
                'composited':service.composited,'bitmap_toolbar_unverified':[name for name in FILES if name not in service.composited],
                'comparison':'light-cacheDisplay.png','interaction_pass':False}, sort_keys=True) + '\n').encode('ascii')
            checked(sum(map(len,payload.values())) <= 8*1024*1024, 'artifact-total-bound')
            resources.stage(payload)
    if mode == 'interaction':
        print('PASS: isolated native keyboard/address subset; AX disclosure/resize not verified; no visual artifact staged.')
    else:
        print('PASS: 33 isolated visual fixture scenes plus paired bitmap; interaction coverage separate; artifact bounded to 8 MiB.')


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
