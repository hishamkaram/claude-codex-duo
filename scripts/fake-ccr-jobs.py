#!/usr/bin/env python3
"""Stateful job-protocol fixture. Never supervises or signals processes."""
import json
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
    if "--detach" not in args or "--prompt-file" not in args or any(a.startswith("--resume") for a in args):
        sys.exit("fixture requires fresh durable prompt-file launch")
    alias = args[args.index("--model") + 1]
    prompt = Path(args[args.index("--prompt-file") + 1]).read_bytes()
    for variable, content in (("FAKE_CCR_ARGV_OUT", "\n".join(args[1:]).encode()), ("FAKE_CCR_STDIN_OUT", prompt)):
        if os.environ.get(variable):
            Path(os.environ[variable]).write_bytes(content)
    jid, sid = "ccr-" + str(uuid.uuid4()), os.environ.get("FAKE_CCR_SESSION", str(uuid.uuid4()))
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
    record = dict(schema_version=1, job_id=jid, session_id=sid, status="running",
                  exit_code=None, log=str(log), error_log=str(err), containment="process-group",
                  cleanup=dict(coverage="unknown", survivors=[], observed=[], reason="running"),
                  fixture_mode=mode, fixture_started=time.time(),
                  fixture_delay=float(os.environ.get("FAKE_CCR_SLEEP", "75")))
    write(root / (jid + ".json"), record)
    hang = os.environ.get("FAKE_CCR_HANG_RECEIPT")
    if hang == "partial":
        print('{"job_id":', end="", flush=True)
    elif mode != "receipt_lost" and hang != "none":
        print(json.dumps(dict(job_id=jid, session_id=sid)), flush=True)
    if hang:
        time.sleep(60)
elif args[0] in ("status", "cancel"):
    path = root / (args[1] + ".json")
    with open(str(path) + ".lock", "a") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX)
        record = json.loads(path.read_text())
        mode = record["fixture_mode"]
        if args[0] == "cancel":
            record.update(status="cancelled", exit_code=137)
        elif record["status"] == "running" and mode not in ("sleep", "grandchild", "receipt_lost"):
            if mode != "slowok" or time.time() - record["fixture_started"] >= record["fixture_delay"]:
                record.update(status="failed" if mode == "fail" else "completed", exit_code=1 if mode == "fail" else 0)
        if record["status"] != "running":
            record["cleanup"] = dict(coverage="partial", survivors=[], observed=["launch_pgid_members"], reason="")
        write(path, record)
        if os.environ.get("FAKE_CCR_BAD_STATUS"):
            record.update(json.loads(os.environ["FAKE_CCR_BAD_STATUS"]))
        print(json.dumps(record))
else:
    sys.exit("unsupported fixture command")
