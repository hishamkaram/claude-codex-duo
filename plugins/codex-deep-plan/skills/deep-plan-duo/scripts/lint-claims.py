#!/usr/bin/env python3
"""lint-claims.py — tag, hedge and decision-support linter for plan artifacts.

usage: lint-claims.py <artifact-dir | file.md>...

Rules (each failure names file:line):
  - an evidence row `| F-n | ...` carries exactly the tag its id implies ([FACT] for F-,
    [VERIFIED] for V-, [INFERENCE] for I-, [UNKNOWN] for U-); an untagged or mis-tagged row fails;
  - a hedge word (probably, likely, should be, I assume, ...) may appear only on a line
    tagged [INFERENCE] or [UNKNOWN];
  - [FACT] needs a `path:lines@sha` citation on the same line;
  - [VERIFIED] needs `cmd:` on the same line;
  - a decision line ("Decision:", "Chosen:", "We will", "Rationale:") must cite an F- or V- id;
    an I-/U- id alone is not support (a table header row is not a decision line);
  - every F-/V-/I-/U- id that is referenced must be defined as a table row `| F-3 |`.
Skips fenced code blocks, `inputs/` (verbatim reporter text), `debate/` and non-.md files.
Exit 0 = clean, 1 = failures, 2 = usage.
"""
import glob, os, re, sys

sys.dont_write_bytecode = True   # never write __pycache__ into the plugin (validator check 5, review F-14)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from duo_common import CITE_RE, HARD_ID_RE  # noqa: E402

HEDGE = re.compile(r"\b(probably|likely|should be|i assume|assuming|presumably|it seems|seems to|"
                   r"typically|might be|i believe|i think|appears to|obviously|clearly)\b", re.I)
TAG = re.compile(r"\[(FACT|VERIFIED|INFERENCE|UNKNOWN)\]")
ID = re.compile(r"\b([FVIU])-(\d+)\b")
DECISION = re.compile(r"^\s*(\|?\s*)?(\*\*)?(decision|chosen|choice|we will|rationale)(\*\*)?\s*[:|]", re.I)
DEFINES = re.compile(r"^\s*\|\s*([FVIU])-(\d+)\s*\|")
SEPARATOR = re.compile(r"^\s*\|?\s*:?-{3,}")
TAG_FOR = {"F": "FACT", "V": "VERIFIED", "I": "INFERENCE", "U": "UNKNOWN"}
SKIP_DIRS = ("inputs", "debate")


def files_for(arg):
    if os.path.isdir(arg):
        return sorted(f for f in glob.glob(os.path.join(arg, "*.md")))
    if os.path.isfile(arg) and arg.endswith(".md"):
        return [arg]
    return None


def lint(files):
    fails, defined, referenced = [], set(), {}
    for f in files:
        base = os.path.basename(f)
        if os.path.basename(os.path.dirname(f)) in SKIP_DIRS:
            continue
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        in_fence = False
        for idx, line in enumerate(lines):
            i = idx + 1
            if line.lstrip().startswith("```"):
                in_fence = not in_fence; continue
            if in_fence or line.startswith("STATUS:"):
                continue
            where = f"{base}:{i}"
            tags = set(TAG.findall(line))
            h = HEDGE.search(line)
            if h and not (tags & {"INFERENCE", "UNKNOWN"}):
                fails.append(f"{where}: hedge without [INFERENCE]/[UNKNOWN]: {h.group(0)!r}")
            if "FACT" in tags and not CITE_RE.search(line):
                fails.append(f"{where}: [FACT] without path:lines@sha")
            if "VERIFIED" in tags and "cmd:" not in line:
                fails.append(f"{where}: [VERIFIED] without `cmd:`")
            d = DEFINES.match(line)
            if d:
                defined.add(f"{d.group(1)}-{d.group(2)}")
                want = TAG_FOR[d.group(1)]
                if tags != {want}:
                    fails.append(f"{where}: row {d.group(1)}-{d.group(2)} must carry exactly [{want}] (found {sorted(tags) or 'no tag'})")
            for kind, num in ID.findall(line):
                referenced.setdefault(f"{kind}-{num}", where)
            is_header = idx + 1 < len(lines) and SEPARATOR.match(lines[idx + 1]) is not None
            if DECISION.match(line) and not is_header and not HARD_ID_RE.search(line):
                fails.append(f"{where}: decision line cites no F-/V- evidence id (inferences and unknowns cannot support a decision)")
    dangling = sorted(set(referenced) - defined, key=lambda s: (s[0], int(s[2:])))
    for d in dangling:
        fails.append(f"{referenced[d]}: {d} referenced but never defined as a table row")
    return fails


def main(argv):
    if not argv or any(a.startswith("-") for a in argv):
        print("usage: lint-claims.py <artifact-dir | file.md>...", file=sys.stderr); return 2
    files = []
    for a in argv:
        got = files_for(a)
        if got is None:
            print(f"lint-claims.py: not a directory or .md file: {a}", file=sys.stderr); return 2
        files.extend(got)
    fails = lint(files)
    print(f"linted {len(files)} file(s)")
    if fails:
        print("FAIL:\n- " + "\n- ".join(fails), file=sys.stderr); return 1
    print("OK"); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
