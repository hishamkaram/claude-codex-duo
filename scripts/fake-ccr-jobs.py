#!/usr/bin/env python3
"""Stateful job-protocol fixture. Never supervises or signals processes."""
import json
import hashlib
import fcntl
import os
from pathlib import Path
import sys
import time
import uuid

args = sys.argv[1:]
root = Path(os.environ.get("FAKE_CCR_STORE", os.environ.get("XDG_DATA_HOME", str(Path.home())))) / "fake-ccr-jobs"
root.mkdir(parents=True, exist_ok=True)


def write(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


if args[0] == "launch":
    if "--detach" not in args or "--prompt-file" not in args:
        sys.exit("fixture requires durable prompt-file launch")
    alias = args[args.index("--model") + 1]
    prompt = Path(args[args.index("--prompt-file") + 1]).read_bytes()
    for variable, content in (("FAKE_CCR_ARGV_OUT", "\n".join(args[1:]).encode()), ("FAKE_CCR_STDIN_OUT", prompt)):
        if os.environ.get(variable):
            Path(os.environ[variable]).write_bytes(content)
    submission = next((a.split("=", 1)[1] for a in args if a.startswith("--submission-id=")), "")
    resumed = next((a.split("=", 1)[1] for a in args if a.startswith("--resume=")), "")
    parent = next((a.split("=", 1)[1] for a in args if a.startswith("--expected-parent-job=")), "")
    bindings = root / "submissions"
    bindings.mkdir(exist_ok=True)
    key = bindings / hashlib.sha256(submission.encode()).hexdigest()
    request = hashlib.sha256(prompt + json.dumps(args).encode()).hexdigest()
    if key.exists():
        bound = json.loads(key.read_text())
        if bound["request"] != request:
            sys.exit("submission conflict")
        print(json.dumps(bound["receipt"]))
        sys.exit(0)
    heads = root / "heads"
    heads.mkdir(exist_ok=True)
    if resumed:
        if (heads / resumed).read_text() != parent:
            sys.exit("stale expected parent")
        previous = json.loads((root / (parent + ".json")).read_text())
        if previous["session_id"] != resumed or previous["status"] == "running":
            sys.exit("parent conflict")
    jid, sid = "ccr-" + str(uuid.uuid4()), resumed or os.environ.get("FAKE_CCR_SESSION", str(uuid.uuid4()))
    mode = os.environ.get("FAKE_CCR_MODE", "ok")
    log = root / (jid + ".log")
    init = dict(type="system", subtype="init", session_id=sid,
                model=os.environ.get("FAKE_CCR_CHILD_MODEL", "anthropic.ccr." + alias), tools=["Read", "Bash"])
    result = dict(type="result", subtype="success", is_error=False, session_id=sid,
                  result=os.environ.get("FAKE_CCR_RESULT", "DONE"))
    if mode == "error_result":
        result.update(subtype="error_max_turns", is_error=True)
    events = [init] + ([] if mode in ("noresult", "fail") else [result])
    log.write_text("".join(json.dumps(e) + "\n" for e in events))
    err = root / (jid + ".err")
    err.write_text("fixture failure" if mode == "fail" else "")
    if mode == "write":
        Path("smoke-write.txt").write_text("hello")
    if mode == "outside":
        import re
        match = re.search(r"echo hello > (.*smoke-outside\.txt)", prompt.decode())
        Path(match[1]).write_text("hello")
    record = dict(schema_version=2, submission_id=submission, requested_resume_session=resumed, resumed_from=parent, resumed_from_status=(previous["status"] if resumed else ""), admission_state="execution_possible", workload_disposition="unknown", job_id=jid, session_id=sid, status="running",
                  exit_code=None, log=str(log), error_log=str(err), containment="process-group",
                  cleanup=dict(coverage="unknown", survivors=[], observed=[], reason="running"),
                  fixture_mode=mode, fixture_started=time.time(),
                  fixture_delay=float(os.environ.get("FAKE_CCR_SLEEP", "75")))
    record["result_evidence"] = dict(boundary=log.stat().st_size, sha256=hashlib.sha256(log.read_bytes()).hexdigest(), session_id=sid, model=init["model"], successful=mode not in ("error_result", "noresult", "fail"))
    write(root / (jid + ".json"), record)
    (heads / sid).write_text(jid)
    write(key, dict(request=request, receipt=dict(submission_id=submission, job_id=jid, session_id=sid)))
    hang = os.environ.get("FAKE_CCR_HANG_RECEIPT")
    if hang == "partial":
        print('{"job_id":', end="", flush=True)
    elif mode != "receipt_lost" and hang != "none" and not os.environ.get("FAKE_CCR_DROP_RECEIPT"):
        print(json.dumps(dict(submission_id=submission, job_id=jid, session_id=sid)), flush=True)
    if hang:
        time.sleep(60)
elif args[0] in ("status", "cancel"):
    if args[1].startswith("--session-id="):
        args[1] = (root / "heads" / args[1].split("=", 1)[1]).read_text()
    if args[1].startswith("--submission-id="):
        submission = args[1].split("=", 1)[1]
        bound = json.loads((root / "submissions" / hashlib.sha256(submission.encode()).hexdigest()).read_text())
        args[1] = bound["receipt"]["job_id"]
        if json.loads((root / (args[1] + ".json")).read_text())["fixture_mode"] == "receipt_lost":
            sys.exit("fixture admission lookup unavailable")
    path = root / (args[1] + ".json")
    with open(str(path) + ".lock", "a") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        record = json.loads(path.read_text())
        mode = record["fixture_mode"]
        if args[0] == "cancel":
            record.update(status="cancelled", exit_code=137)
        elif record["status"] == "running" and mode not in ("sleep", "grandchild", "receipt_lost"):
            if mode != "slowok" or time.time() - record["fixture_started"] >= record["fixture_delay"]:
                failed = mode in ("fail", "error_result", "noresult")
                record.update(status="failed" if failed else "completed", exit_code=1 if failed else 0)
        if record["status"] != "running":
            record.update(admission_state="finished", workload_disposition="stopped")
            record["cleanup"] = dict(coverage="partial", survivors=[], observed=["launch_pgid_members"], reason="")
        write(path, record)
        if os.environ.get("FAKE_CCR_BAD_STATUS"):
            record.update(json.loads(os.environ["FAKE_CCR_BAD_STATUS"]))
        print(json.dumps(record))
else:
    sys.exit("unsupported fixture command")
