"""Run the real local contract harness; child secrets travel only over stdin."""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("local.exs")
PORTS = (42630, 42631)


class DemoError(RuntimeError):
    pass


def closed_ports():
    for port in PORTS:
        with socket.socket() as sock:
            sock.settimeout(1)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                raise DemoError(f"Demo port {port} is still occupied")


def launch(role, cwd, env):
    args = [shutil.which("mix"), "run", "--no-start", str(SCRIPT), role]
    command = 'cmd.exe /d /s /c "' + subprocess.list2cmdline(args) + '"' if os.name == "nt" else args
    return subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=os.name != "nt")


def stop(child, grace):
    if child is None:
        return
    try:
        child.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            try:
                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
            except subprocess.SubprocessError:
                child.kill()
                child.wait(timeout=10)
                raise DemoError("Windows process-tree cleanup failed") from None
        else:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=10)
    finally:
        # A launcher may exit before its descendants; reap its owned Linux group too.
        if os.name != "nt":
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def display(line):
    if line.startswith("DEMO "):
        print(line, flush=True)
    elif re.search(r"\bwarning\b", line, re.IGNORECASE):
        function = re.search(r"Tidewake\.[A-Za-z_.]+/\d+", line)
        category = function.group() if function and "undefined" in line else "details redacted"
        print(f"DEMO diagnostic: child warning observed ({category})", flush=True)


def run_demo(iron, timeout=300, grace=5):
    iron = Path(iron).resolve()
    if not (iron / "mix.exs").is_file():
        raise DemoError("Pass the Ironhold checkout directory")
    if not shutil.which("mix"):
        raise DemoError("Elixir/mix must be on PATH")
    closed_ports()
    message = json.dumps({"run": uuid.uuid4().hex[:12], "secret": secrets.token_hex(32)}) + "\n"
    env = os.environ.copy()
    env.update(MIX_ENV="dev", TIDEWAKE_ENABLE_OUTBOUND_HTTP="true", TIDEWAKE_ALLOW_LOCAL_WEBHOOK_TARGETS="true")
    iron_env = env.copy()
    for name in ("MIX_DEPS_PATH", "MIX_BUILD_PATH"):
        iron_env.pop(name, None)
        if "IRONHOLD_" + name in env:
            iron_env[name] = env["IRONHOLD_" + name]
    receiver = sender = collector = None
    lines = queue.Queue()
    receiver_lines = []

    def collect():
        for line in receiver.stdout:
            lines.put(line.rstrip())
        lines.put(None)

    try:
        receiver = launch("receiver", iron, iron_env)
        collector = threading.Thread(target=collect, daemon=True)
        collector.start()
        receiver.stdin.write(message)
        receiver.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DemoError("Receiver readiness timed out")
            try:
                line = lines.get(timeout=remaining)
            except queue.Empty:
                raise DemoError("Receiver readiness timed out") from None
            if line is None:
                raise DemoError("Receiver exited before readiness")
            receiver_lines.append(line)
            display(line)
            if line == "DEMO receiver READY":
                break
        if receiver.poll() is not None:
            raise DemoError("Receiver exited after readiness")
        sender = launch("sender", ROOT, env)
        try:
            output, _ = sender.communicate(message, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise DemoError("Sender timed out") from None
        for line in output.splitlines():
            display(line)
        if sender.returncode != 0 or "DEMO sender COMPLETE" not in output.splitlines():
            raise DemoError("Sender failed or did not complete all checks")
        if receiver.poll() is not None:
            raise DemoError("Receiver exited before shutdown")
    finally:
        if receiver is not None and receiver.poll() is None:
            try:
                receiver.stdin.write("stop\n")
                receiver.stdin.flush()
            except OSError:
                pass
        cleanup_failed = False
        for child in (sender, receiver):
            try:
                stop(child, grace)
            except (DemoError, OSError, subprocess.SubprocessError):
                cleanup_failed = True
        if collector is not None:
            collector.join(timeout=5)
            cleanup_failed = cleanup_failed or collector.is_alive()
        while not lines.empty():
            line = lines.get()
            if line is not None:
                receiver_lines.append(line)
                display(line)
        for child in (sender, receiver):
            if child is not None and child.poll() is not None:
                try:
                    child.stdin.close()
                except OSError:
                    pass
                if not cleanup_failed:
                    child.stdout.close()
        closed_ports()
        if cleanup_failed:
            raise DemoError("Child process cleanup failed")
    if receiver.returncode != 0 or "DEMO receiver COMPLETE" not in receiver_lines:
        raise DemoError("Receiver failed or did not shut down cleanly")
    print("DEMO PASS: both processes exited cleanly; contracts checked; listeners closed")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ironhold")
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be finite and positive")
    try:
        run_demo(args.ironhold, timeout=args.timeout)
    except (DemoError, OSError, subprocess.SubprocessError):
        print("DEMO FAIL: startup, contract, timeout or cleanup check failed; raw output withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda _signal, _frame: sys.exit(143))
    sys.exit(main())
