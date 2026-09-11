#!/usr/bin/env python3
"""Durable runner receipts and validation. CCR alone owns the workload."""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shutil
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


def load(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def session_id(value):
    if not isinstance(value, str):
        return False
    return str(uuid.UUID(value)) == value


def receipt(value):
    if not isinstance(value, dict):
        raise ValueError("invalid CCR document")
    job = value.get("job_id", "")
    if not job.startswith("ccr-") or not session_id(job[4:]):
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


def state(value):
    receipt(value)
    if value.get("status") == "running":
        return "running"
    return "ended" if stopped(value) else "undetermined"


def attempt(prefix):
    value = load(prefix + ".ccr-attempt.json")
    if value.get("schema") != 1 or value.get("uid") != os.geteuid():
        raise ValueError("unsupported attempt or different user")
    return value


def environment(value):
    env = os.environ.copy()
    for key, val in value["environment"].items():
        if val is None:
            env.pop(key, None)
        else:
            env[key] = val
    return env


def bound_attempt(prefix):
    value = attempt(prefix)
    admitted = receipt(load(prefix + ".ccr-receipt.json"))
    if value.get("receipt") and value["receipt"] != admitted:
        raise ValueError("admission receipt changed")
    value["receipt"] = admitted
    return value


def recover(prefix):
    value = bound_attempt(prefix)
    admitted = value["receipt"]
    atomic(prefix + ".ccr-attempt.json", encode(value))
    # Publish immediately, not only when a watcher times out. A dead watcher
    # must remain attachable even if it never wrote its first progress line.
    if not Path(prefix + ".detached").exists() and not Path(prefix + ".exit").exists():
        fields = dict(backend="ccr", alias=value["alias"],
                      claude_model_id=value["model"], job=admitted["job_id"],
                      session=admitted["session_id"], mode="--fresh",
                      max_turns=value["max_turns"], prompt_sha256=value["prompt_sha256"],
                      prompt_file=value["prompt_file"], joblog="", detached_at="",
                      provider=value["model_document"].get("provider", ""),
                      provider_model=value["model_document"].get("provider_model", ""),
                      compatibility=value["model_document"].get("compatibility", ""),
                      ccr_version=value["ccr_version"], command=shlex.join(value["argv"]),
                      attach_command=shlex.join([value["runner"], prefix, "--attach"]),
                      cancel_command=shlex.join(["python3", str(Path(value["runner"]).with_name("ccr-job.py")),
                                                "cancel-attempt", prefix, admitted["job_id"]]))
        atomic(prefix + ".detached", "".join(f"{k}={v}\n" for k, v in fields.items()).encode())
    return value


def prepare(prefix, alias, model, turns, runner, metadata, version, timeout, argv):
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
    prompt = Path(source).read_bytes()
    prompt_path = str(Path(prefix + ".ccr-prompt").resolve())
    atomic(prompt_path, prompt)
    argv[index] = prompt_path
    argv[0] = os.path.abspath(executable)
    env = {k: os.environ.get(k) for k in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
    # Resolve relative XDG paths once, in the submitting caller's context.
    for key in env:
        if env[key]:
            env[key] = str(Path(env[key]).resolve())
    value = dict(schema=1, uid=os.geteuid(), environment=env,
                 cwd=os.getcwd(), executable=argv[0], argv=argv,
                 alias=alias, model=model, max_turns=turns, runner=str(Path(runner).resolve()),
                 model_document=json.loads(metadata), ccr_version=version,
                 prompt_file=source, prompt_sha256=hashlib.sha256(prompt).hexdigest())
    atomic(prefix + ".ccr-attempt.json", encode(value))
    # Receipt bytes go straight to a private file, even if this collector dies.
    fd = os.open(prefix + ".ccr-receipt.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    expired = False
    with os.fdopen(fd, "wb") as output, open(prefix + ".stderr", "ab") as errors:
        try:
            # subprocess owns this direct submitting child. Its timeout kills
            # and reaps that child only, never the detached owner or a group.
            subprocess.run(argv, env=environment(value), cwd=value["cwd"],
                           stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                           timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            expired = True
        output.flush()
        os.fsync(output.fileno())
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
    record = receipt(json.loads(result.stdout))
    if record["job_id"] != job or record["session_id"] != expected["session_id"]:
        raise ValueError("CCR status identity differs from durable admission")
    return record


def cancel_attempt(prefix, expected=None):
    value = bound_attempt(prefix)
    job = value["receipt"]["job_id"]
    if expected is not None and expected != job:
        raise ValueError("cancel command belongs to a different attempt")
    record = query(prefix, job)
    if stopped(record):
        return record
    query(prefix, job, cancel=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        record = query(prefix, job)
        if stopped(record):
            return record
        time.sleep(0.1)
    raise ValueError("cancellation not positively confirmed; retain the attempt")


def validate_stream(path, expected):
    init, results = [], []
    with open(path, "rb") as stream:
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
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(64 << 10), b""):
            digest.update(chunk)
            length += len(chunk)
    return length, digest.hexdigest()


def snapshot_log(source, destination):
    fd, temp = tempfile.mkstemp(prefix=".ccr-log-", dir=Path(destination).parent)
    digest = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as output, open(source, "rb") as stream:
            length = remaining = os.fstat(stream.fileno()).st_size
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
    if not stopped(record):
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
    length, digest = snapshot_log(record["log"], prefix + ".joblog")
    error_length, error_digest = snapshot_log(record["error_log"], prefix + ".ccr-errorlog")
    # Keep submission errors separate. Rebuilding from these two immutable
    # snapshots avoids duplicating workload diagnostics after collector loss.
    if not Path(prefix + ".ccr-submit.stderr").exists():
        snapshot_log(prefix + ".stderr", prefix + ".ccr-submit.stderr")
    join_diagnostics(prefix)
    successful = record["status"] == "completed" and record["exit_code"] == 0 and not record.get("reason_code")
    error = ""
    error_code = ""
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
                with open(prefix + suffix, "rb") as source:
                    shutil.copyfileobj(source, output, length=64 << 10)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, prefix + ".stderr")
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    operation, *args = sys.argv[1:]
    if operation == "lock":
        fd, seconds = int(args[0]), float(args[1])
        if fd != 9 or not 0 < seconds <= 5:
            raise ValueError("invalid collector lock request")
        deadline = time.monotonic() + seconds
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("collector lock remains held") from None
                time.sleep(min(0.05, deadline - time.monotonic()))
    # A workload/query subprocess must not retain a collector's inherited lease.
    try:
        os.close(9)
    except OSError:
        pass
    if operation == "state":
        print(state(json.load(sys.stdin)))
        return
    prefix = str(Path(args.pop(0)).resolve())
    if operation == "admit":
        value = prepare(prefix, *args[:7], args[7:])
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
        value = recover(prefix)
        record = query(prefix, value["receipt"]["job_id"])
        if not stopped(record):
            raise ValueError("CCR has not positively confirmed workload termination")
        value = record
    else:
        raise ValueError("unknown operation")
    print(json.dumps(value))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
        print("CCR attempt unresolved: " + str(exc), file=sys.stderr)
        sys.exit(6)
