"""Runner lifecycle checks use real child processes, never live service secrets."""
import contextlib
import io
import json
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

    def test_child_output_redacts_credentials_payloads_and_warnings(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            run.display("Authorization: Bearer synthetic-token")
            run.display("Tidewake-Signature: v1=synthetic-signature")
            run.display('{"payload": "synthetic-private-data"}')
            run.display("warning: request contained synthetic-secret")
        self.assertEqual(output.getvalue(), "DEMO diagnostic: child warning observed (details redacted)\n")


@unittest.skipUnless(os.environ.get("IRONHOLD_CHECKOUT"), "Requires prepared real services and PostgreSQL")
class ContractFailureTest(unittest.TestCase):
    def run_failure(self, extra_replacement=None):
        original = run.SCRIPT.read_text(encoding="utf-8")
        expected = 'expected_status = 202'
        self.assertEqual(original.count(expected), 1)
        modified = original.replace(expected, 'expected_status = 201')
        if extra_replacement:
            before, after = extra_replacement
            self.assertEqual(modified.count(before), 1)
            modified = modified.replace(before, after)
        secret = run.secrets.token_hex(32)
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "local.exs"
            script.write_text(modified, encoding="utf-8")
            output = io.StringIO()
            with patch.object(run, "SCRIPT", script), patch.object(run.secrets, "token_hex", return_value=secret), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                code = run.main([os.environ["IRONHOLD_CHECKOUT"]])
            transcript = output.getvalue()
            self.assertEqual(code, 1)
            self.assertIn("DEMO ingestion:", transcript)
            self.assertIn("DEMO credential revoked", transcript)
            self.assertIn("DEMO receiver COMPLETE", transcript)
            self.assertNotIn("DEMO PASS", transcript)
            self.assertFalse(secret in transcript, "Signing secret appeared in child output")
            for line in transcript.splitlines():
                if line.startswith("DEMO diagnostic:"):
                    print(line)
        run.closed_ports()
        return transcript

    def assert_status_mismatch(self, transcript):
        lines = transcript.splitlines()
        prefix = "DEMO worker_status "
        observations = [json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)]
        self.assertTrue(observations == [{"observed": 202, "expected": 201}], "Missing unique persisted HTTP 202 observation against expected 201")
        failures = [line.split(" (", 1)[0] for line in lines if line.startswith("DEMO FAILED ")]
        self.assertEqual(failures, ["DEMO FAILED stage=worker_http_status_mismatch"])

    def test_real_http_contract_mismatch_returns_failure(self):
        transcript = self.run_failure()
        self.assert_status_mismatch(transcript)
        for line in transcript.splitlines():
            if line.startswith(("DEMO worker_status ", "DEMO FAILED stage=worker_http_status_mismatch ")):
                print(line)
        print("DEMO negative control: observed=202 expected=201; worker_http_status_mismatch detected; exit=1; listeners closed")

    def test_observation_requires_specific_mismatch_cause(self):
        observation = 'DEMO worker_status {"observed":202,"expected":201}\n'
        mismatch = "DEMO FAILED stage=worker_http_status_mismatch (details suppressed)"
        for transcript in (
            observation + "DEMO FAILED stage=provision_and_http (details suppressed)",
            observation.replace('202', '500') + mismatch,
            observation * 2 + mismatch,
        ):
            with self.subTest(transcript=transcript), self.assertRaises(AssertionError):
                self.assert_status_mismatch(transcript)

    def test_failure_before_status_check_is_not_valid_negative_control(self):
        query = '[[http_status]] = query.("SELECT http_status FROM delivery_attempts")'
        transcript = self.run_failure((query, 'raise "Injected failure before status observation"\n      ' + query))
        self.assertIn("DEMO FAILED stage=provision_and_http ", transcript)
        self.assertNotIn("DEMO worker_status ", transcript)
        with self.assertRaises(AssertionError):
            self.assert_status_mismatch(transcript)
        print("DEMO negative control: pre-status failure rejected; exit=1; listeners closed")

    def test_worker_error_is_not_valid_negative_control(self):
        drain = '%{success: 1, failure: 0} = Oban.drain_queue(queue: :default)'
        failure = '''Application.delete_env(:tidewake, :webhook_signing_secret)
      %{success: 0, discard: 1} = Oban.drain_queue(queue: :default)
      IO.puts("DEMO injected_worker_failure: success=0 discard=1")
      raise "Injected worker failure"'''
        transcript = self.run_failure((drain, failure))
        self.assertIn("DEMO injected_worker_failure: success=0 discard=1", transcript)
        self.assertIn("DEMO FAILED stage=provision_and_http ", transcript)
        self.assertNotIn("DEMO worker_status ", transcript)
        with self.assertRaises(AssertionError):
            self.assert_status_mismatch(transcript)
        print("DEMO negative control: actual worker error rejected; exit=1; listeners closed")


if __name__ == "__main__":
    unittest.main()
