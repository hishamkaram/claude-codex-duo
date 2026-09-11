#!/usr/bin/env python3
"""Durable runner receipts and validation. CCR alone owns the workload."""
from contextlib import contextmanager
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


class ResultError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def atomic(path, data):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def encode(value):
    return (json.dumps(value, sort_keys=True) + "\n").encode()


def open_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("artifact must be a regular file")
        stream = os.fdopen(fd, "rb")
        fd = None
        return stream
    finally:
        if fd is not None:
            os.close(fd)


def load(path):
    with open_regular(path) as stream:
        return json.load(stream)


def session_id(value):
    if not isinstance(value, str):
        return False
    return str(uuid.UUID(value)) == value


def receipt(value):
    if not isinstance(value, dict):
        raise ValueError("invalid CCR document")
    job = value.get("job_id", "")
    if not isinstance(job, str) or not job.startswith("ccr-") or not session_id(job[4:]):
        raise ValueError("invalid CCR job ID")
    if not session_id(value.get("session_id")):
        raise ValueError("invalid CCR session ID")
    return value


def stopped(value):
    cleanup = value.get("cleanup") or {}
    return (value.get("status") in ("completed", "failed", "cancelled")
            and type(value.get("exit_code")) is int
            and cleanup.get("coverage") in ("complete", "partial")
            and cleanup.get("survivors") == [])


def releasable(value):
    if value.get("schema_version") == 2:
        disposition = value.get("workload_disposition")
        if disposition == "not_started":
            return (value.get("admission_state") == "aborted"
                    and value.get("status") in ("failed", "cancelled")
                    and value.get("exit_code") is None)
        return disposition == "stopped" and stopped(value)
    return stopped(value)


def state(value):
    receipt(value)
    if value.get("status") == "running":
        return "running"
    return "ended" if releasable(value) else "undetermined"


def attempt(prefix):
    if Path(prefix + ".ccr-admission-conflict.json").exists():
        raise ValueError("conflicting admission evidence retained; admission remains unresolved")
    value = load(prefix + ".ccr-attempt.json")
    if value.get("schema") not in (1, 2) or value.get("uid") != os.geteuid():
        raise ValueError("unsupported attempt or different user")
    validate_observations(prefix, value)
    return value


def environment(value):
    env = os.environ.copy()
    for key, val in value["environment"].items():
        if val is None:
            env.pop(key, None)
        else:
            env[key] = val
    return env


def admission_identity(value, admitted):
    receipt(admitted)
    if value.get("schema") == 2:
        if admitted.get("submission_id") != value["submission_id"]:
            raise ValueError("submission identity differs from durable attempt")
        requested = value.get("requested_resume_session", "")
        if requested and admitted["session_id"] != requested:
            raise ResultError("session_identity_mismatch", "admission session differs from requested resume")
    return admitted


def observation_paths(prefix, kind="observation"):
    path = Path(prefix)
    # Avoid glob interpretation of caller-selected artifact directory names.
    stem = path.name + ".ccr-" + kind + "."
    return sorted(item for item in path.parent.iterdir() if item.name.startswith(stem))


def capture_response(prefix, source, argv, value, timeout, errors):
    # Publish a locked, named capture BEFORE starting the submitter. Its stdout
    # inherits this open-file description and lease, so helper loss cannot erase
    # received bytes or make an unfinished writer look like stable evidence.
    fd, staging = tempfile.mkstemp(prefix=".ccr-capture-", dir=Path(prefix).parent)
    expired, code = False, None
    try:
        with os.fdopen(fd, "w+b") as output:
            fcntl.flock(output.fileno(), fcntl.LOCK_EX)
            os.fsync(output.fileno())
            os.replace(staging, prefix + ".ccr-capture." + source + "." + uuid.uuid4().hex)
            directory = os.open(Path(prefix).parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            try:
                result = subprocess.run(argv, cwd=value["cwd"], env=environment(value),
                                        stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                        timeout=timeout, check=False)
                code = result.returncode
            except subprocess.TimeoutExpired:
                expired = True
            output.flush()
            os.fsync(output.fileno())
            output.seek(0)
            raw = output.read()
        return raw, expired, code
    finally:
        if os.path.exists(staging):
            os.unlink(staging)


def retain_observation(prefix, source, raw):
    # Immutable protocol evidence, not admission authority. CCR's registry owns
    # admission. Content addressing prevents a retry overwriting a disagreement.
    digest = hashlib.sha256(raw).hexdigest()
    path = prefix + ".ccr-observation." + source + "." + digest
    try:
        with open_regular(path) as stream:
            if stream.read() != raw:
                raise ValueError("retained admission observation changed")
    except FileNotFoundError:
        atomic(path, raw)


def validate_observations(prefix, value, mark_conflict=False):
    keys = ("submission_id", "job_id", "session_id") if value.get("schema") == 2 else ("job_id", "session_id")
    observations = [("embedded", value.get("receipt"))]
    paths = [Path(prefix + suffix) for suffix in
             (".ccr-receipt.json", ".ccr-receipt.observed", ".ccr-recovery-receipt.json")]
    hashed = observation_paths(prefix)
    captures = observation_paths(prefix, "capture")
    paths.extend(hashed + captures)
    for path in paths:
        try:
            with open_regular(path) as stream:
                if path in captures:
                    try:
                        fcntl.flock(stream.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
                    except BlockingIOError:
                        raise ValueError("admission response is still being captured") from None
                raw = stream.read()
        except FileNotFoundError:
            continue
        if path in hashed and hashlib.sha256(raw).hexdigest() != path.name.rsplit(".", 1)[-1]:
            raise ValueError("retained admission observation changed")
        try:
            observations.append((path.name, json.loads(raw)))
        except (ValueError, UnicodeError):
            # Incomplete receipt delivery can be repaired from read-only lookup.
            continue
    expected = None
    for source, observed in observations:
        if not isinstance(observed, dict) or not all(key in observed for key in keys):
            continue
        identity = {key: observed[key] for key in keys}
        try:
            admission_identity(value, identity)
            if expected is not None and identity != expected:
                raise ValueError("conflicting admission identities")
        except ValueError as exc:
            # This marker is diagnostic only. Every restart rechecks the raw
            # evidence even if the helper died before this marker was written.
            saved = next((item for name, item in observations if name == Path(prefix).name + ".ccr-receipt.json"), None)
            if mark_conflict:
                atomic(prefix + ".ccr-admission-conflict.json",
                       encode(dict(saved_receipt=saved, embedded_receipt=value.get("receipt"),
                                   observed_identity=identity, observation_source=source)))
            raise ValueError("conflicting admission evidence retained; admission remains unresolved") from exc
        expected = identity


def lookup_submission(prefix, value):
    raw, expired, code = capture_response(prefix, "submission_lookup",
        [value["executable"], "status", "--submission-id=" + value["submission_id"], "--json"],
        value, 20, subprocess.DEVNULL)
    retain_observation(prefix, "submission_lookup", raw)
    validate_observations(prefix, value, mark_conflict=True)
    if expired or code:
        raise ValueError("submission lookup unavailable; admission remains unresolved")
    return admission_identity(value, json.loads(raw))


def bound_attempt(prefix):
    value = attempt(prefix)
    admitted = admission_identity(value, load(prefix + ".ccr-receipt.json"))
    if value.get("receipt") and value["receipt"] != admitted:
        raise ValueError("admission receipt changed")
    value["receipt"] = admitted
    return value



def reconcile_receipt(prefix, value, record, source="submission_lookup"):
    keys = ("submission_id", "job_id", "session_id")
    admitted = {key: record[key] for key in keys}
    try:
        with open_regular(prefix + ".ccr-receipt.json") as stream:
            original = stream.read()
    except FileNotFoundError:
        original = b""
    try:
        saved = json.loads(original)
    except (ValueError, UnicodeError):
        saved = None
    observations = [value.get("receipt"), saved]
    for observation in observations:
        # A complete identity, even one containing malformed field values, must
        # never be silently replaced by a different authority observation.
        if isinstance(observation, dict) and all(key in observation for key in keys):
            identity = {key: observation[key] for key in keys}
            if identity != admitted:
                atomic(prefix + ".ccr-admission-conflict.json",
                       encode(dict(saved_receipt=saved, embedded_receipt=value.get("receipt"),
                                   observed_identity=admitted, observation_source=source)))
                raise ValueError("conflicting admission identities; original receipt retained")
    admission_identity(value, admitted)
    # Preserve even partial receipt bytes before repairing delivery from lookup.
    if original and not Path(prefix + ".ccr-receipt.observed").exists():
        atomic(prefix + ".ccr-receipt.observed", original)
    atomic(prefix + ".ccr-receipt.json", encode(admitted))
    return admitted


def recover(prefix):
    value = attempt(prefix)
    if value.get("schema") == 2 and not value.get("receipt"):
        # Status is read-only. A lost receipt never authorizes a fresh admission.
        record = lookup_submission(prefix, value)
        reconcile_receipt(prefix, value, record)
    value = bound_attempt(prefix)
    admitted = value["receipt"]
    atomic(prefix + ".ccr-attempt.json", encode(value))
    # Publish immediately, not only when a watcher times out. A dead watcher
    # must remain attachable even if it never wrote its first progress line.
    if not Path(prefix + ".detached").exists() and not Path(prefix + ".exit").exists():
        fields = dict(backend="ccr", alias=value["alias"],
                      claude_model_id=value["model"], job=admitted["job_id"],
                      session=admitted["session_id"], mode=("--resume-session" if value.get("requested_resume_session") else "--fresh"),
                      max_turns=value["max_turns"], prompt_sha256=value["prompt_sha256"],
                      prompt_file=value["prompt_file"], joblog="", detached_at="",
                      provider=value["model_document"].get("provider", ""),
                      provider_model=value["model_document"].get("provider_model", ""),
                      compatibility=value["model_document"].get("compatibility", ""),
                      ccr_version=value["ccr_version"], command=shlex.join(value["argv"]),
                      attach_command=shlex.join([value["runner"], prefix, "--attach", "--expected-job", admitted["job_id"],
                                               "--stall-min", str(value.get("stall_min", 6)),
                                               "--max-min", str(value.get("max_min", 25)),
                                               "--poll-sec", str(value.get("poll_sec", 15))]),
                      cancel_command=shlex.join(["python3", str(Path(value["runner"]).with_name("ccr-job.py")),
                                                "cancel-attempt", prefix, admitted["job_id"]]))
        atomic(prefix + ".detached", "".join(f"{k}={v}\n" for k, v in fields.items()).encode())
    return value


def close_collector_lease():
    try:
        os.close(9)
    except OSError:
        pass


def acquire_lock(fd, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise ValueError("collector lock remains held") from None
            time.sleep(max(0, min(0.05, deadline - time.monotonic())))


@contextmanager
def mutation_lease(prefix):
    """Hold the same prefix lease through the last write, even after parent loss."""
    path = prefix + ".claim.lock"
    fd = None
    try:
        inherited, expected = os.fstat(9), os.stat(path)
        if (inherited.st_dev, inherited.st_ino) == (expected.st_dev, expected.st_ino):
            fd = 9
    except OSError:
        pass
    if fd is None:
        close_collector_lease()
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        acquire_lock(fd, 5)
        yield
    finally:
        # Do not LOCK_UN: an inherited descriptor shares the parent's lease.
        # subprocess close_fds prevents the workload inheriting this descriptor.
        os.close(fd)


def prepare(prefix, alias, model, turns, runner, metadata, version, timeout, stall, maximum, poll, argv):
    limits = [int(item) for item in (stall, maximum, poll)]
    if any(item <= 0 for item in limits):
        raise ValueError("watch limits must be positive integers")
    timeout = float(timeout)
    if not 0 < timeout <= 30:
        raise ValueError("admission observation timeout must be between zero and 30 seconds")
    if Path(prefix + ".ccr-attempt.json").exists():
        raise ValueError("attempt already admitted or unresolved; attach, never resubmit")
    executable = shutil.which(argv[0])
    if not executable:
        raise ValueError("CCR executable unavailable")
    argv = list(argv)
    index = argv.index("--prompt-file") + 1
    source = str(Path(argv[index]).resolve())
    with open_regular(source) as stream:
        prompt = stream.read()
    prompt_path = str(Path(prefix + ".ccr-prompt").resolve())
    atomic(prompt_path, prompt)
    argv[index] = prompt_path
    argv[0] = os.path.abspath(executable)
    env = {k: os.environ.get(k) for k in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
    # Resolve relative XDG paths once, in the submitting caller's context.
    for key in env:
        if env[key]:
            env[key] = str(Path(env[key]).resolve())
    submission = uuid.uuid4().hex
    owner = Path(prefix + ".claim/owner")
    if owner.exists():
        tokens = [line[6:] for line in owner.read_text().splitlines() if line.startswith("token=")]
        if len(tokens) != 1 or not 1 <= len(tokens[0]) <= 128 or any(ord(c) < 33 or ord(c) > 126 for c in tokens[0]):
            raise ValueError("invalid durable claim token")
        submission = tokens[0]
    if any(arg.startswith("--submission-id") for arg in argv):
        raise ValueError("submission identity is owned by the runner")
    argv.append("--submission-id=" + submission)
    requested = next((arg.split("=", 1)[1] for arg in argv if arg.startswith("--resume=")), "")
    parent = next((arg.split("=", 1)[1] for arg in argv if arg.startswith("--expected-parent-job=")), "")
    if bool(requested) != bool(parent):
        raise ValueError("resume requires an explicit expected parent job")
    value = dict(schema=2, submission_id=submission, requested_resume_session=requested,
                 expected_parent_job=parent, fresh_decision=not bool(requested),
                 uid=os.geteuid(), environment=env,
                 cwd=os.getcwd(), executable=argv[0], argv=argv,
                 alias=alias, model=model, max_turns=turns, runner=str(Path(runner).resolve()),
                 model_document=json.loads(metadata), ccr_version=version,
                 stall_min=limits[0], max_min=limits[1], poll_sec=limits[2],
                 prompt_file=source, prompt_sha256=hashlib.sha256(prompt).hexdigest())
    atomic(prefix + ".ccr-attempt.json", encode(value))
    with open(prefix + ".stderr", "ab") as errors:
        raw, expired, _ = capture_response(prefix, "admission_receipt", argv, value, timeout, errors)
    retain_observation(prefix, "admission_receipt", raw)
    validate_observations(prefix, value, mark_conflict=True)
    atomic(prefix + ".ccr-receipt.json", raw)
    admitted = recover(prefix)["receipt"]
    if expired:
        raise ValueError("admission observation timed out; receipt retained; attach to the original attempt")
    return admitted


def query(prefix, job, cancel=False):
    value = bound_attempt(prefix)
    expected = value["receipt"]
    if job != expected["job_id"]:
        raise ValueError("requested job differs from durable admission")
    argv = [value["executable"], "cancel" if cancel else "status", job]
    if not cancel:
        argv.append("--json")
    result = subprocess.run(argv, cwd=value["cwd"], env=environment(value),
                            capture_output=True, timeout=20, check=False)
    if result.returncode:
        raise ValueError("CCR owner query failed; attempt remains unresolved")
    if cancel:
        return {}
    record = admission_identity(value, json.loads(result.stdout))
    if value.get("schema") == 2 and record.get("schema_version") != 2:
        raise ValueError("transactional status schema missing")
    if record["job_id"] != job or record["session_id"] != expected["session_id"]:
        raise ValueError("CCR status identity differs from durable admission")
    if value.get("schema") == 2 and value.get("requested_resume_session"):
        if (record.get("requested_resume_session") != value["requested_resume_session"]
                or record.get("resumed_from") != value["expected_parent_job"]):
            raise ValueError("session lineage differs from durable admission")
    return record


def cancel_attempt(prefix, expected=None):
    value = bound_attempt(prefix)
    job = value["receipt"]["job_id"]
    if expected is not None and expected != job:
        raise ValueError("cancel command belongs to a different attempt")
    record = query(prefix, job)
    if releasable(record):
        return record
    query(prefix, job, cancel=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        record = query(prefix, job)
        if releasable(record):
            return record
        time.sleep(0.1)
    raise ValueError("cancellation not positively confirmed; retain the attempt")


def validate_stream(path, expected):
    init, results = [], []
    with open_regular(path) as stream:
        while True:
            line = stream.readline((16 << 20) + 1)
            if not line:
                break
            if len(line) > 16 << 20:
                raise ValueError("stream event exceeds 16 MiB observation limit")
            if not line.strip():
                continue
            event = json.loads(line)
            if not isinstance(event, dict):
                raise ValueError("invalid stream event")
            if event.get("type") == "system" and event.get("subtype") == "init":
                init.append(event)
            if event.get("type") == "result":
                results.append(event)
            if len(init) > 1 or len(results) > 1:
                raise ValueError("duplicate initialization or result")
    for event in init + results:
        if event.get("session_id") != expected["receipt"]["session_id"]:
            raise ResultError("session_identity_mismatch", "session identity differs: requested="
                              + expected["receipt"]["session_id"] + " observed=" + str(event.get("session_id")))
    if len(init) != 1 or len(results) != 1:
        raise ValueError("expected one initialization and one result")
    if init[0].get("model") != expected["model"]:
        raise ResultError("route_identity_mismatch", "stream model differs from admitted model")
    result = results[0]
    if result.get("subtype") != "success" or result.get("is_error") is not False:
        raise ValueError("model returned an unsuccessful result")


def file_digest(path):
    digest, length = hashlib.sha256(), 0
    with open_regular(path) as stream:
        for chunk in iter(lambda: stream.read(64 << 10), b""):
            digest.update(chunk)
            length += len(chunk)
    return length, digest.hexdigest()


def snapshot_log(source, destination, boundary=None):
    fd, temp = tempfile.mkstemp(prefix=".ccr-log-", dir=Path(destination).parent)
    digest = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as output, open_regular(source) as stream:
            size = os.fstat(stream.fileno()).st_size
            if boundary is not None and (type(boundary) is not int or boundary < 0 or boundary > size):
                raise ValueError("invalid or truncated committed log boundary")
            length = remaining = size if boundary is None else boundary
            while remaining:
                chunk = stream.read(min(remaining, 64 << 10))
                if not chunk:
                    raise ValueError("job log truncated while collecting")
                output.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, destination)
        # The following atomic evidence publication synchronizes this directory.
        return length, digest.hexdigest()
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def freeze(prefix, job):
    value = recover(prefix)
    record = query(prefix, job)
    if not releasable(record):
        raise ValueError("workload is not positively stopped")
    evidence_path = prefix + ".ccr-result.json"
    if Path(evidence_path).exists():
        evidence = load(evidence_path)
        if evidence["job_id"] != job or evidence["session_id"] != value["receipt"]["session_id"]:
            raise ValueError("committed result belongs to another admission")
        if evidence["status"] != record or type(evidence["successful"]) is not bool:
            raise ValueError("terminal job evidence changed")
        length, digest = file_digest(prefix + ".joblog")
        if digest != evidence["sha256"] or length != evidence["bytes"]:
            raise ValueError("committed result bytes changed")
        length, digest = file_digest(prefix + ".ccr-errorlog")
        if digest != evidence["error_sha256"] or length != evidence["error_bytes"]:
            raise ValueError("committed diagnostic bytes changed")
        return evidence
    # Bound the read to the observed length. An escaped descendant can append
    # diagnostics under partial coverage, but cannot extend this result.
    committed = record.get("result_evidence")
    if value.get("schema") == 2 and record.get("status") == "completed":
        if (not isinstance(committed, dict) or committed.get("successful") is not True
                or committed.get("session_id") != record["session_id"]
                or committed.get("model") != value["model"]):
            raise ValueError("missing or contradictory committed result")
    if record.get("workload_disposition") == "not_started":
        atomic(prefix + ".joblog", b"")
        length, digest = file_digest(prefix + ".joblog")
    else:
        length, digest = snapshot_log(record["log"], prefix + ".joblog", committed["boundary"] if committed else None)
    if committed and digest != committed.get("sha256"):
        raise ValueError("committed output digest differs")
    if record.get("workload_disposition") == "not_started" and not Path(record.get("error_log", "")).is_file():
        atomic(prefix + ".ccr-errorlog", b"")
        error_length, error_digest = file_digest(prefix + ".ccr-errorlog")
    else:
        error_length, error_digest = snapshot_log(record["error_log"], prefix + ".ccr-errorlog")
    # Keep submission errors separate. Rebuilding from these two immutable
    # snapshots avoids duplicating workload diagnostics after collector loss.
    if not Path(prefix + ".ccr-submit.stderr").exists():
        snapshot_log(prefix + ".stderr", prefix + ".ccr-submit.stderr")
    join_diagnostics(prefix)
    successful = record["status"] == "completed" and record["exit_code"] == 0 and not record.get("reason_code")
    error = ""
    error_code = record.get("reason_code", "")
    if successful:
        try:
            validate_stream(prefix + ".joblog", value)
        except (ValueError, KeyError, TypeError) as exc:
            successful, error = False, str(exc)
            error_code = getattr(exc, "code", "invalid_result")
    evidence = dict(job_id=job, session_id=record["session_id"], bytes=length,
                    sha256=digest, successful=successful,
                    error_bytes=error_length, error_sha256=error_digest,
                    error=error, error_code=error_code, status=record)
    atomic(evidence_path, encode(evidence))
    return evidence


def join_diagnostics(prefix):
    fd, temp = tempfile.mkstemp(prefix=".stderr.", dir=Path(prefix).parent)
    try:
        with os.fdopen(fd, "wb") as output:
            for suffix in (".ccr-submit.stderr", ".ccr-errorlog"):
                with open_regular(prefix + suffix) as source:
                    shutil.copyfileobj(source, output, length=64 << 10)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, prefix + ".stderr")
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def complete_admission(prefix):
    value = attempt(prefix)
    if value.get("schema") != 2:
        raise ValueError("only transactional attempts can recover prepared admission")
    for option, expected in (("--submission-id", value["submission_id"]),
                             ("--resume", value.get("requested_resume_session", "")),
                             ("--expected-parent-job", value.get("expected_parent_job", ""))):
        actual = [arg for arg in value["argv"] if arg == option or arg.startswith(option + "=")]
        if actual != ([option + "=" + expected] if expected else []):
            raise ValueError("saved invocation identity changed")
    if value["argv"][0] != value["executable"]:
        raise ValueError("saved executable identity changed")
    record = lookup_submission(prefix, value)
    reconcile_receipt(prefix, value, record)
    if record.get("admission_state") != "prepared":
        return recover(prefix)
    with open_regular(prefix + ".ccr-prompt") as stream:
        prompt = stream.read()
    if hashlib.sha256(prompt).hexdigest() != value["prompt_sha256"]:
        raise ValueError("saved prompt changed; cannot recover admission")
    # Explicit recovery submits the complete matching request under its original
    # token. CCR owns the lease, fingerprint and execution-intent decision.
    with open(prefix + ".stderr", "ab") as errors:
        response, _, _ = capture_response(prefix, "resubmission_receipt", value["argv"], value, 30, errors)
    retain_observation(prefix, "resubmission_receipt", response)
    atomic(prefix + ".ccr-recovery-receipt.json", response)
    validate_observations(prefix, value, mark_conflict=True)
    try:
        returned = json.loads(response)
    except (ValueError, UnicodeError):
        returned = None
    if isinstance(returned, dict) and all(key in returned for key in ("submission_id", "job_id", "session_id")):
        reconcile_receipt(prefix, value, returned, source="resubmission_receipt")
    return recover(prefix)


def resolve_session(prefix, sid):
    if not session_id(sid):
        raise ValueError("invalid session ID")
    executable = shutil.which("ccr")
    if not executable:
        raise ValueError("CCR executable unavailable")
    response = subprocess.run([executable, "status", "--session-id=" + sid, "--json"],
                              capture_output=True, timeout=20, check=False)
    if response.returncode:
        raise ValueError("session head lookup failed")
    record = receipt(json.loads(response.stdout))
    if (record["session_id"] != sid or record.get("schema_version") not in (1, 2)
            or not stopped(record) or not releasable(record)):
        raise ValueError("session head is not a positively stopped predecessor")
    anchor = dict(session_id=sid, expected_parent_job=record["job_id"],
                  predecessor_status=record["status"], resolved_at=time.time())
    atomic(prefix + ".ccr-anchor.json", encode(anchor))
    return anchor


def main():
    operation, *args = sys.argv[1:]
    if operation == "lock":
        fd, seconds = int(args[0]), float(args[1])
        if fd != 9 or not 0 < seconds <= 5:
            raise ValueError("invalid collector lock request")
        acquire_lock(fd, seconds)
        return
    if operation == "state":
        close_collector_lease()
        print(state(json.load(sys.stdin)))
        return
    prefix = str(Path(args.pop(0)).resolve())
    if operation in ("admit", "recover", "freeze", "mirror", "resolve-session", "complete-admission"):
        with mutation_lease(prefix):
            value = dispatch(operation, prefix, args)
    else:
        close_collector_lease()
        value = dispatch(operation, prefix, args)
    print(json.dumps(value))


def dispatch(operation, prefix, args):
    if operation == "complete-admission":
        value = complete_admission(prefix)
    elif operation == "resolve-session":
        value = resolve_session(prefix, args[0])
    elif operation == "admit":
        value = prepare(prefix, *args[:10], args[10:])
    elif operation == "verify-attempt":
        value = bound_attempt(prefix)
        if value["receipt"]["job_id"] != args[0]:
            raise ValueError("saved command belongs to a different attempt")
    elif operation == "recover":
        value = recover(prefix)
    elif operation == "status":
        value = query(prefix, args[0])
    elif operation == "cancel":
        value = query(prefix, args[0], cancel=True)
    elif operation == "cancel-attempt":
        value = cancel_attempt(prefix, args[0] if args else None)
    elif operation == "freeze":
        value = freeze(prefix, args[0])
    elif operation == "mirror":
        if not Path(prefix + ".ccr-result.json").exists():
            record = query(prefix, args[0])
            snapshot_log(record["log"], prefix + ".joblog")
        value = {}
    elif operation == "stopped":
        value = bound_attempt(prefix)
        record = query(prefix, value["receipt"]["job_id"])
        if not releasable(record):
            raise ValueError("CCR has not positively confirmed workload termination")
        value = record
    else:
        raise ValueError("unknown operation")
    return value


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
        print("CCR attempt unresolved: " + str(exc), file=sys.stderr)
        sys.exit(6)
