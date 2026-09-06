#!/usr/bin/env python3
"""Generate the JavaScript constants of templates/review-workflow.js from review_common.py.

The Workflow tool runs JavaScript, so the workflow script needs the same
citation, artifact and provenance rules the Python validators apply. They are
emitted here from the one Python source instead of being mirrored by hand
(rounds 14, 28, 31 and 35 each found the hand copy drifting).

  gen-workflow-constants.py --write   rewrite the generated block in place
  gen-workflow-constants.py --check   exit 1 if the block differs (validate.sh)
  gen-workflow-constants.py           print the block
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import review_common as rc  # noqa: E402

JS = HERE.parent / "templates" / "review-workflow.js"
BEGIN = "  // BEGIN GENERATED FROM scripts/review_common.py — do not edit; run scripts/gen-workflow-constants.py --write (validate.sh checks it)"
END = "  // END GENERATED"

# Escapes JavaScript accepts in unicode mode: syntax characters, class escapes and
# the control/property escapes. Anything else (\" \' \` ...) is an identity escape
# Python tolerates and JavaScript /u rejects, so the backslash is dropped.
KEEP_ESCAPED = set('^$\\.*+?()[]{}|/-') | set("wWdDsSbBnrtfv0pux")


def py2js(pattern: str, flags: int) -> str:
    out = []
    i = 0
    in_class = False
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern):
            n = pattern[i + 1]
            if n == "w":
                out.append(r"\p{L}\p{N}_" if in_class else r"[\p{L}\p{N}_]")
            elif n in KEEP_ESCAPED:
                out.append("\\" + n)
            else:
                out.append(n)
            i += 2
            continue
        if c == "[" and not in_class:
            in_class = True
        elif c == "]" and in_class:
            in_class = False
        elif c == "/" and not in_class:
            out.append("\\/"); i += 1; continue
        elif c == "/":
            out.append("\\/"); i += 1; continue
        if pattern.startswith("(?P<", i):
            out.append("(?<"); i += 4; continue
        out.append(c)
        i += 1
    js_flags = "u" + ("s" if flags & 16 else "") + ("i" if flags & 2 else "")
    return "/" + "".join(out) + "/" + js_flags


def js_list(values) -> str:
    return "[" + ", ".join("'" + v + "'" for v in values) + "]"


def block() -> str:
    lines = [BEGIN]
    lines.append("  const VALID_SEVERITIES = " + js_list(sorted(rc.SEVERITIES)))
    lines.append("  const SCRATCH_DIRS = " + js_list(rc.SCRATCH_DIRS))
    lines.append("  const SCRATCH_PREFIXES = " + js_list(rc.SCRATCH_PREFIXES))
    lines.append("  const ARTIFACT_NAMES = '" + rc.ARTIFACT_NAMES + "'")
    for name in ("LOCATION_RE", "EVIDENCE_RE", "ARTIFACT_SEGMENT_RE", "PROVENANCE_RE", "PATH_PROVENANCE_RE", "BACKTICKED_CITATION_RE"):
        r = getattr(rc, name)
        lines.append(f"  const {name} = {py2js(r.pattern, r.flags)}")
    lines.append(END)
    return "\n".join(lines) + "\n"


def main() -> int:
    generated = block()
    if "--check" not in sys.argv and "--write" not in sys.argv:
        sys.stdout.write(generated)
        return 0
    text = JS.read_text(encoding="utf-8")
    start, end = text.find(BEGIN), text.find(END)
    if start < 0 or end < 0:
        print(f"{JS}: generated block markers not found", file=sys.stderr)
        return 2
    end += len(END) + 1
    current = text[start:end]
    if "--check" in sys.argv:
        if current == generated:
            print("OK review-workflow.js constants match review_common.py")
            return 0
        print(f"{JS}: generated constants differ from review_common.py; run gen-workflow-constants.py --write", file=sys.stderr)
        return 1
    if "--write" in sys.argv:
        JS.write_text(text[:start] + generated + text[end:], encoding="utf-8")
        print(f"wrote generated block to {JS}")
        return 0
    sys.stdout.write(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
