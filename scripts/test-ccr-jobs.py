#!/usr/bin/env python3
"""Durable runner protocol tests, independent of process-table fixtures."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
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
version) echo 'ccr 0.5.1';;
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
        self.assertEqual(argv_path.read_text().splitlines(), [
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
        result = self.run_runner(str(self.prefix), "--via", "ccr:x", "--resume-last",
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

    def test_admission_lease_survives_collector_until_attempt_is_durable(self):
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
        lock = self.root / "admission-lease"
        prefix = str(self.root / "admission")
        variables = dict(CCR_HELPER=str(wrapper), PREFIX=prefix, ALIAS="x",
                         CLAUDE_MODEL="anthropic.ccr.x", MAX_TURNS="3", MODEL_JSON='{"provider":"fixture"}',
                         CCR_VER="0.5.1", ADMISSION_WAIT="2")
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
                deadline = time.monotonic() + 3
                while True:
                    try:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        self.assertLess(time.monotonic(), deadline, "admission retained lease after durable attempt")
                        time.sleep(.02)
                self.assertTrue(Path(prefix + ".ccr-attempt.json").exists())
                receipt_path = Path(prefix + ".ccr-receipt.json")
                deadline = time.monotonic() + 1
                while not receipt_path.exists() or not receipt_path.stat().st_size:
                    self.assertLess(time.monotonic(), deadline, "workload admission never returned a receipt")
                    time.sleep(.02)
                self.assertIn("job_id", json.loads(receipt_path.read_text()))
                self.assertFalse(done.exists(), "admission must still be observing the delayed receipt")
        finally:
            release.write_text("release")
            if process.poll() is None:
                process.kill()
                process.wait()
            deadline = time.monotonic() + 5
            while ready.exists() and not done.exists():
                self.assertLess(time.monotonic(), deadline, "owned admission helper did not finish")
                time.sleep(.02)

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
                        "x", "anthropic.ccr.x", "100", str(RUNNER), "{}", "0.5.1", "0.5",
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

    def test_wrong_stream_identity_fails(self):
        result = self.launch(FAKE_CCR_CHILD_MODEL="wrong-model")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertFalse(job.load(str(self.prefix) + ".ccr-result.json")["successful"])

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
