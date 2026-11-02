"""Runner lifecycle checks use real child processes, never live service secrets."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run

RECEIVER = '''import sys
sys.stdin.readline()
print("DEMO receiver READY", flush=True)
sys.stdin.readline()
print("DEMO receiver COMPLETE", flush=True)
'''
SENDER = 'import sys; sys.stdin.read(); print("DEMO sender COMPLETE", flush=True)'


class RunnerTests(unittest.TestCase):
    def exercise(self, receiver=RECEIVER, sender=SENDER, failure=None):
        children = []

        def launch(role, _cwd, _env):
            child = subprocess.Popen([sys.executable, "-u", "-c", receiver if role == "receiver" else sender],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, start_new_session=os.name != "nt")
            children.append(child)
            return child

        output = io.StringIO()
        with patch.object(run, "launch", side_effect=launch), patch.object(run.shutil, "which", return_value=sys.executable), contextlib.redirect_stdout(output):
            if failure:
                with self.assertRaisesRegex(run.DemoError, failure):
                    run.run_demo(run.ROOT, timeout=1, grace=0.2)
                self.assertNotIn("DEMO PASS", output.getvalue())
            else:
                run.run_demo(run.ROOT, timeout=5, grace=1)
                self.assertIn("DEMO PASS", output.getvalue())
        self.assertTrue(all(child.poll() is not None for child in children))
        run.closed_ports()

    def test_success_requires_clean_completion_of_both_processes(self):
        self.exercise()

    def test_success_text_does_not_override_nonzero_sender_exit(self):
        self.exercise(sender=SENDER + '; sys.exit(7)', failure="Sender failed")

    def test_zero_exit_without_checks_is_not_success(self):
        self.exercise(sender='import sys; sys.stdin.read()', failure="Sender failed")

    def test_receiver_failure_on_shutdown_is_not_success(self):
        self.exercise(receiver=RECEIVER + 'sys.exit(9)', failure="Receiver failed")

    def test_receiver_exit_before_readiness(self):
        self.exercise(receiver='import sys; sys.stdin.readline()', failure="before readiness")

    def test_readiness_timeout_stops_receiver(self):
        self.exercise(receiver='import sys; sys.stdin.readline(); sys.stdin.readline()', failure="readiness timed out")

    def test_sender_timeout_stops_both_processes(self):
        self.exercise(sender='import threading; threading.Event().wait()', failure="Sender timed out")

    @unittest.skipIf(os.name == "nt", "Linux process-group escalation")
    def test_timeout_kills_child_ignoring_sigterm(self):
        self.exercise(sender='import signal, threading; signal.signal(signal.SIGTERM, signal.SIG_IGN); threading.Event().wait()', failure="Sender timed out")

    def test_invalid_checkout_is_explicitly_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(run.DemoError, "checkout"):
                run.run_demo(directory)

    def test_missing_mix_is_explicitly_rejected(self):
        with patch.object(run.shutil, "which", return_value=None):
            with self.assertRaisesRegex(run.DemoError, "PATH"):
                run.run_demo(run.ROOT)

    def test_nonfinite_timeout_is_rejected(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as failure:
                run.main([str(run.ROOT), "--timeout", "inf"])
        self.assertEqual(failure.exception.code, 2)


@unittest.skipUnless(os.environ.get("IRONHOLD_CHECKOUT"), "Requires prepared real services and PostgreSQL")
class ContractFailureTest(unittest.TestCase):
    def test_real_http_contract_mismatch_returns_failure(self):
        original = run.SCRIPT.read_text(encoding="utf-8")
        expected = '[[202]] = query.("SELECT http_status FROM delivery_attempts")'
        self.assertEqual(original.count(expected), 1)
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "local.exs"
            script.write_text(original.replace(expected, expected.replace("202", "201")), encoding="utf-8")
            output = io.StringIO()
            with patch.object(run, "SCRIPT", script), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                code = run.main([os.environ["IRONHOLD_CHECKOUT"]])
            self.assertEqual(code, 1)
            self.assertIn("DEMO ingestion:", output.getvalue())
            self.assertIn("DEMO FAILED stage=provision_and_http", output.getvalue())
            self.assertIn("DEMO credential revoked", output.getvalue())
            self.assertIn("DEMO receiver COMPLETE", output.getvalue())
            self.assertNotIn("DEMO PASS", output.getvalue())
            for line in output.getvalue().splitlines():
                if line.startswith("DEMO diagnostic:"):
                    print(line)
        run.closed_ports()
        print("DEMO negative control: actual worker returned 202; incompatible expectation rejected with exit 1; listeners closed")


if __name__ == "__main__":
    unittest.main()
