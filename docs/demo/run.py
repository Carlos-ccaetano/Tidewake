"""Run two real development services. Secrets travel only over child stdin pipes."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import threading
import queue
import uuid

root = Path(__file__).resolve().parents[2]
iron = Path(sys.argv[1]).resolve()
assert (iron / "mix.exs").is_file(), "Pass the Ironhold checkout directory"
assert shutil.which("mix"), "Elixir/mix must be on PATH"
run = uuid.uuid4().hex[:12]
message = json.dumps({"run": run, "secret": secrets.token_hex(32)}) + "\n"
script = str(Path(__file__).with_name("local.exs"))
env = os.environ.copy()
env.update(MIX_ENV="dev", TIDEWAKE_ENABLE_OUTBOUND_HTTP="true", TIDEWAKE_ALLOW_LOCAL_WEBHOOK_TARGETS="true")
# Separate caches may be supplied for hosts whose OneDrive dependency directories are read-only.
iron_env = env.copy()
for name in ("MIX_DEPS_PATH", "MIX_BUILD_PATH"):
    if "IRONHOLD_" + name in env:
        iron_env[name] = env["IRONHOLD_" + name]
    else:
        iron_env.pop(name, None)
def launch(role, cwd, child_env):
    args = [shutil.which("mix"), "run", "--no-start", script, role]
    command = 'cmd.exe /d /s /c "' + subprocess.list2cmdline(args) + '"' if os.name == "nt" else args
    return subprocess.Popen(command, cwd=cwd, env=child_env, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=os.name != "nt")

def stop(child):
    if child is None or child.poll() is not None:
        return
    try:
        child.wait(timeout=30)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        else:
            import signal
            os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=10)

receiver = launch("receiver", iron, iron_env)
sender = None
lines = queue.Queue()
def collect():
    for line in receiver.stdout:
        lines.put(line.rstrip())
    lines.put(None)
collector = threading.Thread(target=collect, daemon=True)
collector.start()
try:
    receiver.stdin.write(message)
    receiver.stdin.flush()
    while True:
        line = lines.get(timeout=300)
        if line is None:
            raise RuntimeError("Receiver exited before readiness")
        # Only harness allowlisted output is shown; no raw application/compiler logs.
        if line.startswith("DEMO "):
            print(line, flush=True)
        if line == "DEMO receiver READY":
            break
    sender = launch("sender", root, env)
    output, _ = sender.communicate(message, timeout=300)
    for line in output.splitlines():
        if line.startswith("DEMO "):
            print(line)
    if sender.returncode or "DEMO credential revoked" not in output:
        raise RuntimeError("Sender failed; raw output withheld")
finally:
    if receiver.poll() is None:
        try:
            receiver.stdin.write("stop\n")
            receiver.stdin.flush()
        except OSError:
            pass
    stop(sender)
    stop(receiver)
    collector.join(timeout=5)
    while not lines.empty():
        line = lines.get()
        if line and line.startswith("DEMO "):
            print(line)
if receiver.returncode:
    raise RuntimeError("Receiver failed")
print("DEMO PASS: isolated rehearsal; databases retained; no secrets printed")