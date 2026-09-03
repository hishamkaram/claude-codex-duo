#!/usr/bin/env python3
"""check-citations.py — every `path:lines@sha` citation must resolve at that SHA, that SHA must
be the run's base commit, AND the verbatim quote that follows must appear inside the cited range.

usage: check-citations.py [--repo <path>] [--base-sha <sha>] [--allow-empty] <file>...

--repo and --base-sha default to the run's meta.json (beside the file or one level up).
Exit 0 = all citations verified, 1 = at least one failure (or zero citations without
--allow-empty), 2 = usage error.
"""
import json, os, re, subprocess, sys, unicodedata

sys.dont_write_bytecode = True   # never write __pycache__ into the plugin (validator check 5, review F-14)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from duo_common import CITE_RE  # noqa: E402

QUOTE = re.compile(r'"([^"\n]{3,300})"')
MAX_WORDS = 15


def norm(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", s)).strip().lower()


_cache, _resolved = {}, {}


def blob(repo, sha, path):
    key = (repo, sha, path)
    if key not in _cache:
        r = subprocess.run(["git", "-C", repo, "show", f"{sha}:{path}"], capture_output=True, text=True, errors="replace")
        _cache[key] = r.stdout.splitlines() if r.returncode == 0 else None
    return _cache[key]


def resolve(repo, sha):
    key = (repo, sha)
    if key not in _resolved:
        r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"], capture_output=True, text=True)
        _resolved[key] = r.stdout.strip() if r.returncode == 0 else None
    return _resolved[key]


def meta_for(path):
    d = os.path.dirname(os.path.abspath(path))
    for cand in (d, os.path.dirname(d)):
        m = os.path.join(cand, "meta.json")
        if os.path.isfile(m):
            try:
                return json.load(open(m, encoding="utf-8"))
            except Exception:
                pass
    return {}


def repo_for(path, explicit):
    if explicit:
        return explicit
    m = meta_for(path)
    if m.get("repo"):
        return m["repo"]
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else os.getcwd()


def base_for(path, explicit, repo_explicit):
    """Explicit --base-sha wins; else meta.json's base_sha; else none (only when --repo was explicit)."""
    if explicit:
        return explicit
    return meta_for(path).get("base_sha")


def candidates(line, start, end=None):
    """Quote candidates after a citation, up to the next citation on the line (`end`). A quoted
    line of code may itself contain double quotes (`note ok "no machine-specific paths"`), so
    when more than one pair follows the citation the intended quote is the whole span; the
    shortest pair would match trivially."""
    out = []
    tail = line[start:end]
    nq = tail.count('"')
    if nq > 2:
        out.append(tail[tail.find('"') + 1:tail.rfind('"')])
    else:
        q = QUOTE.search(tail) or QUOTE.search(line)
        if q:
            out.append(q.group(1))
    seen, uniq = set(), []
    for c in out + [c.replace('\\"', '"') for c in out]:
        c = c.strip()
        if 3 <= len(c) <= 300 and c not in seen:
            seen.add(c); uniq.append(c)
    return uniq


def check_line(repo, base, where, line):
    """Return (checked, failures) for one text line."""
    fails, n = [], 0
    matches = list(CITE_RE.finditer(line))
    for i, m in enumerate(matches):
        n += 1
        nxt = matches[i + 1].start() if i + 1 < len(matches) else None
        a, b = int(m["a"]), int(m["b"] or m["a"])
        full = resolve(repo, m["sha"])
        if full is None:
            fails.append(f"{where}: {m['sha']} is not a commit in {repo}"); continue
        if base:
            base_full = resolve(repo, base) or base
            if full != base_full:
                fails.append(f"{where}: {m['path']}:{a}-{b} cites {m['sha'][:12]}, but the run's base SHA is {base_full[:12]} — cite the base commit"); continue
        lines = blob(repo, m["sha"], m["path"])
        if lines is None:
            fails.append(f"{where}: {m['path']} not found at {m['sha']} (git show failed)"); continue
        if a < 1 or b > len(lines) or a > b:
            fails.append(f"{where}: {m['path']}:{a}-{b} out of range (file has {len(lines)} lines)"); continue
        cands = candidates(line, m.end(), nxt)
        if not cands:
            fails.append(f"{where}: {m['path']}:{a}-{b}@{m['sha'][:7]} has no verbatim \"quote\""); continue
        short = [q for q in cands if len(q.split()) <= MAX_WORDS]
        if not short:
            fails.append(f"{where}: quote longer than {MAX_WORDS} words ({min(len(q.split()) for q in cands)})"); continue
        rng = norm(" ".join(lines[a - 1:b]))
        if not any(norm(q) in rng for q in short):
            fails.append(f"{where}: quote not found in {m['path']}:{a}-{b}@{m['sha'][:7]}: \"{short[0]}\"")
    return n, fails


def main(argv):
    repo, base, allow_empty, paths = None, None, False, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--repo", "--base-sha"):
            if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                print(f"check-citations.py: {a} requires a value", file=sys.stderr); return 2
            if a == "--repo":
                repo = argv[i + 1]
            else:
                base = argv[i + 1]
            i += 2; continue
        if a == "--allow-empty":
            allow_empty = True; i += 1; continue
        if a.startswith("-"):
            print(f"check-citations.py: unknown arg {a}", file=sys.stderr); return 2
        paths.append(a); i += 1
    if not paths:
        print("usage: check-citations.py [--repo <path>] [--base-sha <sha>] [--allow-empty] <file>...", file=sys.stderr); return 2
    fails, checked = [], 0
    for f in paths:
        if not os.path.isfile(f):
            print(f"check-citations.py: not a file: {f}", file=sys.stderr); return 2
        r = repo_for(f, repo)
        b = base_for(f, base, repo)
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            n, ff = check_line(r, b, f"{f}:{i}", line)
            checked += n; fails.extend(ff)
    print(f"checked {checked} citation(s) in {len(paths)} file(s)")
    if fails:
        print("FAIL:\n- " + "\n- ".join(fails), file=sys.stderr); return 1
    if checked == 0 and not allow_empty:
        print("FAIL: zero citations — an evidence file cannot be empty", file=sys.stderr); return 1
    print("OK"); return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
