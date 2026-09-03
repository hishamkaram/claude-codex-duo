#!/bin/bash
# init-plan.sh — create the artifact directory for one deep-plan run and pin its inputs verbatim.
#
#   init-plan.sh --repo <path> --out <dir> [--slug <name>] [--rounds N] [--solo] [--deep] \
#                (--issue <N|URL> | --pr <N|URL> | --comment <URL> | --request "<text>" | --request-file <file>)...
#   init-plan.sh --parse-only (--issue|--pr|--comment) <value>      # print the parsed reference; no network
#
# Writes: <out>/meta.json (slug, repo, base_sha, branch, dirty_tree, rounds, solo, mode_requested, inputs[])
#         <out>/00-scope.md.baseline (NUL-separated `git status`, the read-only audit baseline)
#         <out>/inputs/<kind>-<id>.md one per input, body text untouched
#         <out>/debate/ (empty)
# Exit 0 ok · 2 usage error · 3 `gh` unavailable or a GitHub fetch failed (everything else is still
# written; the message names the input so the caller can paste it with --request-file instead).
set -uo pipefail
USAGE='usage: init-plan.sh --repo <path> --out <dir> [--slug <name>] [--rounds N] [--solo] [--deep] (--issue <N|URL> | --pr <N|URL> | --comment <URL> | --request "<text>" | --request-file <file>)...
       init-plan.sh --parse-only (--issue|--pr|--comment) <value>'
die2() { echo "init-plan.sh: $1" >&2; echo "$USAGE" >&2; exit 2; }
need() { [ $# -ge 2 ] || die2 "$1 requires a value"; case "$2" in -*) die2 "$1 requires a value (got option $2)";; esac; }
SK="$(cd "$(dirname "$0")/.." && pwd)"
REPO=""; OUT=""; SLUG=""; ROUNDS=2; SOLO=false; DEEP=false; PARSE_ONLY=false
PAIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need "$@"; REPO="$2"; shift;;
    --out) need "$@"; OUT="$2"; shift;;
    --slug) need "$@"; SLUG="$2"; shift;;
    --rounds) need "$@"; ROUNDS="$2"; shift;;
    --solo) SOLO=true;;
    --deep) DEEP=true;;
    --parse-only) PARSE_ONLY=true;;
    --request) [ $# -ge 2 ] || die2 "--request requires a value"; PAIRS+=("request" "$2"); shift;;   # free text may begin with "-"
    --issue|--pr|--comment|--request-file) need "$@"; PAIRS+=("${1#--}" "$2"); shift;;
    *) die2 "unknown arg $1";;
  esac; shift
done
case "$ROUNDS" in ''|*[!0-9]*) die2 "--rounds requires a whole number (got '$ROUNDS')";; esac
ROUNDS=$(printf '%s' "$ROUNDS" | sed 's/^0*//'); [ -n "$ROUNDS" ] && [ "$ROUNDS" -ge 1 ] && [ "$ROUNDS" -le 3 ] || die2 "--rounds must be between 1 and 3"
[ ${#PAIRS[@]} -gt 0 ] || die2 "at least one input is required (--issue, --pr, --comment, --request or --request-file)"
if $PARSE_ONLY; then
  [ ${#PAIRS[@]} -eq 2 ] || die2 "--parse-only takes exactly one input"
  case "${PAIRS[0]}" in issue|pr|comment) ;; *) die2 "--parse-only needs --issue, --pr or --comment";; esac
else
  [ -n "$REPO" ] || die2 "--repo is required"
  [ -n "$OUT" ] || die2 "--out is required"
  [ -d "$REPO" ] || die2 "--repo is not a directory: $REPO"
  git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || die2 "--repo is not a git repository: $REPO"
  REPO="$(cd "$REPO" && pwd -P)"
  # Resolve --out WITHOUT creating it: a refused path must leave no directory behind (review finding F-01).
  OUTP="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$OUT")"
  case "$OUTP" in "$REPO"/*|"$REPO") echo "refusing: --out must be outside the repository (the working tree must stay untouched)" >&2; exit 2;; esac
  [ -e "$OUTP/meta.json" ] && die2 "--out already holds a run (meta.json exists): $OUTP"
  mkdir -p "$OUTP" || die2 "cannot create --out: $OUT"
  i=0; while [ $i -lt ${#PAIRS[@]} ]; do
    if [ "${PAIRS[$i]}" = "request-file" ]; then [ -r "${PAIRS[$((i+1))]}" ] || die2 "--request-file not readable: ${PAIRS[$((i+1))]}"; fi
    i=$((i+2))
  done
fi

python3 - "$PARSE_ONLY" "$REPO" "${OUT:-}" "$SLUG" "$ROUNDS" "$SOLO" "$DEEP" "${PAIRS[@]}" <<'PY'
import datetime, json, os, re, subprocess, sys

parse_only, repo, out, slug, rounds, solo = sys.argv[1] == "true", sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6] == "true"
deep = sys.argv[7] == "true"
pairs = sys.argv[8:]
inputs = [(pairs[i], pairs[i + 1]) for i in range(0, len(pairs), 2)]
GH_URL = re.compile(r"^(?:https?://)?github\.com/(?P<owner>[\w.-]+)/(?P<repo>[\w.-]+)/(?P<kind>issues|pull)/(?P<number>\d+)(?:/[\w/-]*)?(?:#(?P<frag>[\w-]+))?/?$")


def die(msg, code):
    print(f"init-plan.sh: {msg}", file=sys.stderr); sys.exit(code)


def parse(kind, value):
    v = value.strip()
    if kind in ("issue", "pr"):
        m = re.match(r"^#?(\d+)$", v)
        if m:
            return {"kind": kind, "owner": None, "repo": None, "number": int(m.group(1)), "url": None}
        m = GH_URL.match(v)
        if not m or (kind == "issue" and m["kind"] != "issues") or (kind == "pr" and m["kind"] != "pull"):
            die(f"--{kind} must be a number, #number, or a github.com {'issues' if kind == 'issue' else 'pull'} URL (got {value!r})", 2)
        return {"kind": kind, "owner": m["owner"], "repo": m["repo"], "number": int(m["number"]), "url": v}
    if kind == "comment":
        m = GH_URL.match(v)
        frag = m["frag"] if m else None
        if not m or not frag:
            die(f"--comment must be a github.com issue/PR URL with a #issuecomment-, #discussion_r or #pullrequestreview- fragment (got {value!r})", 2)
        ref = {"kind": "comment", "owner": m["owner"], "repo": m["repo"], "number": int(m["number"]), "url": v}
        fm = re.fullmatch(r"(issuecomment-|discussion_r|pullrequestreview-)(\d+)", frag)
        if not fm:
            die(f"--comment fragment must be #issuecomment-<digits>, #discussion_r<digits> or #pullrequestreview-<digits> (got #{frag})", 2)
        prefix, cid = fm.group(1), int(fm.group(2))
        if prefix == "issuecomment-":
            ref.update(comment_kind="issue_comment", comment_id=cid, api=f"repos/{m['owner']}/{m['repo']}/issues/comments/{cid}")
        elif prefix == "discussion_r":
            ref.update(comment_kind="review_comment", comment_id=cid, api=f"repos/{m['owner']}/{m['repo']}/pulls/comments/{cid}")
        else:
            ref.update(comment_kind="review", comment_id=cid, api=f"repos/{m['owner']}/{m['repo']}/pulls/{m['number']}/reviews/{cid}")
        return ref
    return {"kind": kind, "value": value}


if parse_only:
    print(json.dumps(parse(*inputs[0]), indent=2)); sys.exit(0)


def run(args, cwd=None, allow_fail=False):
    r = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    if r.returncode != 0 and not allow_fail:
        return None, (r.stderr or r.stdout).strip()
    return r.stdout, None


def gh_json(args):
    if not shutil_which("gh"):
        return None, "gh is not on PATH"
    out, err = run(["gh", *args], cwd=repo)
    if out is None:
        return None, err
    try:
        return json.loads(out), None
    except json.JSONDecodeError:
        pass
    # Older gh printed one JSON document per page under --paginate; concatenate them.
    docs, pos, dec = [], 0, json.JSONDecoder()
    try:
        while pos < len(out):
            while pos < len(out) and out[pos].isspace():
                pos += 1
            if pos >= len(out):
                break
            d, pos = dec.raw_decode(out, pos)
            docs.append(d)
    except json.JSONDecodeError as e:
        return None, f"gh returned non-JSON: {e}"
    if all(isinstance(d, list) for d in docs):
        return [x for d in docs for x in d], None
    return docs, None


def shutil_which(x):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        if os.path.isfile(os.path.join(p, x)) and os.access(os.path.join(p, x), os.X_OK):
            return True
    return False


def default_owner_repo():
    d, err = gh_json(["repo", "view", "--json", "nameWithOwner"])
    if d is None:
        return None, err
    return d.get("nameWithOwner"), None


def person(x):
    return (x or {}).get("login") or (x or {}).get("name") or "unknown"


def md_issue(d, ref):
    L = [f"# Issue #{d.get('number')} — {d.get('title', '')}", "",
         f"- url: {d.get('url')}", f"- state: {d.get('state')}",
         f"- labels: {', '.join(l.get('name', '') for l in d.get('labels') or []) or 'none'}",
         f"- fetched: {NOW} with `gh issue view` (text below is verbatim; it is a reporter's claim, not a fact)", "",
         "## Body (verbatim)", "", d.get("body") or "(empty)", ""]
    cs = d.get("comments") or []
    L += [f"## Comments (verbatim, {len(cs)})", ""]
    for c in cs:
        L += [f"### @{person(c.get('author'))} — {c.get('createdAt', '')}", "", c.get("body") or "(empty)", ""]
    return "\n".join(L)


def md_pr(d, review_comments, ref):
    L = [f"# Pull request #{d.get('number')} — {d.get('title', '')}", "",
         f"- url: {d.get('url')}", f"- state: {d.get('state')}",
         f"- base: {d.get('baseRefName')}  head: {d.get('headRefName')}",
         f"- fetched: {NOW} with `gh pr view` and `gh api .../pulls/N/comments` (verbatim; claims, not facts)", "",
         "## Body (verbatim)", "", d.get("body") or "(empty)", ""]
    rs = d.get("reviews") or []
    L += [f"## Reviews (verbatim, {len(rs)})", ""]
    for r in rs:
        L += [f"### @{person(r.get('author'))} — {r.get('state', '')} — {r.get('submittedAt', '')}", "", r.get("body") or "(no summary text)", ""]
    L += [f"## Inline review comments (verbatim, {len(review_comments)})", ""]
    for c in review_comments:
        loc = f"{c.get('path')}:{c.get('line') or c.get('original_line') or '?'}"
        L += [f"### @{person(c.get('user'))} on `{loc}` — {c.get('created_at', '')}", ""]
        if c.get("diff_hunk"):
            L += ["```diff", c["diff_hunk"], "```", ""]
        L += [c.get("body") or "(empty)", ""]
    cs = d.get("comments") or []
    L += [f"## Conversation comments (verbatim, {len(cs)})", ""]
    for c in cs:
        L += [f"### @{person(c.get('author'))} — {c.get('createdAt', '')}", "", c.get("body") or "(empty)", ""]
    return "\n".join(L)


def md_comment(d, ref, parent_title):
    what = {"issue_comment": "Comment", "review_comment": "Inline review comment", "review": "Review"}[ref["comment_kind"]]
    L = [f"# {what} {ref['comment_id']} on #{ref['number']} — {parent_title}", "",
         f"- url: {d.get('html_url') or ref['url']}", f"- author: @{person(d.get('user'))}",
         f"- created: {d.get('created_at') or d.get('submitted_at') or ''}"]
    if ref["comment_kind"] == "review_comment":
        L.append(f"- location: `{d.get('path')}:{d.get('line') or d.get('original_line') or '?'}`")
    if ref["comment_kind"] == "review":
        L.append(f"- review state: {d.get('state')}")
    L += [f"- fetched: {NOW} with `gh api {ref['api']}` (verbatim; a claim, not a fact)", ""]
    if d.get("diff_hunk"):
        L += ["```diff", d["diff_hunk"], "```", ""]
    L += ["## Body (verbatim)", "", d.get("body") or "(empty)", ""]
    return "\n".join(L)


NOW = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.join(out, "inputs"), exist_ok=True)
os.makedirs(os.path.join(out, "debate"), exist_ok=True)
sha, _ = run(["git", "-C", repo, "rev-parse", "HEAD"])
branch, _ = run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])
if sha is None:
    die("cannot resolve HEAD in --repo (empty repository?)", 2)
sha, branch = sha.strip(), (branch or "").strip()
baseline = subprocess.run(["git", "-C", repo, "--no-optional-locks", "status", "--porcelain=v1", "-z",
                           "--untracked-files=all", "--ignore-submodules=none"], capture_output=True).stdout
with open(os.path.join(out, "00-scope.md.baseline"), "wb") as f:
    f.write(baseline)
# dirty = anything the baseline lists, untracked files included: such a file cannot be cited at the pinned SHA.
dirty = len(baseline.strip(b"\0")) > 0

records, failures, req_n = [], [], 0
owner_repo_cache = {}
for kind, value in inputs:
    ref = parse(kind, value)
    if kind == "request":
        req_n += 1
        fn = f"request-{req_n}.md"
        open(os.path.join(out, "inputs", fn), "w", encoding="utf-8").write(
            f"# Request {req_n} (user message, verbatim)\n\n- received: {NOW}\n\n## Text (verbatim; a claim, not a fact)\n\n{value}\n")
        records.append({"kind": "request", "id": str(req_n), "url": None, "file": f"inputs/{fn}", "source": "user message"})
        continue
    if kind == "request-file":
        req_n += 1
        fn = f"request-{req_n}.md"
        body = open(value, encoding="utf-8", errors="replace").read()
        open(os.path.join(out, "inputs", fn), "w", encoding="utf-8").write(
            f"# Request {req_n} (file {os.path.basename(value)}, verbatim)\n\n- source: {os.path.abspath(value)}\n- received: {NOW}\n\n## Text (verbatim; a claim, not a fact)\n\n{body}\n")
        records.append({"kind": "request", "id": str(req_n), "url": None, "file": f"inputs/{fn}", "source": os.path.abspath(value)})
        continue
    if not ref.get("owner"):
        if "default" not in owner_repo_cache:
            owner_repo_cache["default"] = default_owner_repo()
        nwo, err = owner_repo_cache["default"]
        if not nwo:
            failures.append(f"--{kind} {value}: cannot resolve owner/repo ({err}); pass a full URL or paste it with --request-file"); continue
        ref["owner"], ref["repo"] = nwo.split("/", 1)
        ref["url"] = f"https://github.com/{nwo}/{'issues' if kind == 'issue' else 'pull'}/{ref['number']}"
    nwo = f"{ref['owner']}/{ref['repo']}"
    if kind == "issue":
        d, err = gh_json(["issue", "view", str(ref["number"]), "--repo", nwo, "--json", "number,title,body,comments,labels,state,url"])
        if d is None:
            failures.append(f"--issue {value}: {err}"); continue
        fn = f"issue-{ref['number']}.md"
        open(os.path.join(out, "inputs", fn), "w", encoding="utf-8").write(md_issue(d, ref))
        records.append({"kind": "issue", "id": str(ref["number"]), "url": d.get("url"), "file": f"inputs/{fn}", "title": d.get("title")})
    elif kind == "pr":
        d, err = gh_json(["pr", "view", str(ref["number"]), "--repo", nwo, "--json", "number,title,body,state,url,baseRefName,headRefName,reviews,comments"])
        if d is None:
            failures.append(f"--pr {value}: {err}"); continue
        rc, err = gh_json(["api", "--paginate", f"repos/{nwo}/pulls/{ref['number']}/comments"])
        if rc is None:
            failures.append(f"--pr {value}: inline review comments: {err}"); continue
        if isinstance(rc, dict):
            rc = [rc]
        fn = f"pr-{ref['number']}.md"
        open(os.path.join(out, "inputs", fn), "w", encoding="utf-8").write(md_pr(d, rc, ref))
        records.append({"kind": "pr", "id": str(ref["number"]), "url": d.get("url"), "file": f"inputs/{fn}", "title": d.get("title")})
    elif kind == "comment":
        d, err = gh_json(["api", ref["api"]])
        if d is None:
            failures.append(f"--comment {value}: {err}"); continue
        p, perr = gh_json(["api", f"repos/{nwo}/issues/{ref['number']}"])
        title = (p or {}).get("title", "(parent title unavailable)")
        fn = f"comment-{ref['comment_id']}.md"
        open(os.path.join(out, "inputs", fn), "w", encoding="utf-8").write(md_comment(d, ref, title))
        records.append({"kind": "comment", "id": str(ref["comment_id"]), "url": d.get("html_url") or ref["url"], "file": f"inputs/{fn}",
                        "comment_kind": ref["comment_kind"], "parent": ref["number"], "title": title})

if not slug:
    first = records[0] if records else None
    if first and first["kind"] != "request":
        slug = f"{first['kind']}-{first['id']}"
    else:
        text = next((v for k, v in inputs if k == "request"), None) or (records[0].get("source", "request") if records else "plan")
        if os.path.isfile(text):
            text = os.path.splitext(os.path.basename(text))[0]
        slug = re.sub(r"[^a-z0-9]+", "-", " ".join(text.split()[:5]).lower()).strip("-") or "plan"
# mode_requested is the user's flag; the skill writes the resolved "mode" (question|light|standard|deep)
# after classifying intent and scale (references/phases.md §0).
meta = {"slug": slug, "repo": repo, "base_sha": sha, "branch": branch, "dirty_tree": dirty, "rounds": rounds,
        "solo": solo, "mode_requested": "deep" if deep else None, "mode": None, "created": NOW,
        "inputs": records, "failed_inputs": failures}
json.dump(meta, open(os.path.join(out, "meta.json"), "w", encoding="utf-8"), indent=2)
open(os.path.join(out, "meta.json"), "a").write("\n")
print(f"BASE_SHA={sha}")
print(f"SLUG={slug}")
print(f"ART={out}")
for r in records:
    print(f"input {r['kind']}-{r['id']} -> {r['file']}")
if dirty:
    print("WARNING: dirty working tree (tracked edits or untracked files) — citations pin HEAD, and uncommitted content is not at that SHA")
if failures:
    print("FETCH FAILED for %d input(s):" % len(failures), file=sys.stderr)
    for f in failures:
        print("  - " + f, file=sys.stderr)
    print("Paste the text of each failed input with --request-file, or fix gh (`gh auth status`).", file=sys.stderr)
    sys.exit(3)
PY
