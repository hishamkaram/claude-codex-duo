#!/usr/bin/env python3
"""lint-claims.py — tag, hedge and decision-support linter for plan artifacts.

usage: lint-claims.py <artifact-dir | file.md>...

Rules (each failure names file:line):
  - a hedge word (probably, likely, should be, I assume, ...) may appear only on a line
    tagged [INFERENCE] or [UNKNOWN];
  - [FACT] needs a `path:lines@sha` citation on the same line;
  - [VERIFIED] needs `cmd:` on the same line;
  - a decision line ("Decision:", "Chosen:", "We will", "Rationale:") must cite an F-/V- id;
  - every F-/V-/I-/U- id that is referenced must be defined as a table row `| F-3 |`.
Skips fenced code blocks, `inputs/` (verbatim reporter text), `debate/` and non-.md files.
Exit 0 = clean, 1 = failures, 2 = usage.
"""
import glob, os, re, sys

HEDGE = re.compile(r"\b(probably|likely|should be|i assume|assuming|presumably|it seems|seems to|"
                   r"typically|might be|i believe|i think|appears to|obviously|clearly)\b", re.I)
TAG = re.compile(r"\[(FACT|VERIFIED|INFERENCE|UNKNOWN)\]")
ID = re.compile(r"\b([FVIU])-(\d+)\b")
CITE = re.compile(r"`?[A-Za-z_][\w./\-]*:\d+(-\d+)?@[0-9a-f]{7,40}`?")
DECISION = re.compile(r"^\s*(\|?\s*)?(\*\*)?(decision|chosen|choice|we will|rationale)(\*\*)?\s*[:|]", re.I)
DEFINES = re.compile(r"^\s*\|\s*([FVIU])-(\d+)\s*\|")
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
        in_fence = False
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence; continue
            if in_fence or line.startswith("STATUS:"):
                continue
            where = f"{base}:{i}"
            tags = set(TAG.findall(line))
            h = HEDGE.search(line)
            if h and not (tags & {"INFERENCE", "UNKNOWN"}):
                fails.append(f"{where}: hedge without [INFERENCE]/[UNKNOWN]: {h.group(0)!r}")
            if "FACT" in tags and not CITE.search(line):
                fails.append(f"{where}: [FACT] without path:lines@sha")
            if "VERIFIED" in tags and "cmd:" not in line:
                fails.append(f"{where}: [VERIFIED] without `cmd:`")
            d = DEFINES.match(line)
            if d:
                defined.add(f"{d.group(1)}-{d.group(2)}")
            for kind, num in ID.findall(line):
                referenced.setdefault(f"{kind}-{num}", where)
            if DECISION.match(line) and not ID.search(line):
                fails.append(f"{where}: decision line cites no evidence id")
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
