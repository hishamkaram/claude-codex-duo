#!/usr/bin/env python3
"""Durable runner protocol tests, independent of process-table fixtures."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "plugins/codex-pr-review/scripts/codex-run.sh"
spec = importlib.util.spec_from_file_location("ccr_job", RUNNER.with_name("ccr-job.py"))
job = importlib.util.module_from_spec(spec)
spec.loader.exec_module(job)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, FAKE_CCR_STORE=str(self.root / "store"))
        self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
        self.prefix = self.root / "attempt"
        self.prompt = self.root / "prompt"
        self.prompt.write_text("Review the code without edits.")
        executable = self.root / "ccr"
        executable.write_text('''#!/bin/sh
case "$1" in
version) echo 'ccr 0.6.0';;
model) printf '%s\\n' '{"provider":"fixture","provider_model":"model","claude_model_id":"anthropic.ccr.x","compatibility":"degraded","effective_capabilities":{"supports_tools":true}}';;
*) exec python3 ''' + shlex.quote(str(ROOT / "scripts/fake-ccr-jobs.py")) + ''' "$@";;
esac
''')
        executable.chmod(0o755)
        probe = self.run_runner("--probe", "--via", "ccr:x", "--record-dir", str(self.root))
        self.assertEqual(probe.returncode, 0, probe.stdout + probe.stderr)

    def run_runner(self, *args, **env):
        return subprocess.run(["bash", str(RUNNER), *args], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=15)

    def launch(self, **env):
        return self.run_runner(str(self.prefix), "--via", "ccr:x", "--prompt-file", str(self.prompt),
                               "--poll-sec", "1", **env)

    def test_submission_lookup_recovers_lost_receipt_without_another_job(self):
        before = len(list((self.root / "store/fake-ccr-jobs").glob("*.json")))
        result = self.launch(FAKE_CCR_DROP_RECEIPT="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = job.load(str(self.prefix) + ".ccr-attempt.json")
        self.assertEqual(value["submission_id"], value["receipt"]["submission_id"])
        self.assertEqual(len(list((self.root / "store/fake-ccr-jobs").glob("*.json"))), before + 1)

    def test_resume_last_rejected_before_claim_or_admission(self):
        claim = Path(str(self.prefix) + ".claim")
        claim.mkdir()
        (claim / "owner").write_text("token=original\n")
        before = list((self.root / "store/fake-ccr-jobs").glob("*.json"))
        result = self.run_runner(str(self.prefix), "--via", "ccr:x", "--resume-last",
                                 "--claim", "original", "--prompt-file", str(self.prompt), "--poll-sec", "1")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertEqual((claim / "owner").read_text(), "token=original\n")
        self.assertFalse((claim / "runner").exists())
        self.assertFalse(Path(str(self.prefix) + ".ccr-attempt.json").exists())
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        self.assertEqual(list((self.root / "store/fake-ccr-jobs").glob("*.json")), before)

    def test_attach_continuation_preserves_requested_session_metadata(self):
        self.assertEqual(self.launch().returncode, 0)
        previous = job.load(str(self.prefix) + ".ccr-attempt.json")["receipt"]
        prefix = str(self.root / "unwatched-continuation")
        args = ["python3", str(RUNNER.with_name("ccr-job.py")), "admit", prefix,
                "x", "anthropic.ccr.x", "100", str(RUNNER), "{}", "0.6.0", "5", "10", "25", "1",
                "ccr", "launch", "--model", "x", "--detach", "--prompt-file", str(self.prompt),
                "--resume=" + previous["session_id"], "--expected-parent-job=" + previous["job_id"]]
        admitted = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(admitted.returncode, 0, admitted.stderr)
        attached = self.run_runner(prefix, "--attach", "--poll-sec", "1")
        self.assertEqual(attached.returncode, 0, attached.stdout + attached.stderr)
        meta = Path(prefix + ".meta").read_text()
        self.assertIn("mode=--resume-session\n", meta)
        self.assertIn("resume_session=" + previous["session_id"], meta.splitlines())
        self.assertIn("requested_resume_session=" + previous["session_id"] + "\n", meta)

    def test_guarded_resume_has_new_job_and_same_session(self):
        first = self.launch()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        previous = job.load(str(self.prefix) + ".ccr-attempt.json")["receipt"]
        next_prefix = self.root / "round-two"
        resumed = self.run_runner(str(next_prefix), "--via", "ccr:x", "--resume-session", previous["session_id"],
                                  "--expected-parent-job", previous["job_id"], "--prompt-file", str(self.prompt), "--poll-sec", "1")
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        value = job.load(str(next_prefix) + ".ccr-attempt.json")
        self.assertEqual(value["receipt"]["session_id"], previous["session_id"])
        self.assertNotEqual(value["receipt"]["job_id"], previous["job_id"])
        self.assertEqual(value["expected_parent_job"], previous["job_id"])
        self.assertFalse(value["fresh_decision"])

    def test_lookup_timeout_retains_complete_conflicting_stdout(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        value = job.load(prefix + ".ccr-attempt.json")
        conflicting = dict(value["receipt"], job_id="ccr-" + str(uuid.uuid4()))
        executable = self.root / "ccr"
        executable.write_text("#!" + sys.executable + "\nimport time\nprint(" + repr(json.dumps(conflicting)) + ", flush=True)\ntime.sleep(25)\n")
        with self.assertRaises(ValueError):
            job.lookup_submission(prefix, value)  # Real process, production 20s timeout.
        self.assertTrue(any(json.loads(path.read_bytes()).get("job_id") == conflicting["job_id"]
                            for path in job.observation_paths(prefix, "capture")))
        Path(prefix + ".ccr-admission-conflict.json").unlink(missing_ok=True)
        executable.write_text("#!" + sys.executable + "\nprint(" + repr(json.dumps(value["receipt"])) + ")\n")
        with self.assertRaises(ValueError):
            job.recover(prefix)
        with self.assertRaises(ValueError):
            job.bound_attempt(prefix)

    def test_helper_loss_preserves_capture_and_excludes_surviving_writer(self):
        self.assertEqual(self.launch().returncode, 0)
        for operation in ("recover", "complete-admission"):
            with self.subTest(operation=operation):
                prefix = str(self.root / ("capture-" + operation))
                value = job.load(str(self.prefix) + ".ccr-attempt.json")
                original = value["receipt"]
                if operation == "recover":
                    value.pop("receipt")
                job.atomic(prefix + ".ccr-attempt.json", job.encode(value))
                job.atomic(prefix + ".ccr-receipt.json", job.encode(original))
                job.atomic(prefix + ".ccr-prompt", self.prompt.read_bytes())
                conflicting = dict(original, job_id="ccr-" + str(uuid.uuid4()))
                ready, stop = Path(prefix + ".ready"), Path(prefix + ".stop")
                script = "#!" + sys.executable + "\nimport sys,time,pathlib\n"
                if operation == "complete-admission":
                    script += "if sys.argv[1] == 'status':\n print(" + repr(json.dumps(dict(original, admission_state="prepared"))) + "); sys.exit(0)\n"
                script += "print(" + repr(json.dumps(conflicting)) + ",flush=True)\npathlib.Path(" + repr(str(ready)) + ").touch()\n"
                script += "deadline=time.monotonic()+10\nwhile not pathlib.Path(" + repr(str(stop)) + ").exists() and time.monotonic()<deadline: time.sleep(.02)\n"
                (self.root / "ccr").write_text(script)
                helper = subprocess.Popen([sys.executable, str(RUNNER.with_name("ccr-job.py")), operation, prefix],
                                          env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and helper.poll() is None and time.monotonic() < deadline:
                        time.sleep(.02)
                    self.assertTrue(ready.exists())
                    # This is the directly owned test helper, never a workload PID.
                    helper.kill()
                    helper.communicate(timeout=5)
                    self.assertFalse(Path(prefix + ".ccr-admission-conflict.json").exists())
                    with self.assertRaisesRegex(ValueError, "still being captured"):
                        job.bound_attempt(prefix)
                    captures = job.observation_paths(prefix, "capture")
                    self.assertTrue(captures)
                    stop.touch()  # The response writer exits cooperatively.
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            job.bound_attempt(prefix)
                        except ValueError as exc:
                            if "still being captured" not in str(exc):
                                self.assertIn("conflicting admission", str(exc))
                                break
                        else:
                            self.fail("contradictory capture accepted after helper loss")
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    self.assertTrue(any(json.loads(path.read_bytes()).get("job_id") == conflicting["job_id"] for path in captures))
                    self.assertFalse(Path(prefix + ".exit").exists())
                finally:
                    stop.touch()
                    if helper.poll() is None:
                        helper.kill()
                    helper.communicate(timeout=5)

    def test_persisted_replay_conflict_survives_collector_loss(self):
        self.assertEqual(self.launch().returncode, 0)
        original_value = job.load(str(self.prefix) + ".ccr-attempt.json")
        original = original_value["receipt"]
        replacement = dict(original, job_id="ccr-" + str(uuid.uuid4()))
        for boundary in (".ccr-observation.resubmission_receipt.", ".ccr-recovery-receipt.json"):
            with self.subTest(boundary=boundary):
                prefix = str(self.root / ("crash[" + str(len(list(self.root.iterdir()))) + "]"))
                job.atomic(prefix + ".ccr-attempt.json", job.encode(original_value))
                before = job.encode(original)
                job.atomic(prefix + ".ccr-receipt.json", before)
                job.atomic(prefix + ".ccr-prompt", self.prompt.read_bytes())
                atomic = job.atomic

                class CollectorLoss(Exception):
                    pass

                def interrupted(path, raw):
                    atomic(path, raw)
                    if boundary in str(path):
                        raise CollectorLoss()

                def response(argv, **kwargs):
                    if argv[1] == "status":
                        kwargs["stdout"].write(job.encode(dict(original, admission_state="prepared")))
                        return subprocess.CompletedProcess(argv, 0)
                    kwargs["stdout"].write(job.encode(replacement))
                    return subprocess.CompletedProcess(argv, 0)

                with mock.patch.object(job, "atomic", side_effect=interrupted), mock.patch.object(job.subprocess, "run", side_effect=response):
                    with self.assertRaises(CollectorLoss):
                        job.complete_admission(prefix)
                self.assertFalse(Path(prefix + ".ccr-admission-conflict.json").exists())
                evidence = {path: path.read_bytes() for path in job.observation_paths(prefix)}
                self.assertIn(job.encode(replacement), evidence.values())
                for operation, args in (("recover", []), ("complete-admission", []),
                                        ("verify-attempt", [original["job_id"]]), ("cancel-attempt", []),
                                        ("freeze", [original["job_id"]]), ("stopped", [])):
                    with mock.patch.object(job.subprocess, "run", side_effect=AssertionError("must not invoke CCR")):
                        with self.assertRaises(ValueError, msg=operation):
                            job.dispatch(operation, prefix, args)
                    self.assertEqual(Path(prefix + ".ccr-receipt.json").read_bytes(), before)
                    self.assertEqual({path: path.read_bytes() for path in job.observation_paths(prefix)}, evidence)
                    self.assertFalse(Path(prefix + ".exit").exists())

    def test_complete_bad_lookup_remains_unresolved_after_matching_retry(self):
        self.assertEqual(self.launch().returncode, 0)
        for operation in ("recover", "complete-admission"):
            for field, replacement in (("submission_id", "different"),
                                       ("session_id", str(uuid.uuid4())), ("job_id", 123)):
                with self.subTest(operation=operation, field=field):
                    prefix = str(self.root / (operation + field))
                    value = job.load(str(self.prefix) + ".ccr-attempt.json")
                    original = value.pop("receipt")
                    value["requested_resume_session"] = original["session_id"]
                    value["argv"].append("--resume=" + original["session_id"])
                    job.atomic(prefix + ".ccr-attempt.json", job.encode(value))
                    job.atomic(prefix + ".ccr-receipt.json", job.encode(original))
                    command = ["python3", str(RUNNER.with_name("ccr-job.py")), operation, prefix]
                    bad = subprocess.run(command, env=dict(self.env, FAKE_CCR_BAD_STATUS=json.dumps({field: replacement})),
                                         capture_output=True, timeout=10)
                    self.assertEqual(bad.returncode, 6, bad.stderr)
                    evidence = {path: path.read_bytes() for path in job.observation_paths(prefix)}
                    self.assertTrue(any(json.loads(raw).get(field) == replacement for raw in evidence.values()))
                    # Even loss of the optional diagnostic marker cannot clear evidence.
                    Path(prefix + ".ccr-admission-conflict.json").unlink(missing_ok=True)
                    retry = subprocess.run(command, env=self.env, capture_output=True, timeout=10)
                    self.assertEqual(retry.returncode, 6, retry.stderr)
                    self.assertEqual({path: path.read_bytes() for path in job.observation_paths(prefix)}, evidence)
                    self.assertEqual(job.load(prefix + ".ccr-receipt.json"), original)
                    self.assertFalse(Path(prefix + ".exit").exists())

    def test_fresh_attempt_rotation_preserves_old_observations(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        previous = {path.name: path.read_bytes() for path in
                    job.observation_paths(prefix) + job.observation_paths(prefix, "capture")}
        self.assertTrue(previous)
        self.assertEqual(self.launch().returncode, 0)
        for name, raw in previous.items():
            rotated = self.root / name.replace("attempt.", "attempt.attempt1.", 1)
            self.assertEqual(rotated.read_bytes(), raw)
        self.assertNotEqual(job.load(prefix + ".ccr-attempt.json")["receipt"],
                            job.load(prefix + ".attempt1.ccr-attempt.json")["receipt"])

    def test_submission_identity_validation_has_no_other_receipt_dependency(self):
        admitted = dict(submission_id="unexpected", job_id="ccr-" + str(uuid.uuid4()), session_id=str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            job.admission_identity(dict(schema=2, submission_id="expected"), admitted)

    def test_observation_retention_is_idempotent_and_detects_changed_bytes(self):
        prefix = str(self.root / "prefix[with]glob")
        admitted = dict(submission_id="s", job_id="ccr-" + str(uuid.uuid4()), session_id=str(uuid.uuid4()))
        raw = job.encode(admitted)
        for _ in range(3):
            job.retain_observation(prefix, "submission_lookup", raw)
        paths = job.observation_paths(prefix)
        self.assertEqual(len(paths), 1)
        value = dict(schema=2, submission_id="s")
        job.validate_observations(prefix, value)
        paths[0].write_bytes(job.encode(dict(admitted, submission_id="changed")))
        with self.assertRaises(ValueError):
            job.validate_observations(prefix, value)

    def test_recovery_preserves_conflicting_complete_receipt(self):
        self.assertEqual(self.launch().returncode, 0)
        for operation in ("recover", "complete-admission"):
            for field in ("job_id", "session_id"):
                with self.subTest(operation=operation, field=field):
                    prefix = str(self.root / (operation + field))
                    value = job.load(str(self.prefix) + ".ccr-attempt.json")
                    original = value.pop("receipt")
                    job.atomic(prefix + ".ccr-attempt.json", job.encode(value))
                    receipt_bytes = json.dumps(original, indent=2).encode()
                    job.atomic(prefix + ".ccr-receipt.json", receipt_bytes)
                    replacement = ("ccr-" if field == "job_id" else "") + str(uuid.uuid4())
                    invoked = self.root / "unexpected-invocation"
                    command = ["python3", str(RUNNER.with_name("ccr-job.py")), operation, prefix]
                    result = subprocess.run(command, env=dict(self.env, FAKE_CCR_BAD_STATUS=json.dumps(
                        {field: replacement, "admission_state": "prepared"}), FAKE_CCR_ARGV_OUT=str(invoked)),
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
                    self.assertEqual(Path(prefix + ".ccr-receipt.json").read_bytes(), receipt_bytes)
                    self.assertNotIn("receipt", job.load(prefix + ".ccr-attempt.json"))
                    conflict = job.load(prefix + ".ccr-admission-conflict.json")
                    self.assertEqual(conflict["saved_receipt"], original)
                    self.assertEqual(conflict["observed_identity"][field], replacement)
                    self.assertFalse(invoked.exists())
                    retry = subprocess.run(command, env=self.env, capture_output=True, timeout=10)
                    self.assertEqual(retry.returncode, 6)
                    self.assertFalse(Path(prefix + ".exit").exists())

    def test_prepared_resubmission_preserves_conflicting_returned_receipt(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        value = job.load(prefix + ".ccr-attempt.json")
        original = value["receipt"]
        before = Path(prefix + ".ccr-receipt.json").read_bytes()
        replacement = dict(original, job_id="ccr-" + str(uuid.uuid4()))
        executable = self.root / "ccr"
        script = executable.read_text().replace("#!/bin/sh\n", "#!/bin/sh\n" +
            'if [ "$1" = launch ] && [ -n "${FAKE_REPLAY_RECEIPT:-}" ]; then printf "%s\\n" "$FAKE_REPLAY_RECEIPT"; exit 0; fi\n')
        executable.write_text(script)
        result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "complete-admission", prefix],
                                env=dict(self.env, FAKE_REPLAY_RECEIPT=json.dumps(replacement),
                                         FAKE_CCR_BAD_STATUS=json.dumps(dict(admission_state="prepared"))),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertEqual(Path(prefix + ".ccr-receipt.json").read_bytes(), before)
        self.assertEqual(job.load(prefix + ".ccr-recovery-receipt.json"), replacement)
        self.assertEqual(job.load(prefix + ".ccr-admission-conflict.json")["observed_identity"], replacement)

    def test_recovery_repairs_partial_receipt_and_preserves_original_bytes(self):
        self.assertEqual(self.launch().returncode, 0)
        for index, partial in enumerate((b"", b'{"job_id":', b'{"job_id":"incomplete"}')):
            prefix = str(self.root / ("partial-" + str(index)))
            value = job.load(str(self.prefix) + ".ccr-attempt.json")
            original = value.pop("receipt")
            job.atomic(prefix + ".ccr-attempt.json", job.encode(value))
            job.atomic(prefix + ".ccr-receipt.json", partial)
            result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "recover", prefix],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(job.load(prefix + ".ccr-attempt.json")["receipt"], original)
            if partial:
                self.assertEqual(Path(prefix + ".ccr-receipt.observed").read_bytes(), partial)

    def test_submission_status_mismatch_stays_unresolved(self):
        result = self.launch(FAKE_CCR_BAD_STATUS=json.dumps(dict(submission_id="different-submission")))
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def test_resume_lineage_mismatch_stays_unresolved(self):
        self.assertEqual(self.launch().returncode, 0)
        previous = job.load(str(self.prefix) + ".ccr-attempt.json")["receipt"]
        prefix = self.root / "bad-lineage"
        self.fast_clock()
        result = self.run_runner(str(prefix), "--via", "ccr:x", "--resume-session", previous["session_id"],
                                 "--expected-parent-job", previous["job_id"], "--prompt-file", str(self.prompt),
                                 "--poll-sec", "1", "--max-min", "1", "--stall-min", "10", FAKE_CCR_BAD_STATUS=json.dumps(dict(resumed_from="ccr-" + str(uuid.uuid4()))))
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(prefix) + ".exit").exists())

    def test_anchor_requires_authoritative_stopped_head(self):
        self.assertEqual(self.launch().returncode, 0)
        value = job.load(str(self.prefix) + ".ccr-attempt.json")
        record_path = self.root / "store/fake-ccr-jobs" / (value["receipt"]["job_id"] + ".json")
        record = job.load(record_path)
        command = ["python3", str(RUNNER.with_name("ccr-job.py")), "resolve-session",
                   str(self.root / "anchor"), record["session_id"]]
        for changes, expected in ((dict(status="failed"), 0),
                                  (dict(workload_disposition="unknown"), 6),
                                  (dict(schema_version=3), 6),
                                  (dict(cleanup=dict(coverage="unknown", survivors=[])), 6)):
            result = subprocess.run(command, env=dict(self.env, FAKE_CCR_BAD_STATUS=json.dumps(changes)),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_malformed_resume_ids_fail_before_claim_mutation(self):
        claim = Path(str(self.prefix) + ".claim")
        claim.mkdir()
        (claim / "owner").write_text("token=original\n")
        for sid, parent in (("not-a-uuid", "ccr-" + str(uuid.uuid4())),
                            (str(uuid.uuid4()), "not-a-job")):
            result = self.run_runner(str(self.prefix), "--via", "ccr:x", "--resume-session", sid,
                                     "--expected-parent-job", parent, "--prompt-file", str(self.prompt))
            self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
            self.assertEqual((claim / "owner").read_text(), "token=original\n")
            self.assertFalse(Path(str(self.prefix) + ".ccr-attempt.json").exists())
            self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def test_not_started_release_requires_aborted_terminal_evidence(self):
        value = dict(schema_version=2, job_id="ccr-" + str(uuid.uuid4()), session_id=str(uuid.uuid4()),
                     status="failed", exit_code=None, workload_disposition="not_started", admission_state="aborted")
        self.assertEqual(job.state(value), "ended")
        for field, wrong in (("status", "completed"), ("exit_code", 0), ("admission_state", "prepared"),
                             ("workload_disposition", "unknown")):
            self.assertEqual(job.state(dict(value, **{field: wrong})), "undetermined")

    def test_prepared_recovery_refuses_changed_submission_argument(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        value = job.load(prefix + ".ccr-attempt.json")
        store = self.root / "store/fake-ccr-jobs"
        original = store / (value["receipt"]["job_id"] + ".json")
        record = job.load(original)
        record.update(status="running", admission_state="prepared", workload_disposition="unknown", fixture_mode="sleep")
        original.write_text(json.dumps(record))
        value["argv"] = [arg for arg in value["argv"] if not arg.startswith("--submission-id=")]
        value["argv"].append("--submission-id=" + uuid.uuid4().hex)
        Path(prefix + ".ccr-attempt.json").write_text(json.dumps(value))
        before = sorted(store.glob("*.json"))
        result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "complete-admission", prefix],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertEqual(sorted(store.glob("*.json")), before)
        self.assertIn("saved invocation identity changed", result.stderr)

    def test_never_started_failure_releases_without_fabricated_exit(self):
        override = dict(status="failed", admission_state="aborted", workload_disposition="not_started",
                        reason_code="admission_interrupted", exit_code=None, result_evidence=None,
                        cleanup=dict(coverage="unknown", survivors=[]))
        result = self.launch(FAKE_CCR_BAD_STATUS=json.dumps(override))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        evidence = job.load(str(self.prefix) + ".ccr-result.json")
        self.assertFalse(evidence["successful"])
        self.assertIsNone(evidence["status"]["exit_code"])
        self.assertEqual(evidence["status"]["cleanup"]["coverage"], "unknown")
        self.assertEqual(Path(str(self.prefix) + ".exit").read_text().strip(), "1")

    def test_fifo_attempt_is_rejected_without_blocking(self):
        os.mkfifo(str(self.prefix) + ".ccr-attempt.json")
        result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "recover", str(self.prefix)],
                                env=self.env, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def fast_clock(self):
        clock = self.root / "date"
        clock.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
if sys.argv[1:] == ['+%s']:
    p = pathlib.Path(__file__).with_name('clock')
    value = int(p.read_text()) + 10 if p.exists() else 100000
    p.write_text(str(value))
    print(value)
else:
    os.execv('/bin/date', ['date'] + sys.argv[1:])
''')
        clock.chmod(0o755)

    def bounded_launch(self, **env):
        self.fast_clock()
        return self.run_runner(str(self.prefix), "--via", "ccr:x", "--prompt-file", str(self.prompt),
                               "--poll-sec", "1", "--max-min", "1", "--stall-min", "10", **env)

    def test_unknown_cleanup_keeps_attempt_open(self):
        result = self.bounded_launch(FAKE_CCR_BAD_STATUS='{"cleanup":{"coverage":"unknown","survivors":[]}}')
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        self.assertTrue(Path(str(self.prefix) + ".detached").exists())

    def test_survivors_prevent_terminal_publication(self):
        result = self.bounded_launch(FAKE_CCR_BAD_STATUS='{"cleanup":{"coverage":"partial","survivors":[{"pid":42}]}}')
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def test_watch_timeout_does_not_cancel_and_attach_does_not_launch(self):
        result = self.bounded_launch(FAKE_CCR_MODE="sleep")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        attempt = job.load(str(self.prefix) + ".ccr-attempt.json")
        jid = attempt["receipt"]["job_id"]
        store = self.root / "store/fake-ccr-jobs"
        self.assertEqual(job.load(store / (jid + ".json"))["status"], "running")
        count = len(list(store.glob("*.json")))
        cancel = self.run_runner(str(self.prefix), "--attach", "--cancel")
        self.assertEqual(cancel.returncode, 0, cancel.stdout + cancel.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        result = self.run_runner(str(self.prefix), "--attach", "--poll-sec", "1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(list(store.glob("*.json"))), count)

    def test_receipt_status_identity_mismatch_is_unresolved(self):
        result = self.bounded_launch(FAKE_CCR_BAD_STATUS=json.dumps({"session_id": str(uuid.uuid4())}))
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def test_stall_requests_owner_cancel_and_confirms_stop(self):
        self.fast_clock()
        result = self.run_runner(str(self.prefix), "--via", "ccr:x", "--prompt-file", str(self.prompt),
                                 "--poll-sec", "1", "--max-min", "10", "--stall-min", "1", FAKE_CCR_MODE="sleep")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("cancel_confirmed=yes", Path(str(self.prefix) + ".meta").read_text())

    def test_success_freezes_result_and_records_owner(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        evidence = job.load(str(self.prefix) + ".ccr-result.json")
        self.assertTrue(evidence["successful"])
        self.assertEqual(Path(str(self.prefix) + ".exit").read_text().strip(), "0")
        self.assertIn("job=ccr-", Path(str(self.prefix) + ".meta").read_text())
        self.assertNotIn("pgid=", Path(str(self.prefix) + ".meta").read_text())

    def test_exact_readonly_arguments_and_prompt_bytes(self):
        self.prompt = self.root / "prompt with spaces.md"
        self.prompt.write_bytes(b"Read only.\nKeep these exact bytes.\n")
        argv_path, input_path = self.root / "argv", self.root / "input"
        result = self.launch(FAKE_CCR_ARGV_OUT=str(argv_path), FAKE_CCR_STDIN_OUT=str(input_path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(input_path.read_bytes(), self.prompt.read_bytes())
        actual_args = argv_path.read_text().splitlines()
        submission = job.load(str(self.prefix) + ".ccr-attempt.json")["submission_id"]
        self.assertEqual(actual_args.pop(), "--submission-id=" + submission)
        self.assertEqual(actual_args, [
            "--model", "x", "--permission-mode", "plan", "-p", "--no-lifecycle", "--no-statusline",
            "--detach", "--prompt-file", str(self.prefix.resolve()) + ".ccr-prompt",
            "--output-format=stream-json", "--verbose", "--strict-mcp-config",
            '--mcp-config={"mcpServers":{}}', "--disallowedTools=Write,Edit,MultiEdit,NotebookEdit,Agent",
            "--max-turns=100"])

    def test_resume_rejected_without_admission_or_claim_mutation(self):
        claim = Path(str(self.prefix) + ".claim")
        claim.mkdir()
        (claim / "owner").write_text("token=example\n")
        before = list(self.root.iterdir())
        result = self.run_runner(str(self.prefix), "--via", "ccr:x", "--resume-session", str(uuid.uuid4()),
                                 "--prompt-file", str(self.prompt), "--claim", "example")
        self.assertEqual(result.returncode, 4)
        self.assertEqual(list(self.root.iterdir()), before)
        self.assertEqual(list(claim.iterdir()), [claim / "owner"])

    def test_lost_receipt_never_closes_or_resubmits(self):
        result = self.launch(FAKE_CCR_MODE="receipt_lost")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        before = list((self.root / "store/fake-ccr-jobs").glob("*.json"))
        retry = self.launch()
        self.assertEqual(retry.returncode, 4)
        attach = self.run_runner(str(self.prefix), "--attach")
        self.assertEqual(attach.returncode, 6)
        self.assertEqual(list((self.root / "store/fake-ccr-jobs").glob("*.json")), before)

    def test_invalid_attach_preserves_unresolved_smoke_admission(self):
        result = self.run_runner("--probe", "--via", "ccr:x", "--record-dir", str(self.root),
                                 FAKE_CCR_MODE="receipt_lost")
        self.assertNotEqual(result.returncode, 0)
        evidence = next(line.removeprefix("CCR smoke evidence: ") for line in result.stderr.splitlines()
                        if line.startswith("CCR smoke evidence: "))
        prefix = str(Path(evidence) / "run")
        self.addCleanup(shutil.rmtree, evidence)
        self.assertTrue(Path(prefix + ".ccr-attempt.json").exists())
        self.assertFalse(Path(prefix + ".progress").exists())
        rejected = self.run_runner(prefix, "--attach", "--poll-sec", "0")
        self.assertEqual(rejected.returncode, 4)
        self.assertFalse(Path(prefix + ".exit").exists())
        attach = self.run_runner(prefix, "--attach")
        self.assertEqual(attach.returncode, 6)
        retry = self.run_runner(prefix, "--via", "ccr:x", "--prompt-file", str(self.prompt))
        self.assertEqual(retry.returncode, 4)
        self.assertFalse(Path(prefix + ".exit").exists())

    def test_admission_lease_survives_collector_through_receipt_binding(self):
        wrapper = self.root / "admission-helper.py"
        helper = RUNNER.with_name("ccr-job.py")
        wrapper.write_text("""import importlib.util, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('helper', HELPER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = Path(__file__).parent
original = m.atomic
blocked = False
def atomic(path, data):
    global blocked
    if str(path).endswith('.ccr-attempt.json') and not blocked:
        blocked = True
        (root / 'before-attempt').write_text('ready')
        end = time.monotonic() + 10
        while not (root / 'release-attempt').exists():
            if time.monotonic() > end:
                raise RuntimeError('test release missing')
            time.sleep(.02)
    original(path, data)
m.atomic = atomic
try:
    m.main()
finally:
    (root / 'helper-done').write_text('done')
""".replace("HELPER", repr(str(helper))))
        prefix = str(self.root / "admission")
        lock = Path(prefix + ".claim.lock")
        variables = dict(CCR_HELPER=str(wrapper), PREFIX=prefix, ALIAS="x",
                         CLAUDE_MODEL="anthropic.ccr.x", MAX_TURNS="3", MODEL_JSON='{"provider":"fixture"}',
                         CCR_VER="0.5.1", ADMISSION_WAIT="2", CCR_RUNNER=str(RUNNER),
                         STALL_MIN="10", MAX_MIN="1", POLL="1")
        assignment = next(line for line in RUNNER.read_text().splitlines()
                          if line.strip().startswith("RECEIPT_JSON="))
        script = "exec 9>>" + shlex.quote(str(lock)) + "\n"
        script += shlex.join(["python3", str(helper), "lock", "9", "5"]) + "\n"
        script += "\n".join(key + "=" + shlex.quote(value) for key, value in variables.items()) + "\n"
        script += "ARGV=(" + shlex.join(["ccr", "launch", "--model", "x", "--detach", "--prompt-file", str(self.prompt)]) + ")\n"
        script += assignment + "\n"
        process = subprocess.Popen(["bash", "-c", script], env=dict(self.env, FAKE_CCR_HANG_RECEIPT="valid"),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready, release, done = [self.root / name for name in ("before-attempt", "release-attempt", "helper-done")]
        try:
            deadline = time.monotonic() + 8
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline, "admission never reached preparation")
                time.sleep(.02)
            process.kill()
            process.wait()
            with lock.open("rb") as handle:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.write_text("release")
                receipt_path = Path(prefix + ".ccr-receipt.json")
                deadline = time.monotonic() + 1
                while not receipt_path.exists() or not receipt_path.stat().st_size:
                    self.assertLess(time.monotonic(), deadline, "workload admission never returned a receipt")
                    time.sleep(.02)
                self.assertIn("job_id", json.loads(receipt_path.read_text()))
                self.assertFalse(done.exists(), "admission must still be observing the delayed receipt")
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                deadline = time.monotonic() + 4
                while not done.exists():
                    self.assertLess(time.monotonic(), deadline, "helper did not finish publication")
                    time.sleep(.02)
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                admitted = job.load(prefix + ".ccr-attempt.json")
                self.assertEqual(admitted["receipt"], job.load(receipt_path))
                self.assertTrue(Path(prefix + ".detached").exists())
        finally:
            release.write_text("release")
            if process.poll() is None:
                process.kill()
                process.wait()
            deadline = time.monotonic() + 5
            while ready.exists() and not done.exists():
                self.assertLess(time.monotonic(), deadline, "owned admission helper did not finish")
                time.sleep(.02)

    def test_orphaned_mutators_exclude_replacement_until_final_write(self):
        for operation in ("recover", "freeze", "mirror"):
            with self.subTest(operation=operation):
                self.prefix = self.root / operation
                self.assertEqual(self.launch().returncode, 0)
                prefix = str(self.prefix)
                original_job = job.load(prefix + ".ccr-receipt.json")["job_id"]
                Path(prefix + ".exit").unlink()
                Path(prefix + ".ccr-result.json").unlink()
                wrapper = self.root / (operation + "-helper.py")
                ready, release, done = [self.root / (operation + suffix) for suffix in ("-ready", "-release", "-done")]
                wrapper.write_text("""import importlib.util, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location('helper', HELPER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def pause():
    Path(READY).write_text('ready')
    end = time.monotonic() + 20
    while not Path(RELEASE).exists():
        if time.monotonic() >= end:
            raise RuntimeError('fixture release missing')
        time.sleep(.02)
original_atomic, original_snapshot = m.atomic, m.snapshot_log
def atomic(path, data):
    suffix = '.ccr-attempt.json' if OPERATION == 'recover' else '.ccr-result.json'
    if OPERATION != 'mirror' and str(path).endswith(suffix):
        pause()
    original_atomic(path, data)
def snapshot(source, destination, boundary=None):
    if OPERATION == 'mirror':
        pause()
    return original_snapshot(source, destination, boundary)
m.atomic, m.snapshot_log = atomic, snapshot
try:
    m.main()
finally:
    Path(DONE).write_text('done')
""".replace("HELPER", repr(str(RUNNER.with_name("ccr-job.py"))))
                    .replace("OPERATION", repr(operation)).replace("READY", repr(str(ready)))
                    .replace("RELEASE", repr(str(release))).replace("DONE", repr(str(done))))
                script = "exec 9>>" + shlex.quote(prefix + ".claim.lock") + "\n"
                script += shlex.join(["python3", str(RUNNER.with_name("ccr-job.py")), "lock", "9", "5"]) + "\n"
                script += shlex.join(["python3", str(wrapper), operation, prefix, original_job]) + "\ntrue\n"
                process = subprocess.Popen(["bash", "-c", script], env=self.env,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    deadline = time.monotonic() + 8
                    while not ready.exists():
                        self.assertLess(time.monotonic(), deadline, "mutator did not reach final write")
                        time.sleep(.02)
                    process.kill()
                    process.wait()
                    rejected = self.launch()
                    self.assertEqual(rejected.returncode, 4, rejected.stdout + rejected.stderr)
                    self.assertEqual(job.load(prefix + ".ccr-receipt.json")["job_id"], original_job)
                    self.assertFalse(done.exists(), "helper must remain alive through replacement refusal")
                    release.write_text("release")
                    deadline = time.monotonic() + 3
                    while not done.exists():
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    replacement = self.launch()
                    self.assertEqual(replacement.returncode, 0, replacement.stdout + replacement.stderr)
                    admitted = job.load(prefix + ".ccr-attempt.json")["receipt"]
                    self.assertNotEqual(admitted["job_id"], original_job)
                    self.assertEqual(admitted, job.load(prefix + ".ccr-receipt.json"))
                    self.assertEqual(admitted["job_id"], job.load(prefix + ".ccr-result.json")["job_id"])
                finally:
                    release.write_text("release")
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    deadline = time.monotonic() + 3
                    while ready.exists() and not done.exists():
                        self.assertLess(time.monotonic(), deadline, "owned helper did not finish")
                        time.sleep(.02)

    def test_relative_probe_saves_executable_recovery_commands(self):
        result = subprocess.run(["bash", str(RUNNER.relative_to(ROOT)), "--probe", "--via", "ccr:x",
                                 "--record-dir", str(self.root)], cwd=ROOT, env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        location = next(line.split(": ", 1)[1] for line in result.stderr.splitlines()
                        if line.startswith("CCR smoke evidence:"))
        attempt = job.load(Path(location) / "run.ccr-attempt.json")
        self.assertEqual(Path(attempt["runner"]).resolve(), RUNNER.resolve())
        fields = dict(line.split("=", 1) for line in (Path(location) / "run.detached").read_text().splitlines())
        self.assertTrue(Path(shlex.split(fields["attach_command"])[0]).is_file())
        self.assertTrue(Path(shlex.split(fields["cancel_command"])[1]).is_file())

    def test_saved_attach_preserves_limits_and_explicit_overrides(self):
        self.assertEqual(self.bounded_launch(FAKE_CCR_MODE="sleep").returncode, 6)
        fields = dict(line.split("=", 1) for line in
                      Path(str(self.prefix) + ".detached").read_text().splitlines())
        command = shlex.split(fields["attach_command"])
        # Execute the advertised command: checking its text alone would miss
        # an attach path that ignores the saved cancellation policy.
        sleeper = self.root / "sleep"
        sleeper.write_text("#!/bin/sh\nexit 0\n")
        sleeper.chmod(0o700)
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertIn("stall_min=10 max_min=1", Path(str(self.prefix) + ".meta").read_text())
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        self.assertEqual(command[command.index("--poll-sec") + 1], "1")
        result = subprocess.run(command + ["--stall-min", "1", "--max-min", "10"],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("stall_min=1 max_min=10", Path(str(self.prefix) + ".meta").read_text())

    def test_watch_timeout_keeps_admitted_prompt_digest(self):
        for action in ("edit", "delete"):
            with self.subTest(action=action):
                self.prefix = self.root / action
                self.prompt.write_text("Original prompt bytes")
                self.fast_clock()
                process = subprocess.Popen(["bash", str(RUNNER), str(self.prefix), "--via", "ccr:x",
                                            "--prompt-file", str(self.prompt), "--poll-sec", "1",
                                            "--max-min", "1", "--stall-min", "10"],
                                           env=dict(self.env, FAKE_CCR_MODE="sleep"),
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    detached = Path(str(self.prefix) + ".detached")
                    deadline = time.monotonic() + 8
                    while not detached.exists():
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    if action == "edit":
                        self.prompt.write_text("Changed after admission")
                    else:
                        self.prompt.unlink()
                    self.assertEqual(process.wait(timeout=10), 6)
                    expected = job.load(str(self.prefix) + ".ccr-attempt.json")["prompt_sha256"]
                    fields = dict(line.split("=", 1) for line in detached.read_text().splitlines())
                    self.assertEqual(fields["prompt_sha256"], expected)
                    self.assertEqual(self.run_runner(str(self.prefix), "--attach", "--cancel").returncode, 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def test_watcher_death_is_immediately_attachable(self):
        ready, release = self.root / "poll-ready", self.root / "poll-release"
        # The owned polling child announces actual entry and remains alive until
        # after attach, so killing the collector before it sleeps cannot pass.
        sleeper = self.root / "sleep"
        sleeper.write_text("""#!/usr/bin/env python3
import pathlib, sys, time
root = pathlib.Path(__file__).parent
if sys.argv[1:] == ['20']:
    (root / 'poll-ready').write_text('ready')
    end = time.monotonic() + 20
    while not (root / 'poll-release').exists() and time.monotonic() < end:
        time.sleep(.02)
    (root / 'poll-done').write_text('done')
else:
    time.sleep(float(sys.argv[1]))
""")
        sleeper.chmod(0o755)
        process = subprocess.Popen(["bash", str(RUNNER), str(self.prefix), "--via", "ccr:x",
                                    "--prompt-file", str(self.prompt), "--poll-sec", "20"],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 8
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline, "collector never entered polling sleep")
                time.sleep(.05)
            process.kill()
            process.wait(timeout=3)
            result = self.run_runner(str(self.prefix), "--attach", "--poll-sec", "1")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.root / "poll-done").exists(), "polling child exited before recovery")
        finally:
            release.write_text("release")
            if process.poll() is None:
                process.kill()
                process.wait()
            deadline = time.monotonic() + 3
            while ready.exists() and not (self.root / "poll-done").exists():
                self.assertLess(time.monotonic(), deadline, "owned polling fixture did not finish")
                time.sleep(.02)

    def test_saved_commands_cannot_operate_on_replacement_attempt(self):
        self.assertEqual(self.bounded_launch(FAKE_CCR_MODE="sleep").returncode, 6)
        fields = dict(line.split("=", 1) for line in Path(str(self.prefix) + ".detached").read_text().splitlines())
        old_job = fields["job"]
        self.assertEqual(self.run_runner(str(self.prefix), "--attach", "--cancel").returncode, 0)
        self.assertEqual(self.run_runner(str(self.prefix), "--attach", "--poll-sec", "1").returncode, 1)
        self.assertEqual(self.bounded_launch(FAKE_CCR_MODE="sleep").returncode, 6)
        current = job.load(str(self.prefix) + ".ccr-attempt.json")["receipt"]["job_id"]
        self.assertNotEqual(old_job, current)
        for key in ["attach_command", "cancel_command"]:
            with self.subTest(command=key):
                result = subprocess.run(["bash", "-c", fields[key]], env=self.env,
                                        capture_output=True, text=True, timeout=10)
                self.assertIn(result.returncode, (4, 6), result.stdout + result.stderr)
                self.assertEqual(job.load(self.root / "store/fake-ccr-jobs" / (current + ".json"))["status"], "running")
        self.assertEqual(self.run_runner(str(self.prefix), "--attach", "--cancel").returncode, 0)

    def test_write_cancel_refusal_returns_without_wait_or_commit(self):
        repo = self.root / "repository"
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                        "commit", "--allow-empty", "-qm", "base"], check=True)
        head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        ready, release, done = [self.root / x for x in ("write-ready", "write-release", "write-done")]
        worker = self.root / "write-worker.py"
        worker.write_text("""import pathlib, time
root = pathlib.Path(__file__).parent
pathlib.Path('uncommitted.txt').write_text('work in progress')
(root / 'write-ready').write_text('ready')
end = time.monotonic() + 20
while not (root / 'write-release').exists() and time.monotonic() < end:
    time.sleep(.02)
(root / 'write-done').write_text('done')
""")
        ccr = self.root / "ccr"
        ccr.write_text(ccr.read_text().replace('*) exec python3 ',
                       'launch) exec python3 ' + shlex.quote(str(worker)) + ';;\n*) exec python3 '))
        # Initial ownership lookup succeeds; only cancellation-time owner lookup
        # fails. No arbitrary PID/group is ever signalled by this fixture.
        inspector = self.root / "ps"
        inspector.write_text("""#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(__file__).parent
if sys.argv[1:3] == ['-o', 'pgid=']:
    counter = root / 'ps-count'
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    if n >= 3:
        raise SystemExit(1)
os.execv('/bin/ps', ['ps'] + sys.argv[1:])
""")
        inspector.chmod(0o755)
        self.fast_clock()
        prefix = self.root / "write" / "attempt"
        runner = ROOT / "plugins/codex-deep-plan/scripts/implement-run.sh"
        process = subprocess.Popen(["bash", str(runner), str(prefix), "--via", "ccr:x", "--repo", str(repo),
                                    "--base", head, "--branch", "impl/refusal", "--plan", str(self.prompt),
                                    "--poll-sec", "1", "--stall-min", "1", "--max-min", "1"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out, err = process.communicate(timeout=12)
            self.assertEqual(process.returncode, 5, out + err)
            self.assertTrue(ready.exists())
            self.assertFalse(done.exists(), "workload must still be alive at unconfirmed return")
            self.assertEqual(Path(str(prefix) + ".exit").read_text().strip(), "5")
            self.assertIn("launcher_commit=not_attempted", Path(str(prefix) + ".meta").read_text())
            worktree = str(self.root / "write" / "worktree")
            self.assertEqual(subprocess.check_output(["git", "-C", worktree, "rev-parse", "HEAD"], text=True).strip(), head)
            self.assertIn("?? uncommitted.txt", subprocess.check_output(["git", "-C", worktree, "status", "--porcelain"], text=True))
        finally:
            release.write_text("release")
            if process.poll() is None:
                process.kill()
                process.wait()
            deadline = time.monotonic() + 3
            while ready.exists() and not done.exists():
                self.assertLess(time.monotonic(), deadline, "owned write fixture did not finish")
                time.sleep(.02)

    def test_failed_job_cannot_promote_successful_text(self):
        result = self.launch(FAKE_CCR_BAD_STATUS='{"status":"failed","exit_code":0}')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_legacy_progress_refuses_new_admission(self):
        progress = Path(str(self.prefix) + ".progress")
        progress.write_text(f"0s launched backend=ccr pid={os.getpid()} pgid={os.getpgrp()} alias=x\n")
        before = list((self.root / "store/fake-ccr-jobs").glob("*.json"))
        result = self.launch()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("legacy CCR attempt", result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".attempt1.progress").exists())
        self.assertEqual(list((self.root / "store/fake-ccr-jobs").glob("*.json")), before)

    def test_incomplete_legacy_progress_never_rotates_or_admits(self):
        for content in ("", "0s preparing legacy workload\n", "0s launched back"):
            with self.subTest(content=content):
                progress = Path(str(self.prefix) + ".progress")
                progress.write_text(content)
                result = self.launch()
                self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
                self.assertIn("no verifiable workload identity", result.stderr)
                self.assertEqual(progress.read_text(), content)
                self.assertFalse(Path(str(self.prefix) + ".attempt1.progress").exists())
                self.assertFalse(Path(str(self.prefix) + ".ccr-attempt.json").exists())
                self.assertFalse(Path(str(self.prefix) + ".exit").exists())

    def test_kernel_lock_blocks_even_when_process_inspection_fails(self):
        ps = self.root / "ps"
        ps.write_text("#!/bin/sh\nexit 1\n")
        ps.chmod(0o755)
        with open(str(self.prefix) + ".claim.lock", "a") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.launch()
            self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
            self.assertFalse(Path(str(self.prefix) + ".ccr-attempt.json").exists())
        self.assertEqual(self.launch().returncode, 0)
        self.assertTrue(Path(str(self.prefix) + ".claim.lock").is_file())

    def test_incomplete_legacy_collector_lock_is_not_reclaimed(self):
        lock = Path(str(self.prefix) + ".claim.lock")
        lock.mkdir()
        holder = lock / "holder"
        holder.write_text(f"pid={os.getpid()}\nidentity=\n")
        before = holder.read_bytes()
        result = self.launch()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("legacy collector lock", result.stderr)
        self.assertEqual(holder.read_bytes(), before)

    def test_admission_timeout_retains_every_receipt_shape_without_replay(self):
        for shape in ("none", "partial", "valid"):
            with self.subTest(shape=shape):
                prefix = str(self.root / ("admission-" + shape))
                args = ["python3", str(RUNNER.with_name("ccr-job.py")), "admit", prefix,
                        "x", "anthropic.ccr.x", "100", str(RUNNER), "{}", "0.5.1", "0.5", "10", "1", "1",
                        "ccr", "launch", "--model", "x", "--detach", "--prompt-file", str(self.prompt)]
                started = time.monotonic()
                result = subprocess.run(args, env=dict(self.env, FAKE_CCR_HANG_RECEIPT=shape),
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 6, result.stderr)
                self.assertLess(time.monotonic() - started, 4)
                self.assertTrue(Path(prefix + ".ccr-attempt.json").exists())
                self.assertFalse(Path(prefix + ".exit").exists())
                count = len(list((self.root / "store/fake-ccr-jobs").glob("*.json")))
                retry = subprocess.run(args, env=self.env, capture_output=True, timeout=5)
                self.assertEqual(retry.returncode, 6)
                self.assertEqual(len(list((self.root / "store/fake-ccr-jobs").glob("*.json"))), count)
                if shape == "valid":
                    receipt = job.load(prefix + ".ccr-receipt.json")
                    self.assertEqual(job.load(prefix + ".ccr-attempt.json")["receipt"], receipt)
                    self.assertTrue(Path(prefix + ".detached").exists())

    def test_smoke_budget_includes_admission_wait(self):
        record = self.root / "hung-probe"
        record.mkdir()
        started = time.monotonic()
        result = self.run_runner("--probe", "--via", "ccr:x", "--record-dir", str(record),
                                 CODEX_RUN_SMOKE_MAX_SEC="1", FAKE_CCR_HANG_RECEIPT="valid")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("admission unresolved", result.stdout)
        self.assertFalse((record / ".ccr-smoke.x").exists())

    def test_workload_stderr_is_preserved_once(self):
        result = self.launch(FAKE_CCR_MODE="fail")
        self.assertEqual(result.returncode, 1)
        prefix = str(self.prefix)
        self.assertEqual(Path(prefix + ".stderr").read_text(), "fixture failure")
        self.assertIn("last_error=fixture failure", Path(prefix + ".meta").read_text())
        evidence = job.load(prefix + ".ccr-result.json")
        args = ["python3", str(RUNNER.with_name("ccr-job.py")), "freeze", prefix, evidence["job_id"]]
        self.assertEqual(subprocess.run(args, env=self.env, capture_output=True).returncode, 0)
        self.assertEqual(Path(prefix + ".stderr").read_text(), "fixture failure")
        Path(prefix + ".ccr-errorlog").write_text("changed")
        self.assertEqual(subprocess.run(args, env=self.env, capture_output=True).returncode, 6)

    def test_cancel_remains_available_while_collector_is_watching(self):
        process = subprocess.Popen(["bash", str(RUNNER), str(self.prefix), "--via", "ccr:x",
                                    "--prompt-file", str(self.prompt), "--poll-sec", "1"],
                                   env=dict(self.env, FAKE_CCR_MODE="sleep"),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 8
            while not Path(str(self.prefix) + ".detached").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.05)
            receipt = job.load(str(self.prefix) + ".ccr-receipt.json")
            wrong = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "cancel-attempt",
                                    str(self.prefix), "ccr-" + str(uuid.uuid4())],
                                   env=self.env, capture_output=True, timeout=5)
            self.assertEqual(wrong.returncode, 6)
            record = self.root / "store/fake-ccr-jobs" / (receipt["job_id"] + ".json")
            self.assertEqual(job.load(record)["status"], "running")
            invalid = self.run_runner(str(self.prefix), "--attach", "--cancel", "--fresh")
            self.assertEqual(invalid.returncode, 4)
            self.assertEqual(job.load(record)["status"], "running")
            result = self.run_runner(str(self.prefix), "--attach", "--cancel")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(process.wait(timeout=8), 1)
            self.assertEqual(job.load(record)["status"], "cancelled")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_contradictory_committed_model_remains_unresolved(self):
        result = self.launch(FAKE_CCR_CHILD_MODEL="wrong-model")
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        self.assertFalse(Path(str(self.prefix) + ".exit").exists())
        self.assertFalse(Path(str(self.prefix) + ".ccr-result.json").exists())

    def test_first_collection_obeys_ccr_boundary_and_digest(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        evidence = job.load(prefix + ".ccr-result.json")
        source = Path(evidence["status"]["log"])
        original = source.read_bytes()
        command = ["python3", str(RUNNER.with_name("ccr-job.py")), "freeze", prefix, evidence["job_id"]]
        for content, code in ((original + b'{"type":"result","result":"late"}\n', 0),
                              (original[:-1], 6), (original[:-1] + b" ", 6)):
            Path(prefix + ".ccr-result.json").unlink(missing_ok=True)
            source.write_bytes(content)
            result = subprocess.run(command, env=self.env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, code, result.stderr)
            if code == 0:
                self.assertEqual(Path(prefix + ".joblog").read_bytes(), original)
            else:
                self.assertFalse(Path(prefix + ".ccr-result.json").exists())

    def test_result_append_ignored_but_committed_bytes_cannot_change(self):
        self.assertEqual(self.launch().returncode, 0)
        prefix = str(self.prefix)
        evidence = job.load(prefix + ".ccr-result.json")
        with open(evidence["status"]["log"], "a") as stream:
            stream.write('{"type":"result","result":"replacement"}\n')
        # Query fixture storage is environment-bound; test the helper as a caller.
        result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "freeze", prefix, evidence["job_id"]],
                                env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["sha256"], evidence["sha256"])
        Path(prefix + ".joblog").write_text("changed")
        result = subprocess.run(["python3", str(RUNNER.with_name("ccr-job.py")), "freeze", prefix, evidence["job_id"]],
                                env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 6)


class ConsumerSafetyTests(unittest.TestCase):
    def test_unknown_detached_backend_cannot_authorize_replacement(self):
        source = RUNNER.read_text()
        guard = source[source.index("refuse_if_in_flight() {"):source.index("rotate_previous_attempt() {")]
        for backend in ("", "unknown"):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory() as directory:
                prefix = str(Path(directory) / "attempt")
                detached = Path(prefix + ".detached")
                detached.write_text("backend=" + backend + "\n")
                Path(prefix + ".progress").write_text("work still unresolved\n")
                before = detached.read_bytes()
                script = guard + """
detached_field() { awk -F= -v key="$1" '$1==key{print $2;exit}' "$PREFIX.detached"; }
refuse_if_in_flight
printf replacement > "$PREFIX.launched"
"""
                result = subprocess.run(["bash", "-c", script], env=dict(os.environ, PREFIX=prefix),
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertFalse(Path(prefix + ".launched").exists())
                self.assertFalse(Path(prefix + ".exit").exists())
                self.assertEqual(detached.read_bytes(), before)

    def test_saved_codex_command_resolves_relative_prefix_before_cwd_changes(self):
        source = RUNNER.read_text().splitlines()
        quote = next(line for line in source if line.startswith("quote_command()"))
        assignment = next(line.strip() for line in source if "ATTACH_CMD=" in line and "$PREFIX" in line and "--stall-min" in line)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            other = root / "other"
            other.mkdir()
            runner = root / "capture"
            runner.write_text("#!/bin/sh\n[ -f \"$1.detached\" ]\n")
            runner.chmod(0o700)
            (root / "relative.detached").write_text("owned attempt")
            env = dict(os.environ, CCR_RUNNER=str(runner), PREFIX="relative", STALL_MIN="1", MAX_MIN="2", POLL="3")
            result = subprocess.run(["bash", "-c", quote + "\n" + assignment + '\nprintf "%s\\n" "$ATTACH_CMD"'],
                                    cwd=root, env=env, capture_output=True, text=True, check=True)
            command = shlex.split(result.stdout)
            self.assertTrue(Path(command[1]).is_absolute())
            attached = subprocess.run(command, cwd=other, capture_output=True, text=True)
            self.assertEqual(attached.returncode, 0, attached.stderr)

    def test_fixture_stop_is_cooperative_and_releases_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stop, ready, lease_path = (root / name for name in ("stop", "ready", "lease"))
            fixture = Path(__file__).resolve().parent / "fixture-process.py"
            process = subprocess.Popen([sys.executable, str(fixture), str(stop), "--lease", str(lease_path), "--ready", str(ready), "--lifetime", "5"])
            try:
                deadline = time.monotonic() + 3
                while not ready.exists():
                    self.assertIsNone(process.poll(), "fixture failed before readiness")
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.02)
                with lease_path.open("a") as lease:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    stop.touch()
                    self.assertEqual(process.wait(timeout=3), 0)
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                # Expired fixtures require no signal, even if teardown arrives late.
                stop.touch()
                script = (fixture.parent / "test-args.sh").read_text()
                self.assertNotIn("signal_pid", script)
                for variable in ("CJOB", "WPID", "GH"):
                    self.assertNotRegex(script, r"kill[^\n]*\$" + variable)
            finally:
                stop.touch()
                process.wait(timeout=6)


    def test_unconfirmed_fixture_cleanup_never_signals_saved_group(self):
        source = (ROOT / "scripts/test-args.sh").read_text()
        helpers = ""
        if "signal_group() {" in source:
            helpers = source[source.index("signal_group() {"):source.index("# Group liveness")]
        branch = next(line for line in source.splitlines() if "T-15(stall): rc=" in line)
        script = helpers + '''
ps() { return 1; }
kill() { printf 'SIGNAL %s\\n' "$*"; }
rc=5; PG=424242; FAIL=0
''' + branch + '\n[ "$FAIL" = 1 ]\n'
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FAIL", result.stdout)
        self.assertNotIn("SIGNAL", result.stdout)
        self.assertNotIn("command not found", result.stderr)

    def test_write_escalation_requires_original_owner_identity(self):
        source = (ROOT / "plugins/codex-deep-plan/scripts/implement-run.sh").read_text()
        functions = source[source.index("pgid_of()"):source.index("stream_field()")]
        for scenario in ("unchanged", "owner-unavailable", "identity-changed"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                script = functions + """
pgid_of() {
  if [ "$1" = "$$" ]; then echo 222222; return; fi
  if [ "$SCENARIO" = owner-unavailable ] && [ -e "$FIXTURE/term" ]; then return 1; fi
  echo 333333
}
proc_identity() {
  if [ "$SCENARIO" = identity-changed ] && [ -e "$FIXTURE/term" ]; then echo replacement; else echo admitted; fi
}
kill() {
  printf '%s\\n' "$*" >> "$FIXTURE/signals"
  [ "$1" != -TERM ] || : > "$FIXTURE/term"
  return 0
}
sleep() { :; }
kill_group 333333 333333 admitted
"""
                result = subprocess.run(["bash", "-c", script],
                                        env=dict(os.environ, FIXTURE=directory, SCENARIO=scenario),
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1, result.stderr)
                signals = (Path(directory) / "signals").read_text()
                self.assertIn("-TERM", signals)
                self.assertEqual("-KILL" in signals, scenario == "unchanged", signals)

    def test_codex_saved_commands_preserve_every_path_argument(self):
        source = RUNNER.read_text().splitlines()
        quote = next(line for line in source if line.startswith("quote_command()"))
        assignments = [line.strip() for line in source
                       if ("ATTACH_CMD=" in line and "$PREFIX" in line and "--stall-min" in line)
                       or ("CANCEL_CMD=" in line and "codex-companion.mjs" in line)]
        self.assertEqual(len(assignments), 2)
        runner = "/tmp/runner 'quoted' $(literal)/codex-run.sh"
        prefix = "/tmp/review with spaces/round;literal"
        plugin = "/tmp/plugin 'quoted' with spaces"
        env = dict(os.environ, CCR_RUNNER=runner, PREFIX=prefix, CODEX_ROOT=plugin,
                   STALL_MIN="1", MAX_MIN="2", POLL="3", JOB="task-123")
        result = subprocess.run(["bash", "-c", quote + "\n" + "\n".join(assignments)
                                 + '\nprintf "%s\\n%s\\n" "$ATTACH_CMD" "$CANCEL_CMD"'],
                                env=env, capture_output=True, text=True, timeout=5, check=True)
        attach, cancel = result.stdout.splitlines()
        self.assertEqual(shlex.split(attach), [runner, prefix, "--attach", "--stall-min", "1",
                                               "--max-min", "2", "--poll-sec", "3"])
        self.assertEqual(shlex.split(cancel), ["node", plugin + "/scripts/codex-companion.mjs", "cancel", "task-123"])


class CodexCollectorTests(unittest.TestCase):
    def test_completed_result_publication_excludes_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            (home / ".claude/plugins").mkdir(parents=True)
            plugin = root / "plugin"
            (plugin / "scripts").mkdir(parents=True)
            (plugin / "scripts/codex-companion.mjs").write_text("fixture")
            (home / ".claude/plugins/installed_plugins.json").write_text(json.dumps({"plugins": {
                "codex@openai-codex": [{"installPath": str(plugin)}]}}))
            binary = root / "node"
            binary.write_text("#!" + sys.executable + "\n" + '''
import pathlib,sys,json,time,os
root=pathlib.Path(os.environ["FIXTURE"]); args=sys.argv[2:]
if args[0]=="task":
    counter=root/"count"; n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n)); print("task-fake-"+str(n))
elif args[0]=="status":
    print(json.dumps({"job":{"status":"completed","logFile":str(root/"log")}}))
elif args[0]=="result":
    (root/"result-ready").touch(); deadline=time.monotonic()+15
    while not (root/"result-go").exists() and time.monotonic()<deadline: time.sleep(.01)
    print("completed result")
''')
            binary.chmod(0o700)
            (root / "prompt").write_text("fixture")
            (root / "log").write_text("fixture log")
            env = dict(os.environ, HOME=str(home), FIXTURE=str(root),
                       PATH=str(root) + os.pathsep + os.environ["PATH"])
            command = ["bash", str(RUNNER), str(root / "attempt"), "--prompt-file",
                       str(root / "prompt"), "--poll-sec", "1"]
            first = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 8
                while not (root / "result-ready").exists():
                    self.assertLess(time.monotonic(), deadline, "first result never became ready")
                    time.sleep(.01)
                try:
                    replacement = subprocess.run(command, env=env, capture_output=True, text=True, timeout=8)
                except subprocess.TimeoutExpired:
                    self.assertEqual((root / "count").read_text(), "1",
                                     "replacement workload launched while first publication was pending")
                    raise
                self.assertEqual(replacement.returncode, 4, replacement.stdout + replacement.stderr)
                self.assertEqual((root / "count").read_text(), "1")
                self.assertFalse((root / "attempt.exit").exists())
                (root / "result-go").touch()
                out, err = first.communicate(timeout=5)
                self.assertEqual(first.returncode, 0, out + err)
                self.assertEqual((root / "attempt.exit").read_text(), "0\n")
                self.assertEqual((root / "attempt.stdout").read_text(), "completed result\n")
                self.assertIn("job=task-fake-1\n", (root / "attempt.meta").read_text())
            finally:
                (root / "result-go").touch()
                if first.poll() is None:
                    first.kill()
                first.communicate(timeout=5)


class ShellMutationLeaseTests(unittest.TestCase):
    def wait_path(self, path):
        deadline = time.monotonic() + 10
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(path.exists(), str(path))

    def test_orphaned_shell_publishers_keep_the_lease(self):
        runner = RUNNER.read_text()
        gate = (ROOT / "plugins/codex-pr-review/skills/two-model-pr-review/scripts/phase-gate.sh").read_text()
        publication = runner[runner.index("write_detached() {"):runner.index("detached_field() {")]
        rotation = gate[gate.index("rotate_claim() {"):gate.index("# release <ART>")]
        removal = next(line for line in runner.splitlines() if line.strip().startswith("rm ")
                       and '"$PREFIX.detached"' in line)
        companion = next(line for line in runner.splitlines() if line.startswith("cc()"))
        cases = [("publish", "mv", publication + '\nwrite_detached <<EOF\njob=old\nEOF\n'),
                 ("claim-rotation", "mv", rotation + '\nrotate_claim attempt\n'),
                 ("terminal-removal", "rm", removal + '\n'),
                 ("companion-result", "node", companion + '\ncc result task-fixture > "$PREFIX.stdout"\n')]
        for name, command, operation in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prefix = root / "attempt"
                Path(str(prefix) + ".claim").mkdir()
                Path(str(prefix) + ".detached").write_text("old")
                wrapper = root / command
                wrapper.write_text("#!" + sys.executable + "\n" + '''
import pathlib, subprocess, sys, time
root = pathlib.Path(__file__).parent
(root / "ready").touch()
deadline = time.monotonic() + 10
while not (root / "go").exists() and time.monotonic() < deadline: time.sleep(.01)
if not (root / "go").exists(): sys.exit(2)
if pathlib.Path(__file__).name == "node": print("old result")
else: subprocess.run(["/bin/" + pathlib.Path(__file__).name, *sys.argv[1:]], check=True)
(root / "done").touch()
''')
                wrapper.chmod(0o700)
                with open(str(prefix) + ".claim.lock", "a+") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX)
                    fd = lease.fileno()
                    script = (f'exec 9>&{fd}; exec {fd}>&-\n'
                              'PREFIX="$1"; ART="$2"; CLAIM_SPENT_MAX=10\n'
                              'fail() { echo "$*" >&2; exit 1; }\n' + operation + '\ntrue\n')
                    process = subprocess.Popen(["bash", "-c", script, "collector", str(prefix), str(root)],
                                               env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"]),
                                               pass_fds=(fd,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                               start_new_session=True)
                try:
                    self.wait_path(root / "ready")
                    process.kill()
                    process.wait(timeout=5)
                    with open(str(prefix) + ".claim.lock", "a+") as replacement:
                        with self.assertRaises(BlockingIOError):
                            fcntl.flock(replacement, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    (root / "go").touch()
                    self.wait_path(root / "done")
                with open(str(prefix) + ".claim.lock", "a+") as replacement:
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            fcntl.flock(replacement, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic() >= deadline:
                                self.fail("finished shell mutator retained the lease")
                            time.sleep(.01)


class StopEvidenceTests(unittest.TestCase):
    def record(self):
        return dict(job_id="ccr-" + str(uuid.uuid4()), session_id=str(uuid.uuid4()),
                    status="completed", exit_code=0, cleanup=dict(coverage="partial", survivors=[]))

    def test_partial_stopped_is_supported(self):
        self.assertEqual(job.state(self.record()), "ended")

    def test_terminal_is_not_stop_proof(self):
        for change in (dict(exit_code=None), dict(exit_code=False),
                       dict(cleanup={"coverage": "unknown", "survivors": []}),
                       dict(cleanup={"coverage": "partial", "survivors": [{"pid": 42}]}),
                       dict(cleanup={"coverage": "complete"}), dict(status="future_status")):
            with self.subTest(change=change):
                record = self.record()
                record.update(change)
                self.assertEqual(job.state(record), "undetermined")


if __name__ == "__main__":
    unittest.main()
