#!/usr/bin/env python3
"""check-citations.py — every `path:lines@sha` citation must resolve at that SHA AND the
verbatim quote that follows it must appear inside the cited line range.

usage: check-citations.py [--repo <path>] [--allow-empty] <file>...

This is what turns "no assumptions" into a constraint: a citation without a SHA drifts,
a citation without a quote cannot be checked, and a quote that is not in the range is a
fabrication. Exit 0 = all citations verified, 1 = at least one failure (or zero
citations without --allow-empty), 2 = usage error.
"""
import json, os, re, subprocess, sys, unicodedata

CITE = re.compile(r"`?(?P<path>[A-Za-z_][\w./\-]*):(?P<a>\d+)(?:-(?P<b>\d+))?@(?P<sha>[0-9a-f]{7,40})`?")
QUOTE = re.compile(r'"([^"\n]{3,300})"')
MAX_WORDS = 15


def norm(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", s)).strip().lower()


_cache = {}


def blob(repo, sha, path):
    key = (repo, sha, path)
    if key not in _cache:
        r = subprocess.run(["git", "-C", repo, "show", f"{sha}:{path}"], capture_output=True, text=True, errors="replace")
        _cache[key] = r.stdout.splitlines() if r.returncode == 0 else None
    return _cache[key]


def repo_for(path, explicit):
    """--repo wins; else meta.json beside the file or one level up; else the cwd's repo."""
    if explicit:
        return explicit
    d = os.path.dirname(os.path.abspath(path))
    for cand in (d, os.path.dirname(d)):
        m = os.path.join(cand, "meta.json")
        if os.path.isfile(m):
            try:
                return json.load(open(m, encoding="utf-8"))["repo"]
            except Exception:
                pass
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else os.getcwd()


def check_line(repo, where, line):
    """Return (checked, failures) for one text line."""
    fails, n = [], 0
    for m in CITE.finditer(line):
        n += 1
        lines = blob(repo, m["sha"], m["path"])
        a, b = int(m["a"]), int(m["b"] or m["a"])
        if lines is None:
            fails.append(f"{where}: {m['path']} not found at {m['sha']} (git show failed)"); continue
        if a < 1 or b > len(lines) or a > b:
            fails.append(f"{where}: {m['path']}:{a}-{b} out of range (file has {len(lines)} lines)"); continue
        q = QUOTE.search(line, m.end()) or QUOTE.search(line)
        if not q:
            fails.append(f"{where}: {m['path']}:{a}-{b}@{m['sha'][:7]} has no verbatim \"quote\""); continue
        quote = q.group(1)
        if len(quote.split()) > MAX_WORDS:
            fails.append(f"{where}: quote longer than {MAX_WORDS} words ({len(quote.split())})"); continue
        if norm(quote) not in norm(" ".join(lines[a - 1:b])):
            fails.append(f"{where}: quote not found in {m['path']}:{a}-{b}@{m['sha'][:7]}: \"{quote}\"")
    return n, fails


def main(argv):
    repo, allow_empty, paths = None, False, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--repo":
            if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                print("check-citations.py: --repo requires a value", file=sys.stderr); return 2
            repo = argv[i + 1]; i += 2; continue
        if a == "--allow-empty":
            allow_empty = True; i += 1; continue
        if a.startswith("-"):
            print(f"check-citations.py: unknown arg {a}", file=sys.stderr); return 2
        paths.append(a); i += 1
    if not paths:
        print(__doc__.strip().splitlines()[3], file=sys.stderr); return 2
    fails, checked = [], 0
    for f in paths:
        if not os.path.isfile(f):
            print(f"check-citations.py: not a file: {f}", file=sys.stderr); return 2
        r = repo_for(f, repo)
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            n, ff = check_line(r, f"{f}:{i}", line)
            checked += n; fails.extend(ff)
    print(f"checked {checked} citation(s) in {len(paths)} file(s)")
    if fails:
        print("FAIL:\n- " + "\n- ".join(fails), file=sys.stderr); return 1
    if checked == 0 and not allow_empty:
        print("FAIL: zero citations — an evidence file cannot be empty", file=sys.stderr); return 1
    print("OK"); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
