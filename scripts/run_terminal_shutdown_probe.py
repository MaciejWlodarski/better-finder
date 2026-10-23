#!/usr/bin/env python3
"""Separate, synthetic-only native shutdown experiment. Not part of the GUI gate.
Requires explicit sole-publisher execution on the approved ephemeral macOS runner.
No user desktop, global process matching, screenshots, or production lifecycle fix.
"""
import argparse
import ctypes
import difflib
import errno
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import shutil
import re
import time

ROOT = Path(__file__).resolve().parent.parent
MAX_FRAME = 256
RING = 128 * 1024
OUTER_SECONDS = 480  # Cooperative work deadline; cleanup may continue past it.
# Separate native-job hard timeout (>=10 minutes) is required for final containment.
RUN_END = 0.0
CANCELLED = False
IDENTITY_HELPER = None
SOCKET_CONSTANTS = None
SOCKET_SEND_OPTIONS = None
OWNERS = []  # Retain owned resources until both reaping and descriptor cleanup finish.
CASES = []
CHILD_RETENTION_READY = False
STAGE = "preflight"
FAILURE_STAGE = None
OPERATION = "preflight"
FIRST_OPERATIONAL_FAILURE = None
FIRST_CLEANUP_FAILURE = None
LAST_CLEANUP_EXCEPTION = None
GROUP_CENSUS = None


class ProbeError(Exception):
    pass


class SafetyError(ProbeError):
    pass


def require(ok, tag):
    if not ok:
        raise ProbeError(tag)


def failure_reason(error):
    # Never stringify exceptions. Cleanup/safety errors take precedence over cause detail.
    if isinstance(error, SafetyError):
        return "safety-failure"
    mapping = {
        "normal-quit-timeout": "normal-quit-timeout",
        "normal-quit-not-proven": "normal-quit-not-proven",
        "quit-expectation-not-met": "quit-expectation-not-met",
        "proof-unsolicited-frame": "proof-unsolicited-frame",
        "fixture-not-live-at-quit": "fixture-not-live-at-quit",
        "gate-target-invalid": "gate-target-invalid",
        "gate-interpreter-invalid": "gate-interpreter-invalid",
        "gate-sigpipe-invalid": "gate-sigpipe-invalid",
        "gate-deadline": "gate-deadline",
        "gate-not-owned": "gate-not-owned",
        "gate-release-failed": "gate-release-failed",
        "gate-control-invalid": "gate-control-invalid",
        "gate-control-early-exit": "gate-control-early-exit",
        "gate-control-timeout": "gate-control-timeout",
        "gate-control-failed": "gate-control-failed",
        "process-event-unavailable": "process-event-unavailable",
        "process-event-no-process": "process-event-no-process",
        "process-event-permission": "process-event-permission",
        "process-event-unsupported": "process-event-unsupported",
        "process-event-invalid": "process-event-invalid",
        "process-event-resource": "process-event-resource",
        "process-event-other": "process-event-other",

        "approved-macos-runner-required": "approved-runner-required",
        "kqueue-unavailable": "kqueue-unavailable",
        "platform-identity-invalid": "platform-identity-invalid",
        "competing-supervisor-thread": "child-retention-contract",
        "sigchld-reset-failed": "child-retention-contract",
        "sigchld-preflight-abnormal-exit": "child-retention-contract",
        "manifest-count-invalid": "manifest-invalid",
        "manifest-duplicate-input": "manifest-invalid",
        "input-path-invalid": "input-path-invalid",
        "source-manifest-mismatch": "source-manifest-mismatch",
        "native-constants-invalid": "native-constants-invalid",
        "nosigpipe-setup-failed": "nosigpipe-setup-failed",
    }
    if isinstance(error, ProbeError) and len(error.args) == 1 and type(error.args[0]) is str:
        return mapping.get(error.args[0], "unavailable")
    return "unavailable"


SAFETY_SUBTYPES = {
    "launch-outcome-unverified", "owned-child-cleanup-timeout", "owned-child-signal-failed",
    "owned-group-cleanup-unverified", "owned-gate-close-unverified",
    "final-cleanup-unverified", "sigchld-auto-reap-detected", "sigchld-preflight-timeout",
    "fixture-cleanup-query-unavailable", "fixture-cleanup-unverified",
    "helper-case-cleanup-failed", "app-case-cleanup-failed",
}


def error_category(error):
    if isinstance(error, OSError):
        value = error.errno
        if value == errno.ENOENT:
            return "os-not-found"
        if value in {errno.EPERM, errno.EACCES}:
            return "os-permission"
        if value == errno.ECHILD:
            return "os-no-child"
        if value == errno.ESRCH:
            return "os-no-process"
        if value in {errno.ENOSYS, errno.ENOTSUP}:
            return "os-unsupported"
        return "os-other"
    if isinstance(error, subprocess.TimeoutExpired):
        return "wait-timeout"
    if isinstance(error, ProbeError) and len(error.args) == 1 and type(error.args[0]) is str:
        tag = error.args[0]
        if tag in SAFETY_SUBTYPES or tag in {
            "tool-timeout", "tool-failed", "outer-cancel-or-deadline",
            "unexpected-process-event", "process-event-error", "missing-exit-event",
            "child-retention-contract-missing",
        }:
            return tag
        return failure_reason(error)
    return "unavailable"


def record_failure(error, phase, cleanup=False):
    global FIRST_OPERATIONAL_FAILURE, FIRST_CLEANUP_FAILURE, LAST_CLEANUP_EXCEPTION
    if cleanup:
        LAST_CLEANUP_EXCEPTION = error
        if FIRST_CLEANUP_FAILURE is None:
            FIRST_CLEANUP_FAILURE = (OPERATION, phase, error_category(error))
    elif error is not LAST_CLEANUP_EXCEPTION and FIRST_OPERATIONAL_FAILURE is None:
        FIRST_OPERATIONAL_FAILURE = (OPERATION, phase, error_category(error))


def diagnostic_call(phase, fn, *args, cleanup=False, **kwargs):
    try:
        return fn(*args, **kwargs)
    except BaseException as error:
        record_failure(error, phase, cleanup)
        raise


def failure_diagnostic(error):
    # Only fixed enum records; never serialize exception objects or their arguments.
    record_failure(error, "unavailable")
    first = FIRST_OPERATIONAL_FAILURE or ("none", "none", "none")
    clean = FIRST_CLEANUP_FAILURE or ("none", "none", "none")
    subtype = "none"
    if isinstance(error, SafetyError):
        subtype = error_category(error)
        if subtype not in SAFETY_SUBTYPES:
            subtype = "unavailable"
    return dict(first_operation=first[0], first_phase=first[1], first_category=first[2],
                cleanup_operation=clean[0], cleanup_phase=clean[1], cleanup_category=clean[2],
                safety_subtype=subtype)


def load_group_census():
    # Apple libproc.h: int proc_listpgrppids(pid_t, void*, int byte_size).
    # The wrapper returns a PID COUNT. Darwin pid_t and C int are signed 32-bit.
    require(sys.platform == "darwin" and os.uname().machine in {"arm64", "x86_64"} and
            ctypes.sizeof(ctypes.c_int) == 4 and ctypes.sizeof(ctypes.c_int32) == 4,
            "group-census-unavailable")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_listpgrppids
    function.argtypes = [ctypes.c_int32, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_int
    return library, function  # Retain library for the function's lifetime.


def singleton_group(owner):
    # Only a known, exited, UNREAPED direct leader in our fresh session.
    # Accepted scope excludes detached/group-changing tools and all app owners.
    if (not owner.group or owner.group_scope not in {"trusted-tool", "fixture-control"} or
            owner.p is None or owner.reaped or not owner.exit_seen or
            not CHILD_RETENTION_READY or signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL or
            threading.active_count() != 1 or GROUP_CENSUS is None):
        return False
    pid = owner.p.pid
    if type(pid) is not int or not 1 < pid <= 2147483647:
        return False
    values = (ctypes.c_int * 2)(0, 0)
    try:
        ctypes.set_errno(0)
        count = GROUP_CENSUS[1](pid, values, ctypes.sizeof(values))
        error = ctypes.get_errno()
    except Exception:
        return False
    # Zero may be an API error; a full two-entry buffer may be truncated.
    return type(count) is int and count == 1 and error == 0 and values[0] == pid


def parse_socket_constants(raw):
    # Versioned, bounded native SDK values; never guess Darwin option numbers.
    require(type(raw) is bytes and len(raw) <= 128, "native-constants-invalid")
    require(re.fullmatch(rb"BFSC1(?: [0-9]{1,10}){6}\n", raw) is not None,
            "native-constants-invalid")
    values = tuple(int(x) for x in raw.split()[1:])
    level, peer_option, pid_size, uid_size, socket_level, nosigpipe = values
    require(0 <= level <= 2147483647 and 0 < peer_option <= 2147483647 and
            pid_size == 4 and uid_size == 4 and
            socket_level == socket.SOL_SOCKET and 0 < socket_level <= 2147483647 and
            0 < nosigpipe <= 2147483647, "native-constants-invalid")
    return values[:4], values[4:]


def protect_socket(s):
    require(SOCKET_SEND_OPTIONS is not None, "native-constants-invalid")
    level, option = SOCKET_SEND_OPTIONS
    try:
        s.setsockopt(level, option, 1)
        require(s.getsockopt(level, option) == 1, "nosigpipe-setup-failed")
    except OSError:
        raise ProbeError("nosigpipe-setup-failed") from None


def tick():
    if CANCELLED or time.monotonic() >= RUN_END:
        raise ProbeError("outer-cancel-or-deadline")


def cancelled(_sig, _frame):
    global CANCELLED
    CANCELLED = True  # Never reap or signal in a concurrent signal callback.


class CaseResources:
    """Registered before launch, survives a constructor failing before assignment."""
    def __init__(self, kind, env, cwd, started, nonce, case_id):
        self.kind, self.env, self.cwd = kind, env, cwd
        self.started, self.nonce, self.case_id = started, nonce, case_id
        self.attempted = False
        self.owner = None
        self.fixture = None
        self.app = None
        self.listeners = []
        self.original = None
        self.ready_time = None
        self.fixture_verified_gone = False
        self.unknown_wait_done = False
        self.safe = False
        CASES.append(self)

    def finish(self):
        """Attempt every resource independently; errors never skip another cleanup."""
        errors = []
        def attempt(fn):
            try:
                fn()
            except BaseException as error:
                record_failure(error, "cleanup-case-finalizer", cleanup=True)
                errors.append("cleanup-operation-failed")
        if self.fixture:
            if not self.fixture.closed and not self.fixture_verified_gone:
                try:
                    self.fixture.send("CLEANUP %s %s" % (self.nonce, self.case_id))
                except (OSError, ProbeError):
                    pass  # Delivery is not proof; independent identity verification follows.
            attempt(self.fixture.close)
        if self.owner:
            attempt(self.owner.cleanup)
        # Fixture verification is independent even if app/tool cleanup failed.
        if self.original and not self.fixture_verified_gone:
            try:
                wait_gone(self.original, self.env, self.cwd,
                          max(time.monotonic() + 2, (self.ready_time or self.started) + 14))
                self.fixture_verified_gone = True
            except BaseException as error:
                record_failure(error, "cleanup-case-finalizer", cleanup=True)
                errors.append("fixture-cleanup-unverified")
        elif self.kind == "app" and self.attempted and not self.original:
            if not self.unknown_wait_done:
                # App may have spawned before Owned.__init__ returned or a marker
                # arrived. Never signal an unverified fixture PID. Preserve root.
                until = self.started + 26
                while time.monotonic() < until:
                    time.sleep(.05)
                self.unknown_wait_done = True
            errors.append("unknown-app-spawned-work")
        if self.app:
            attempt(self.app.close)
        for server in self.listeners:
            attempt(server.close)
        owner_safe = self.owner is None or self.owner.reaped
        fixture_safe = (self.fixture_verified_gone if self.original else
                        not (self.kind == "app" and self.attempted))
        self.safe = owner_safe and fixture_safe and not errors
        return errors


def finalize_resources():
    errors = []
    # Case cleanup never stops cleanup of the other cases/launch attempts.
    for case in CASES:
        try:
            errors.extend(case.finish())
        except BaseException as error:
            record_failure(error, "cleanup-case-finalizer", cleanup=True)
            errors.append("case-finalizer-failed")
    # Includes partial Owned constructors and tools unrelated to a case.
    for owner in list(OWNERS):
        try:
            owner.cleanup()
        except BaseException as error:
            record_failure(error, "cleanup-owner-finalizer", cleanup=True)
            errors.append("owned-child-finalizer-failed")
    safe = not OWNERS and all(case.safe for case in CASES) and not errors
    return safe


def finalize_root(base):
    safe = finalize_resources()
    if safe:
        try:
            diagnostic_call("cleanup-root-remove", shutil.rmtree, base, cleanup=True)
        except OSError:
            safe = False
    if not safe:
        # Private root remains for approved ephemeral-runner disposal.
        error = SafetyError("final-cleanup-unverified")
        record_failure(error, "cleanup-root-finalizer", cleanup=True)
        raise error


def classify_response(valid_response):
    # Nonresponse may follow helper protocol, I/O, EOF or timer self-cleanup.
    return "CONFIRMED" if valid_response else "INCONCLUSIVE"


def establish_child_retention():
    """No guessed sigaction ABI; explicitly reset then behaviorally verify.

    No numeric signals are used in this preflight. A synthetic immediate-exit
    fork child is only ownership validation, never AppKit/T3 evidence.
    """
    global CHILD_RETENTION_READY
    CHILD_RETENTION_READY = False
    require(threading.active_count() == 1, "competing-supervisor-thread")
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    signal.siginterrupt(signal.SIGCHLD, False)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGCHLD})
    require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, "sigchld-reset-failed")
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    end = time.monotonic() + 2
    while time.monotonic() < end:
        try:
            waited, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            raise SafetyError("sigchld-auto-reap-detected") from None
        if waited == pid:
            require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
                    "sigchld-preflight-abnormal-exit")
            CHILD_RETENTION_READY = True
            return
        time.sleep(.005)
    # Do not signal a numeric PID while the retention contract is unverified.
    raise SafetyError("sigchld-preflight-timeout")


# Isolated interpreter bootstrap, never preexec_fn. No target runs before GO.
START_SHIM = r'''
import os, sys, signal, select, time
try:
    fd = int(sys.argv[1]); end = float(sys.argv[2]); argv = sys.argv[3:]
    if fd < 3 or not argv or not os.path.isabs(argv[0]): os._exit(120)
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


def gate_target_allowed(argv, scope):
    if not argv or not all(type(x) is str for x in argv): return False
    if IDENTITY_HELPER is not None and argv[0] == str(IDENTITY_HELPER):
        return scope in {"trusted-tool", "fixture-control"}
    if scope != "trusted-tool": return False
    if argv == ["/usr/bin/true"]: return True
    if argv[0] == "/usr/bin/xcrun":
        return len(argv) > 1 and argv[1] in {"clang", "swiftc", "--sdk"}
    return argv[0] == "/usr/bin/codesign" and len(argv) == 6 and argv[1:5] == ["--force", "--sign", "-", "--timestamp=none"]


class StartGate:
    def __init__(self):
        self.read_fd = self.write_fd = None
        self.uncertain = False

    def create(self):
        self.read_fd, self.write_fd = os.pipe()
        os.set_inheritable(self.read_fd, False)
        os.set_inheritable(self.write_fd, False)
        os.set_blocking(self.write_fd, False)

    def close_end(self, name):
        fd = getattr(self, name)
        setattr(self, name, None)  # Never retry a possibly reused numeric FD.
        if fd is not None:
            try: os.close(fd)
            except BaseException:
                self.uncertain = True
                raise

    def close(self):
        error = None
        for name in ("read_fd", "write_fd"):
            try: self.close_end(name)
            except BaseException as caught:
                if error is None: error = caught
        if error is not None: raise error
        if self.uncertain: raise SafetyError("owned-gate-close-unverified")

    def release(self):
        require(self.write_fd is not None and not self.uncertain, "gate-not-owned")
        require(os.write(self.write_fd, b"G") == 1, "gate-release-failed")
        self.close_end("write_fd")


def process_event_error(data):
    if type(data) is not int: return "process-event-unavailable"
    if data == errno.ESRCH: return "process-event-no-process"
    if data in {errno.EPERM, errno.EACCES}: return "process-event-permission"
    if data in {errno.ENOSYS, errno.ENOTSUP}: return "process-event-unsupported"
    if data == errno.EINVAL: return "process-event-invalid"
    if data in {errno.ENOMEM, errno.ENOSPC, errno.EMFILE, errno.ENFILE}: return "process-event-resource"
    return "process-event-other"


class Owned:
    """Only this owner reaps. NOTE_EXIT observation is NOT wait/poll.

    kqueue native constants/kevent layout come from Python's Darwin extension.
    No ctypes siginfo_t, guessed WNOWAIT values, or waitid ABI is used.
    If registration races an already-exited child, keep it unreaped and fail
    closed into owned cleanup. Popen is retained until cleanup/reap finishes.
    """
    def __init__(self, argv, env, cwd, group=True, case=None, group_scope=None, deadline=None, gate_hold=False, check_outer=True):
        require(CHILD_RETENTION_READY and signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL and
                threading.active_count() == 1, "child-retention-contract-missing")
        self.p = None
        self.q = None
        self.gate = None
        self.reaped = False
        self.exit_seen = False
        self.code = None
        self.output = bytearray()
        self.group = group
        self.group_scope = group_scope
        self.group_cleanup_verified = False
        self.group_cleanup_uncertain = False
        self.group_cleanup_attempted = False
        OWNERS.append(self)  # Register intent BEFORE the possibly partial Popen constructor.
        if case is not None:
            case.attempted = True
            case.owner = self
        phase = "launch"
        try:
            launch_argv = argv; extra = {}
            if group:
                phase = "gate-create"
                require(gate_target_allowed(argv, group_scope), "gate-target-invalid")
                require(os.path.isabs(sys.executable), "gate-interpreter-invalid")
                require(signal.getsignal(signal.SIGPIPE) == signal.SIG_IGN, "gate-sigpipe-invalid")
                created = time.monotonic()
                caller_end = deadline if deadline is not None else RUN_END
                if check_outer: caller_end = min(caller_end, RUN_END)
                release_end = min(created + 1, caller_end)
                shim_end = min(created + 2, caller_end)
                require(created < release_end, "gate-deadline")
                self.gate = StartGate()
                diagnostic_call("gate-create", self.gate.create)
                launch_argv = [sys.executable, "-I", "-S", "-c", START_SHIM,
                               str(self.gate.read_fd), repr(shim_end), *argv]
                extra = {"pass_fds": (self.gate.read_fd,)}
            self.p = diagnostic_call("launch", subprocess.Popen, launch_argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      close_fds=True, start_new_session=group, **extra)
            if self.gate is not None:
                diagnostic_call("gate-parent-read-close", self.gate.close_end, "read_fd")
            phase = "pipe-nonblocking"
            diagnostic_call("pipe-nonblocking", os.set_blocking, self.p.stdout.fileno(), False)
            phase = "kqueue-create"
            self.q = diagnostic_call("kqueue-create", select.kqueue)
            phase = "kevent-create"
            event = diagnostic_call("kevent-create", select.kevent, self.p.pid, filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                                 fflags=select.KQ_NOTE_EXIT)
            # An ESRCH/EV_ERROR here is inconclusive, never a reason to poll.
            phase = "kqueue-register"
            returned = diagnostic_call("kqueue-register", self.q.control, [event], 1, 0)
            phase = "kqueue-decode"
            diagnostic_call("kqueue-decode", self._events, returned)
            if self.gate is not None:
                phase = "gate-release"
                if gate_hold:
                    require(argv == ["/usr/bin/true"], "gate-control-invalid")
                    until = time.monotonic() + .05
                    while time.monotonic() < until:
                        require(not self.observe(), "gate-control-early-exit")
                        require(time.monotonic() < release_end and (not check_outer or not CANCELLED), "gate-deadline")
                        time.sleep(.005)
                require(not self.exit_seen and (not check_outer or not CANCELLED) and time.monotonic() < release_end, "gate-deadline")
                diagnostic_call("gate-release", self.gate.release)
        except BaseException as error:
            record_failure(error, phase)
            self.cleanup()
            raise

    def _events(self, events):
        for event in events:
            require(event.ident == self.p.pid and event.filter == select.KQ_FILTER_PROC,
                    "unexpected-process-event")
            if event.flags & select.KQ_EV_ERROR:
                raise ProbeError(process_event_error(event.data))
            require(event.fflags & select.KQ_NOTE_EXIT, "missing-exit-event")
            self.exit_seen = True

    def drain(self):
        if self.p.stdout is None or self.p.stdout.closed:
            return
        # Bounded work per tick; continue discarding excess output.
        for _ in range(8):
            try:
                data = os.read(self.p.stdout.fileno(), 16384)
            except BlockingIOError:
                break
            if not data:
                break
            self.output.extend(data)
            del self.output[:-RING]

    def observe(self):
        if self.reaped:
            return True
        self.drain()
        if self.q is not None:
            self._events(self.q.control([], 1, 0))
        return self.exit_seen

    def reap_normal_app(self):
        require(not self.group, "group-reap-before-cleanup")
        require(self.exit_seen, "reap-without-exit-observation")
        self.code = self.p.wait(timeout=1)
        self.reaped = True
        # No later signal is permitted, including finally.
        self.drain()
        return self.code

    def _cleanup_group(self):
        # State is independent of direct-child reaping. Uncertainty never clears.
        failure = None
        def uncertain(tag, phase):
            nonlocal failure
            self.group_cleanup_uncertain = True
            error = SafetyError(tag)
            record_failure(error, phase, cleanup=True)
            if failure is None:
                failure = error
        def observe_for_proof():
            try:
                self.observe()  # kqueue/drain only, never poll/wait.
            except BaseException as error:
                record_failure(error, "cleanup-group-proof", cleanup=True)
                uncertain("owned-group-cleanup-unverified", "cleanup-group-proof")
                return False
            return singleton_group(self)
        if getattr(self, "gate", None) is not None:
            try: diagnostic_call("cleanup-gate-close", self.gate.close, cleanup=True)
            except BaseException:
                uncertain("owned-gate-close-unverified", "cleanup-gate-close")
        if self.p is None:
            uncertain("launch-outcome-unverified", "cleanup-launch-outcome")
        elif not self.reaped and not self.group_cleanup_attempted:
            self.group_cleanup_attempted = True
            for sig, grace in ((signal.SIGTERM, .15), (signal.SIGKILL, .05)):
                try:
                    os.kill(-self.p.pid, sig)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    # EPERM alone proves nothing. Only the exact pre-reap
                    # singleton evidence can resolve the Darwin zombie case.
                    if error.errno != errno.EPERM or not observe_for_proof():
                        record_failure(error, "cleanup-term" if sig == signal.SIGTERM else "cleanup-kill", cleanup=True)
                        uncertain("owned-child-signal-failed", "cleanup-signal-result")
                until = time.monotonic() + grace
                while time.monotonic() < until:
                    try:
                        self.drain()
                    except OSError:
                        pass
                    time.sleep(.005)
            # Share the existing two-second reap budget with non-reaping exit
            # observation. Never reap first to obtain a stronger-looking proof.
            deadline = time.monotonic() + 2
            try:
                while not self.exit_seen and time.monotonic() < deadline:
                    self.observe()
                    if not self.exit_seen:
                        time.sleep(.005)
            except BaseException as error:
                record_failure(error, "cleanup-group-proof", cleanup=True)
                uncertain("owned-group-cleanup-unverified", "cleanup-group-proof")
            if not self.group_cleanup_uncertain and singleton_group(self):
                self.group_cleanup_verified = True
            else:
                uncertain("owned-group-cleanup-unverified", "cleanup-group-proof")
            try:
                self.code = diagnostic_call("cleanup-reap", self.p.wait,
                                            timeout=max(0, deadline - time.monotonic()), cleanup=True)
                self.reaped = True
            except subprocess.TimeoutExpired:
                uncertain("owned-child-cleanup-timeout", "cleanup-reap")
            except BaseException as error:
                record_failure(error, "cleanup-reap", cleanup=True)
                uncertain("owned-group-cleanup-unverified", "cleanup-reap")
        # No new numeric signal or census is permitted after reaping, including
        # a repeated finally call. Descriptor work remains independent.
        if self.p is not None:
            for phase, action in (("cleanup-drain", self.drain),
                                  ("cleanup-pipe-close", self.p.stdout.close if self.p.stdout is not None else lambda: None),
                                  ("cleanup-kqueue-close", self.q.close if self.q is not None else lambda: None)):
                try:
                    diagnostic_call(phase, action, cleanup=True)
                    if phase == "cleanup-kqueue-close":
                        self.q = None
                except BaseException:
                    uncertain("owned-group-cleanup-unverified", phase)
        safe = self.reaped and self.group_cleanup_verified and not self.group_cleanup_uncertain
        if safe:
            if self in OWNERS:
                OWNERS.remove(self)
        else:
            if failure is None:
                uncertain("owned-group-cleanup-unverified", "cleanup-group-proof")
            raise failure

    def cleanup(self):
        if self.group:
            return self._cleanup_group()
        if self.p is None:
            error = SafetyError("launch-outcome-unverified")
            record_failure(error, "cleanup-launch-outcome", cleanup=True)
            raise error
        # Only owner method; no Popen.poll/communicate/context-manager/destructor path.
        if not self.reaped:
            target = -self.p.pid if self.group else self.p.pid
            signal_error = False
            for sig, grace in ((signal.SIGTERM, .15), (signal.SIGKILL, .05)):
                try:
                    os.kill(target, sig)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    record_failure(error, "cleanup-term" if sig == signal.SIGTERM else "cleanup-kill", cleanup=True)
                    signal_error = True
                # Hold the leader UNREAPED even after NOTE_EXIT until final KILL.
                until = time.monotonic() + grace
                while time.monotonic() < until:
                    try:
                        self.drain()
                    except OSError:
                        pass
                    time.sleep(.005)
            try:
                self.code = diagnostic_call("cleanup-reap", self.p.wait, timeout=2, cleanup=True)
            except subprocess.TimeoutExpired:
                # Retain ownership; caller must abort native job. Never signal a reused ID.
                error = SafetyError("owned-child-cleanup-timeout")
                record_failure(error, "cleanup-reap", cleanup=True)
                raise error from None
            self.reaped = True
            if signal_error:
                error = SafetyError("owned-child-signal-failed")
                record_failure(error, "cleanup-signal-result", cleanup=True)
                raise error
        diagnostic_call("cleanup-drain", self.drain, cleanup=True)
        if self.p.stdout is not None:
            diagnostic_call("cleanup-pipe-close", self.p.stdout.close, cleanup=True)
        if self.q is not None:
            diagnostic_call("cleanup-kqueue-close", self.q.close, cleanup=True)
            self.q = None
        if self in OWNERS:
            OWNERS.remove(self)


def run_tool(argv, env, cwd, seconds, check_outer=True):
    end = time.monotonic() + seconds
    owner = Owned([str(x) for x in argv], env, cwd, group=True, group_scope="trusted-tool", deadline=end, check_outer=check_outer)
    try:
        while not diagnostic_call("tool-observe", owner.observe):
            if check_outer:
                tick()
            require(time.monotonic() < end, "tool-timeout")
            time.sleep(.005)
        require(time.monotonic() < end, "tool-timeout")
        # Cleanup owned residual group while the direct leader still anchors ID.
        owner.cleanup()
        require(owner.code == 0, "tool-failed")
        return bytes(owner.output)
    except BaseException as error:
        record_failure(error, "tool-work")
        raise
    finally:
        owner.cleanup()


def start_gate_control(env, cwd):
    end = time.monotonic() + 2
    gate_owner = Owned(["/usr/bin/true"], env, cwd, group_scope="trusted-tool", deadline=end, gate_hold=True)
    try:
        while not gate_owner.observe():
            tick(); require(time.monotonic() < end, "gate-control-timeout"); time.sleep(.005)
        require(time.monotonic() < end, "gate-control-timeout")
        gate_owner.cleanup()
        require(gate_owner.code == 0, "gate-control-failed")
        return {"case": "start-gate-true", "result": "CONTROL_PASS", "cleanup": "verified"}
    finally:
        gate_owner.cleanup()


def narrow_env(home, fixture, tmp):
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "TMPDIR": str(tmp) + "/", "BETTERFINDER_TEST_ROOT": str(fixture)}


def private_dir(parent, name):
    p = parent / name
    p.mkdir(mode=0o700)
    require(not p.is_symlink() and p.is_dir() and p.resolve().parent == parent.resolve(), "private-dir-invalid")
    return p.resolve()


def listener(path):
    require(len(os.fsencode(path)) < 104 and not path.exists(), "socket-path-invalid")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.set_inheritable(False)
    s.setblocking(False)
    s.bind(str(path)); os.chmod(path, 0o600); s.listen(2)
    return s


def peer(s):
    level, option, pid_size, uid_size = SOCKET_CONSTANTS
    require(pid_size == 4 and uid_size == 4, "unsupported-peer-abi")
    pid = struct.unpack("=i", s.getsockopt(level, option, 4))[0]
    libc = ctypes.CDLL(None, use_errno=True)
    f = libc.getpeereid
    f.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
    f.restype = ctypes.c_int
    uid, gid = ctypes.c_uint(), ctypes.c_uint()
    require(f(s.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0, "peer-uid-unavailable")
    require(pid > 1 and uid.value == os.getuid(), "peer-identity-invalid")
    return pid


class Channel:
    def __init__(self, s):
        self.s = s
        s.set_inheritable(False); s.setblocking(False)
        protect_socket(s)
        self.pid = peer(s)
        self.data = bytearray()
        self.closed = False

    def receive(self):
        result = []
        if self.closed:
            return result
        for _ in range(4):
            try:
                chunk = self.s.recv(256)
            except BlockingIOError:
                break
            if not chunk:
                self.closed = True
                break
            self.data.extend(chunk)
            require(len(self.data) <= MAX_FRAME and b"\0" not in self.data and b"\r" not in self.data, "frame-invalid")
            while b"\n" in self.data:
                line, _, rest = self.data.partition(b"\n")
                self.data = bytearray(rest)
                result.append(line.decode("ascii", errors="strict"))
        return result

    def send(self, text):
        data = (text + "\n").encode("ascii")
        require(len(data) <= MAX_FRAME and self.s.send(data) == len(data), "frame-send-failed")

    def close(self):
        self.s.close(); self.closed = True


def accept(s):
    try:
        connection, _ = s.accept()
    except BlockingIOError:
        return None
    try:
        return Channel(connection)
    except BaseException:
        connection.close()
        raise


def _identity(pid, env, cwd):
    data = run_tool([IDENTITY_HELPER, "--identity", str(pid)], env, cwd, 1, check_outer=False).decode("utf8", errors="strict").splitlines()
    require(bool(data), "empty-identity")
    words = data[0].split()
    if words == ["ABSENT"]:
        return {"kind": "absent"}
    if words == ["UNKNOWN"]:
        return {"kind": "unknown"}
    if len(words) == 4 and words[0] == "ZOMBIE":
        return {"kind": "zombie", "pid": int(words[1]), "start": tuple(map(int, words[2:]))}
    require(len(words) == 8 and words[0] == "LIVE" and len(data) == 2, "identity-invalid")
    values = list(map(int, words[1:]))
    return {"kind": "live", "pid": values[0], "ppid": values[1], "pgid": values[2], "uid": values[3],
            "status": values[4], "start": tuple(values[5:]), "path": data[1]}


def identity(pid, env, cwd):
    global STAGE
    previous = STAGE
    STAGE = "identity"
    result = _identity(pid, env, cwd)
    STAGE = previous
    return result


def verified_live(pid, parent, executable, env, cwd):
    v = identity(pid, env, cwd)
    require(v["kind"] == "live" and v["pid"] == pid and v["ppid"] == parent and v["pgid"] == pid and
            v["uid"] == os.getuid() and Path(v["path"]).resolve() == executable.resolve(), "foreground-identity-invalid")
    v["inode"] = (executable.stat().st_dev, executable.stat().st_ino)
    return v


def gone(original, env, cwd):
    current = identity(original["pid"], env, cwd)
    if current["kind"] == "unknown":
        return None
    if current["kind"] == "absent":
        return True
    if current.get("start") != original["start"]:
        return True  # New process identity; NEVER signal its numeric ID.
    if current["kind"] == "zombie":
        return True
    return False


def wait_gone(original, env, cwd, until):
    while time.monotonic() < until:
        try:
            answer = gone(original, env, cwd)
        except (OSError, ProbeError):
            raise SafetyError("fixture-cleanup-query-unavailable") from None
        if answer is True:
            return
        time.sleep(.025)
    raise SafetyError("fixture-cleanup-unverified")


def case_environment(base, case_id):
    folder = private_dir(base, case_id)
    home = private_dir(folder, "home")
    fixture = private_dir(folder, "fixture")
    tmp = private_dir(folder, "tmp")
    return folder, fixture, narrow_env(home, fixture, tmp)


def helper_case(base, helper, mode, action):
    case_id = "helper-" + mode + "-" + action
    folder, cwd, env = case_environment(base, case_id)
    nonce = secrets.token_hex(16)
    path = folder / "f.sock"
    server = listener(path)
    owner = None; channel = None; original = None
    started = time.monotonic()
    resources = CaseResources("helper", env, cwd, started, nonce, case_id)
    resources.listeners = [server]
    try:
        owner = Owned([str(helper), str(path), nonce, case_id, mode, "fixture-v1"], env, cwd, case=resources, group_scope="fixture-control", deadline=started + 2)
        deadline = started + 2
        frame = None
        while frame is None:
            tick(); require(time.monotonic() < deadline, "helper-setup-timeout")
            if channel is None:
                channel = accept(server)
                resources.fixture = channel
                if channel:
                    require(channel.pid == owner.p.pid, "helper-peer-mismatch")
            if channel:
                lines = channel.receive()
                require(len(lines) <= 1, "duplicate-helper-ready")
                if lines:
                    frame = lines[0]
            require(not owner.observe(), "helper-premature-exit")
            time.sleep(.005)
        original = verified_live(channel.pid, os.getpid(), helper, env, cwd)
        resources.original = original
        resources.ready_time = time.monotonic()
        require(frame == "READY %s %s %d %d %d" % (nonce, case_id, channel.pid, channel.pid, os.getpid()), "helper-ready-invalid")
        action_time = time.monotonic()
        if action == "cleanup":
            channel.send("CLEANUP %s %s" % (nonce, case_id))
        elif action == "eof":
            channel.close()
        elif action != "deadline":
            raise ProbeError("invalid-helper-action")
        limit = started + 14 if action == "deadline" else action_time + 2
        while not diagnostic_call("tool-observe", owner.observe):
            tick(); require(time.monotonic() < limit, "helper-control-timeout")
            time.sleep(.01)
        observed = time.monotonic()
        # Before owned cleanup can introduce death, record actual signal status.
        # Fixture control is single-process; group cleanup occurs only after exit seen.
        owner.cleanup()
        expected = -signal.SIGKILL if mode == "resistant" or action == "deadline" else -signal.SIGTERM
        require(owner.code == expected, "helper-control-wrong-signal")
        if action == "deadline":
            require(observed - started >= 11.5, "hard-deadline-fired-early")
        wait_gone(original, env, cwd, time.monotonic() + 2)
        resources.fixture_verified_gone = True
        return {"case": case_id, "result": "CONTROL_PASS", "cleanup": "verified"}
    except BaseException as error:
        record_failure(error, "operation")
        raise
    finally:
        if diagnostic_call("cleanup-case-finalizer", resources.finish, cleanup=True):
            error = SafetyError("helper-case-cleanup-failed")
            record_failure(error, "cleanup-case-finalizer", cleanup=True)
            raise error


def proof_helper_case(base, helper, protocol):
    mode = "proof-resistant" if protocol else "proof-default"
    case_id = "proof-protocol-resistant" if protocol else "proof-eof-default"
    folder, cwd, env = case_environment(base, case_id)
    nonce = secrets.token_hex(16); path = folder / "f.sock"
    started = time.monotonic()
    require(RUN_END - started > 20, "insufficient-proof-control-budget")
    server = listener(path)
    resources = CaseResources("helper", env, cwd, started, nonce, case_id)
    resources.listeners = [server]; channel = None; original = None
    try:
        owner = Owned([str(helper), str(path), nonce, case_id, mode, "fixture-v1"],
                      env, cwd, case=resources, group_scope="fixture-control", deadline=started + 2)
        ready = None
        while ready is None:
            tick(); require(time.monotonic() < started + 2, "proof-control-ready-timeout")
            if channel is None:
                channel = accept(server); resources.fixture = channel
            if channel:
                lines = channel.receive(); require(len(lines) <= 1, "proof-control-duplicate")
                if lines: ready = lines[0]
            require(not owner.observe(), "proof-control-early-exit")
            time.sleep(.005)
        require(ready == "READY %s %s %d %d %d" % (nonce, case_id, owner.p.pid, owner.p.pid, os.getpid()), "proof-control-ready-invalid")
        original = verified_live(channel.pid, os.getpid(), helper, env, cwd)
        require(channel.pid == owner.p.pid, "proof-control-peer-invalid")
        resources.original = original; resources.ready_time = time.monotonic()
        action_time = time.monotonic()
        if protocol:
            channel.send("INVALID")
            fault = False
            while not fault:
                tick(); require(time.monotonic() < action_time + 1, "proof-control-fault-timeout")
                lines = channel.receive()
                require(len(lines) <= 1, "proof-control-fault-duplicate")
                if lines:
                    require(lines == ["FAULT %s %s" % (nonce, case_id)], "proof-control-fault-invalid")
                    fault = True
                require(not owner.observe(), "proof-control-early-exit")
                time.sleep(.005)
        else:
            channel.close()  # Deliberate EOF; proof fixture must not self-terminate.
        while time.monotonic() < action_time + .35:
            tick(); require(not owner.observe(), "proof-control-early-exit"); time.sleep(.005)
        require(gone(original, env, cwd) is False and time.monotonic() < started + 10,
                "proof-control-not-live")
        # Freeze positive control observation before any disposal.
        if protocol:
            channel.send("CLEANUP %s %s" % (nonce, case_id))
            until = time.monotonic() + 2
            while not owner.observe():
                tick(); require(time.monotonic() < until, "proof-control-cleanup-timeout"); time.sleep(.005)
            owner.cleanup()
            require(owner.code == -signal.SIGKILL, "proof-control-cleanup-signal")
        else:
            # EOF proof also checks unchanged harddeadline, without early disposal.
            while not owner.observe():
                tick(); require(time.monotonic() < started + 14, "proof-control-deadline-timeout"); time.sleep(.01)
            require(time.monotonic() - started >= 11.5, "proof-control-deadline-early")
            owner.cleanup()
            require(owner.code == -signal.SIGKILL, "proof-control-deadline-signal")
        wait_gone(original, env, cwd, resources.ready_time + 14)
        resources.fixture_verified_gone = True
        return {"case": case_id, "result": "CONTROL_PASS", "cleanup": "verified"}
    except BaseException as error:
        record_failure(error, "operation"); raise
    finally:
        if diagnostic_call("cleanup-case-finalizer", resources.finish, cleanup=True):
            error = SafetyError("helper-case-cleanup-failed")
            record_failure(error, "cleanup-case-finalizer", cleanup=True); raise error


def shutdown_verdict(dead, completed, deadline, fault, normal_exit, clean_observation):
    # Identity evidence only; EOF/nonresponse/late queries never establish death.
    return ("SHUTDOWN_VERIFIED" if dead is True and completed < deadline and
            not fault and normal_exit and clean_observation else "INCONCLUSIVE")


def app_case(base, app, helper, mode, control):
    global STAGE
    STAGE = "startup"
    case_id = ("cancel-" if control else "quit-") + mode
    folder, cwd, env = case_environment(base, case_id)
    nonce = secrets.token_hex(16)
    app_path, fixture_path = folder / "a.sock", folder / "f.sock"
    app_server, fixture_server = listener(app_path), listener(fixture_path)
    env.update(BF_PROBE_APPROVED_RUNNER="1", BF_PROBE_APP_SOCKET=str(app_path),
               BF_PROBE_FIXTURE_SOCKET=str(fixture_path), BF_PROBE_HELPER=str(helper),
               BF_PROBE_NONCE=nonce, BF_PROBE_CASE=case_id, BF_PROBE_MODE=mode if control else "proof-" + mode)
    owner = None; app_channel = None; fixture_channel = None; original = None
    started = time.monotonic(); ready_time = None
    seen = set(); response = False; result = "INCONCLUSIVE"
    expected_events = {"APP", "STARTED", "QUIT", "HIDE", "HIDDEN", "TERMINATED"}
    resources = CaseResources("app", env, cwd, started, nonce, case_id)
    resources.listeners = [app_server, fixture_server]

    def pump():
        nonlocal app_channel, fixture_channel, original, ready_time
        tick()
        if app_channel is None:
            app_channel = accept(app_server)
            resources.app = app_channel
            if app_channel:
                require(app_channel.pid == owner.p.pid, "app-peer-mismatch")
        if fixture_channel is None:
            fixture_channel = accept(fixture_server)
            resources.fixture = fixture_channel
        if app_channel:
            for line in app_channel.receive():
                parts = line.split()
                require(len(parts) == 3 and parts[1:] == [nonce, case_id], "app-frame-invalid")
                name = parts[0]
                require(name in expected_events and name not in seen, "app-event-invalid-or-duplicate")
                require(name != "HIDDEN" or control, "unexpected-hide")
                seen.add(name)
        if fixture_channel and original is None:
            lines = fixture_channel.receive()
            require(len(lines) <= 1, "fixture-ready-duplicate")
            if lines:
                pid = fixture_channel.pid
                require(lines[0] == "READY %s %s %d %d %d" % (nonce, case_id, pid, pid, owner.p.pid), "fixture-ready-invalid")
                original = verified_live(pid, owner.p.pid, helper, env, cwd)
                ready_time = time.monotonic()
                resources.original = original
                resources.ready_time = ready_time
        owner.observe()

    try:
        require(RUN_END - time.monotonic() > 35, "insufficient-app-case-budget")
        # The app has no child tools; cleanup uses only its unreaped direct PID.
        owner = Owned([str(app)], env, cwd, group=False, case=resources)
        while original is None or not {"APP", "STARTED"}.issubset(seen):
            pump(); require(not owner.exit_seen, "app-early-exit")
            require(time.monotonic() < started + 10, "app-ready-timeout")
            time.sleep(.005)
        verified = verified_live(original["pid"], owner.p.pid, helper, env, cwd)
        require(verified["start"] == original["start"], "fixture-identity-changed")
        require(time.monotonic() < started + 7, "insufficient-fixture-lifetime")
        pump(); require(not fixture_channel.closed and not owner.exit_seen, "premature-lifecycle-end")
        if control:
            app_channel.send("HIDE %s %s" % (nonce, case_id))
            end = time.monotonic() + 2
            while True:
                pump(); require(not owner.exit_seen, "control-app-exited")
                dead = gone(original, env, cwd)
                if dead is True and {"HIDE", "HIDDEN"}.issubset(seen):
                    break
                require(time.monotonic() < end, "drawer-cancellation-failed")
                time.sleep(.01)
            result = "CONTROL_PASS"
        else:
            require(gone(original, env, cwd) is False, "fixture-not-live-at-quit")
        STAGE = "shutdown"
        request_time = time.monotonic()
        app_channel.send("QUIT %s %s" % (nonce, case_id))
        while not owner.exit_seen:
            pump(); require(time.monotonic() < request_time + 5, "normal-quit-timeout")
            time.sleep(.005)
        code = owner.reap_normal_app()
        exit_observed = time.monotonic()
        pump()  # Drain marker already sent before normal process exit.
        require(code == 0 and {"QUIT", "TERMINATED"}.issubset(seen), "normal-quit-not-proven")
        challenge_sent = challenge_received = None
        gone_observed = None; proof_fault_seen = False; proof_clean = True
        if not control:
            STAGE = "protocol"
            # A short post-exit window, never the full ten-second lifetime ceiling.
            deadline = min(started + 10, time.monotonic() + 1)
            def read_faults():
                nonlocal proof_fault_seen
                lines = fixture_channel.receive()
                for line in lines:
                    require(line == "FAULT %s %s" % (nonce, case_id), "proof-unsolicited-frame")
                    proof_fault_seen = True
            dead = None
            while time.monotonic() < deadline:
                read_faults()
                if proof_fault_seen: break
                dead = gone(original, env, cwd)
                completed = time.monotonic()
                read_faults()
                result = shutdown_verdict(dead, completed, deadline, proof_fault_seen, True, proof_clean)
                if result == "SHUTDOWN_VERIFIED":
                    gone_observed = completed; break
                if dead is None or completed >= deadline: break
                tick(); time.sleep(.01)
            # No data was sent to fixture during disappearance observation.
            # Freeze negative evidence before any challenge or cleanup.
            if result != "SHUTDOWN_VERIFIED" and dead is False and not proof_fault_seen:
                proof_clean = False
                challenge = secrets.token_hex(16)
                challenge_sent = time.monotonic()
                try:
                    fixture_channel.send("CHALLENGE %s %s %s" % (nonce, case_id, challenge))
                    end = challenge_sent + .25
                    while time.monotonic() < end:
                        lines = fixture_channel.receive()
                        require(len(lines) <= 1, "challenge-duplicate")
                        if lines:
                            if lines == ["FAULT %s %s" % (nonce, case_id)]:
                                proof_fault_seen = True; break
                            require(lines == ["RESPONSE %s %s %s" % (nonce, case_id, challenge)], "challenge-invalid")
                            response = True; challenge_received = time.monotonic(); break
                        if fixture_channel.closed: break
                        tick(); time.sleep(.002)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                result = classify_response(response) if not proof_fault_seen else "INCONCLUSIVE"
        # Verdict is frozen. Only now may supervisor cleanup cause fixture death.
        if not fixture_channel.closed:
            try:
                fixture_channel.send("CLEANUP %s %s" % (nonce, case_id))
            except (BrokenPipeError, ConnectionResetError):
                pass
        fixture_channel.close()
        wait_gone(original, env, cwd, ready_time + 14)
        resources.fixture_verified_gone = True
        return {"case": case_id, "result": result, "cleanup": "verified", "normal_exit": True,
                "restoration_enabled": False, "persistence_tested": False,
                "post_exit_response": response,
                "quit_to_exit_observation_ms": round((exit_observed - request_time) * 1000, 3),
                "challenge_roundtrip_ms": None if not response else round((challenge_received - challenge_sent) * 1000, 3),
                "proof_mode": not control, "proof_fault_observed": proof_fault_seen,
                "gone_by_observation_ms": None if gone_observed is None else round((gone_observed - started) * 1000, 3),
                "observation_before_intervention": gone_observed is not None}
    except BaseException as error:
        record_failure(error, "operation")
        raise
    finally:
        if diagnostic_call("cleanup-case-finalizer", resources.finish, cleanup=True):
            error = SafetyError("app-case-cleanup-failed")
            record_failure(error, "cleanup-case-finalizer", cleanup=True)
            raise error


def transform(source, build):
    app_path = source / "Sources/BetterFinder/BetterFinderApp.swift"
    drawer_path = source / "Sources/BetterFinder/Views/EmbeddedTerminalDrawerView.swift"
    app = app_path.read_text(); drawer = drawer_path.read_text()
    require(hashlib.sha256(app_path.read_bytes()).hexdigest() == "e6f377cfd32d9cf78f8ae81b8b4d68629ff23be317cfe9ddc96424aabcc9f71a", "app-source-drift")
    require(hashlib.sha256(drawer_path.read_bytes()).hexdigest() == "17d577dbf1243348932c1b0393d423cd46a733e36ed7203bcd516ee69d83bb53", "drawer-source-drift")
    require(app.count("@main\n") == 1, "main-transform-mismatch")
    changed_app = app.replace("@main\n", "", 1)
    needle = "        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }\n"
    require(changed_app.count(needle) == 1, "delegate-transform-mismatch")
    changed_app = changed_app.replace(needle, needle + "        ProbeTerminationMarker.shared.emit()\n")
    needle = "        .onAppear { isInputFocused = true }\n        .onDisappear {\n"
    require(drawer.count(needle) == 1, "drawer-transform-mismatch")
    changed_drawer = drawer.replace(needle, "        .onAppear {\n            isInputFocused = true\n            ShutdownProbe.appeared { executeCommand($0) }\n        }\n        .onDisappear {\n            ShutdownProbe.disappeared()\n")
    app_out, drawer_out = build / "App.swift", build / "Drawer.swift"
    app_out.write_text(changed_app); drawer_out.write_text(changed_drawer)
    diff = "".join(difflib.unified_diff(app.splitlines(True), changed_app.splitlines(True), fromfile="production/App.swift", tofile="probe/App.swift"))
    diff += "".join(difflib.unified_diff(drawer.splitlines(True), changed_drawer.splitlines(True), fromfile="production/Drawer.swift", tofile="probe/Drawer.swift"))
    (build / "transforms.diff").write_text(diff)
    return app_out, drawer_out, hashlib.sha256(diff.encode()).hexdigest()


def main():
    global RUN_END, IDENTITY_HELPER, SOCKET_CONSTANTS, SOCKET_SEND_OPTIONS, STAGE, FAILURE_STAGE, OPERATION, GROUP_CENSUS
    parser = argparse.ArgumentParser()
    parser.add_argument("--approved-ephemeral-runner", action="store_true")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--expected-quit-result", choices=("CONFIRMED", "SHUTDOWN_VERIFIED"), required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and args.approved_ephemeral_runner, "approved-macos-runner-required")
    require(all(hasattr(select, x) for x in ("kqueue", "kevent", "KQ_FILTER_PROC", "KQ_NOTE_EXIT")), "kqueue-unavailable")
    require(os.uname().machine in {"arm64", "x86_64"} and
            re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", os.uname().release), "platform-identity-invalid")
    GROUP_CENSUS = load_group_census()
    RUN_END = time.monotonic() + OUTER_SECONDS
    signal.signal(signal.SIGINT, cancelled); signal.signal(signal.SIGTERM, cancelled)
    establish_child_retention()
    manifest_bytes = args.manifest.read_bytes()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)
    require(manifest.get("file_count") == len(manifest["files"]), "manifest-count-invalid")
    allowed_inputs = {entry["path"] for entry in manifest["files"]}
    require(len(allowed_inputs) == manifest["file_count"], "manifest-duplicate-input")
    for entry in manifest["files"]:
        p = ROOT / entry["path"]
        require(p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(ROOT.resolve()), "input-path-invalid")
        require(hashlib.sha256(p.read_bytes()).hexdigest() == entry["sha256"], "source-manifest-mismatch")
    results = []
    # Short roots keep sockaddr_un paths below Darwin's fixed limit.
    base = Path(tempfile.mkdtemp(prefix="bfq-", dir="/tmp")).resolve()
    os.chmod(base, 0o700)
    try:
        build = private_dir(base, "build"); home = private_dir(base, "home")
        fixture = private_dir(base, "fixture"); tmp = private_dir(base, "tmp")
        env = narrow_env(home, fixture, tmp)
        results.append(start_gate_control(env, build))
        build_deadline = time.monotonic() + 180
        def tool(argv, seconds):
            return run_tool(argv, env, build, min(seconds, max(.01, build_deadline - time.monotonic())))
        STAGE = "build-c"
        helper = build / "fixture-tool"
        OPERATION = "compile-c"
        tool(["/usr/bin/xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", ROOT / "scripts/terminal_shutdown_fixture.c", "-o", helper], 30)
        IDENTITY_HELPER = helper
        OPERATION = "version-swift"
        version_output = tool(["/usr/bin/xcrun", "swiftc", "--version"], 5).decode("utf8", errors="replace")
        swift_match = re.search(r"Swift version ([0-9]+(?:\.[0-9]+){0,3})", version_output)
        require(swift_match is not None, "swift-version-unavailable")
        OPERATION = "version-clang"
        clang_output = tool(["/usr/bin/xcrun", "clang", "--version"], 5).decode("utf8", errors="replace")
        clang_match = re.search(r"clang version ([0-9]+(?:\.[0-9]+){0,3})", clang_output)
        require(clang_match is not None, "clang-version-unavailable")
        OPERATION = "constants"
        SOCKET_CONSTANTS, SOCKET_SEND_OPTIONS = parse_socket_constants(tool([helper, "--constants"], 2))
        OPERATION = "sdk"
        sdk = tool(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], 10).decode().strip()
        require(sdk.startswith("/") and Path(sdk).is_dir(), "sdk-invalid")
        OPERATION = "transform"
        app_source, drawer_source, diff_hash = transform(ROOT, build)
        OPERATION = "bundle"
        bundle = private_dir(build, "Probe.app"); contents = private_dir(bundle, "Contents"); binary_dir = private_dir(contents, "MacOS")
        import plistlib
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "ShutdownProbe", "CFBundleIdentifier": "com.betterfinder.shutdown-probe",
                          "CFBundleName": "ShutdownProbe", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}, stream)
        binary = binary_dir / "ShutdownProbe"
        sources = sorted((ROOT / "Sources/BetterFinder/Models").glob("*.swift")) + sorted((ROOT / "Sources/BetterFinder/Engine").glob("*.swift"))
        sources += [p for p in sorted((ROOT / "Sources/BetterFinder/Views").glob("*.swift")) if p.name != "EmbeddedTerminalDrawerView.swift"]
        cache = private_dir(build, "module-cache")
        require(all(str(p.relative_to(ROOT)) in allowed_inputs for p in sources), "unmanifested-compile-source")
        argv = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-D", "BETTERFINDER_TESTING", "-D", "BETTERFINDER_SHUTDOWN_PROBE",
                "-module-cache-path", cache, "-target", os.uname().machine + "-apple-macosx14.0", "-sdk", sdk]
        argv += sources + [app_source, drawer_source, ROOT / "scripts/terminal_shutdown_probe.swift", "-o", binary]
        STAGE = "build-swift"
        OPERATION = "compile-swift"
        tool(argv, 120)
        STAGE = "sign"
        OPERATION = "sign"
        tool(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", bundle], 15)
        OPERATION = "helper-controls"
        STAGE = "helper-controls"
        for mode in ("default", "resistant"):
            for action in ("cleanup", "eof", "deadline"):
                results.append(helper_case(base, helper, mode, action))
        require(RUN_END - time.monotonic() > 160, "insufficient-proof-suite-budget")
        for protocol in (False, True):
            results.append(proof_helper_case(base, helper, protocol))
        for control in (True, False):
            OPERATION = "cancel-controls" if control else "quit-cases"
            STAGE = "cancel-controls" if control else "quit-cases"
            for mode in ("default", "resistant"):
                results.append(app_case(base, binary, helper, mode, control))
        tick()
        require(all(case["result"] == args.expected_quit_result for case in results if case["case"].startswith("quit-")),
                "quit-expectation-not-met")
        # Fixed schema only. No logs, private paths, tokens or command content.
        output = {"schema": 3, "result": "COMPLETE", "configuration": "restoration-disabled-quit-proof-v1",
                  "expected_quit_result": args.expected_quit_result,
                  "transform_sha256": diff_hash, "source_manifest_sha256": manifest_digest,
                  "darwin_release": os.uname().release, "architecture": os.uname().machine,
                  "swift_version": swift_match.group(1), "clang_version": clang_match.group(1),
                  "cases": results}
    except BaseException as error:
        record_failure(error, "operation")
        FAILURE_STAGE = STAGE
        raise
    finally:
        STAGE = "cleanup"
        finalize_root(base)
    STAGE = "complete"
    print(json.dumps(output, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SafetyError as error:
        print(json.dumps({"schema": 2, "result": "SAFETY_FAILURE", "clean_success": False, "stage": FAILURE_STAGE or STAGE, "reason": failure_reason(error), "diagnostic": failure_diagnostic(error)}))
        sys.exit(2)
    except (Exception, KeyboardInterrupt) as error:
        print(json.dumps({"schema": 2, "result": "INCONCLUSIVE", "clean_success": False, "stage": FAILURE_STAGE or STAGE, "reason": failure_reason(error), "diagnostic": failure_diagnostic(error)}))
        sys.exit(1)
