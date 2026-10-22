#!/usr/bin/env python3
"""Bounded, synthetic-only execution of the existing native preview harness.

This is not desktop capture, Accessibility automation, or a permission grant.
Run only on an ephemeral GitHub-hosted macOS runner after code gates pass.
"""
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FILES = ("rename.png", "light.png", "search.png", "compact.png", "inspector.png", "dual-pane.png", "dark-icons.png")
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


def stop(process):
    if process is None:
        return
    # Ignore repeat cancellation signals only while reaping our owned group.
    # Restore handlers even if cleanup fails; callers must not stage artifacts
    # until this function returns successfully.
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        # The group belongs exclusively to this invocation, not other runner jobs.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Native preview cleanup exceeded its deadline; no artifact published") from None
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def interrupted(signum, frame):
    raise RuntimeError("Native preview interrupted")


def main():
    if sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Use only an ephemeral GitHub-hosted macOS runner")
    if DEST.exists():
        raise RuntimeError("Artifact directory already exists; use a fresh checkout")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with tempfile.TemporaryDirectory(prefix="better-finder-preview-ci-") as tmp:
        sandbox = Path(tmp)
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
            with (sandbox / "native.log").open("wb") as log:
                process = subprocess.Popen(["zsh", "scripts/preview_app.sh"], cwd=ROOT, env=env,
                                           stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    code = process.wait(timeout=240)
                except subprocess.TimeoutExpired:
                    raise RuntimeError("Native preview exceeded 240 seconds; last stage: " + last_stage(output)) from None
                if code:
                    marker = output / "verification.txt"
                    allowed = {
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
                    }
                    if marker.is_file() and marker.stat().st_size <= 2048:
                        message = marker.read_text().removeprefix("FAIL: ").strip()
                        if message in allowed:
                            raise RuntimeError("Native preview assertion: " + message)
                    # Harness-only compilation/bootstrap failures are distinct from
                    # production build/tests; retain the last fixed stage, not logs.
                    raise RuntimeError("Native preview failed (exit %d); last stage: %s; no artifact published" % (code, last_stage(output)))
        finally:
            stop(process)
        verification = output / "verification.txt"
        if not verification.is_file() or verification.stat().st_size > 2048 or not verification.read_text().startswith("PASS native window,"):
            raise RuntimeError("Missing native preview PASS marker")
        total = 0
        for name in FILES:
            file = output / name
            if file.is_symlink() or not file.is_file():
                raise RuntimeError("Missing expected native render: " + name)
            size = file.stat().st_size
            total += size
            if size < 24 or total > MAX_BYTES:
                raise RuntimeError("Native renders exceed the 8 MiB artifact bound")
            with file.open("rb") as stream:
                header = stream.read(24)
            if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                raise RuntimeError("Invalid native PNG: " + name)
            width, height = struct.unpack(">II", header[16:24])
            if not (1 <= width <= 3000 and 1 <= height <= 2200):
                raise RuntimeError("Unexpected render dimensions: " + name)
        DEST.mkdir(parents=True)
        for name in FILES:
            shutil.copyfile(output / name, DEST / name)
        # Deliberately fixed verification text: never copy logs or environment paths.
        (DEST / "verification.txt").write_text(
            "PASS: native app window and in-process keyboard assertions using application-level synthetic-fixture isolation.\n"
            "Seven native AppKit view renders from synthetic fixtures.\n"
            "Test startup uses synthetic pane roots and an isolated preference suite; mounted-volume discovery and automatic indexing are disabled.\n"
            "Not an OS sandbox or proof that all macOS global/preference accesses are blocked; an ephemeral hosted runner is required.\n"
            "No desktop capture, global keyboard injection or OS permission automation.\n"
            "Not proof of menu shortcut dispatch, rename submission, persistence, external drag/drop, Quick Look or thumbnail correctness.\n")
        print("PASS: seven isolated native view renders; PNG payload %d bytes; total artifact including verification is bounded to 8 MiB." % total)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        # RuntimeError messages above are fixed strings or allowlisted assertions.
        print("FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError):
        # Filesystem/decoding errors can contain paths or data; never echo them.
        print("FAIL: native preview I/O or data validation failed; no artifact published", file=sys.stderr)
        sys.exit(1)
