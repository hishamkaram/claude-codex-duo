"""Shared constants for the two-model review validators.

Imported by validate-consultation.py, validate-verifier-packets.py, and
mirrored (as a string) by templates/review-workflow.js. Keeping these in
one module prevents the three copies from drifting — the exact failure
mode the sibling codex-deep-plan plugin's duo_common.py was created to close.
"""
from __future__ import annotations  # `str | None` on the Python 3.9 shipped with macOS

import re

ID_RE = re.compile(r"F-[0-9]{2,}")
ORIGINS = {"BOTH", "CLAUDE-ONLY", "CODEX-ONLY", "CONFLICT"}
SEVERITIES = {"P0", "P1", "P2", "P3"}

# Structured-field format: locations and observations must be `path:line[-line]` or
# `path:line[-line]@sha "quote"` — nothing else (the quote may itself contain
# double quotes; it runs to the end of the string). The path is either a bare token
# (no whitespace) or a double-quoted string (for repository paths that contain
# spaces, e.g. "docs/API guide.md":42). This is the primary structural control
# against artifact paths in structured fields; the provenance regex below is
# defense-in-depth for free-text fields.
LOCATION_RE = re.compile(r"^(?P<path>[\w./@+-]+|\"[^\"\\]+\"):\d+(?:-\d+)?(?:@\w+)?(?:\s+\".*\")?$", re.DOTALL)

# Verifier evidence item (agents/finding-verifier.md): either a citation with a
# verbatim quote — path:line[-line][@sha] "quote" — or a recorded command
# `cmd: <command> -> <output excerpt>`. Anything else cannot back a CONFIRMED
# or REFUTED verdict.
EVIDENCE_RE = re.compile(r"^(?:(?:[\w./@+-]+|\"[^\"\\]+\"):\d+(?:-\d+)?(?:@\w+)?\s+\".*\S.*\"|cmd:\s*\S.*->\s*\S.*)$", re.DOTALL)

# Paths that are never repository-relative citations: the verifier's scratch
# directories live under the run's artifact directory, not the repository.
SCRATCH_DIRS = ("verify-scratch", "lead-scratch")   # rejected at any depth
SCRATCH_PREFIXES = SCRATCH_DIRS + ("repro",)         # `repro` only as the first segment

# The skill's own run artifacts, by base name (NN-<name>.<ext>[.<ext>]). Rejected
# at any path depth — `run/00-brief.md` is still a review artifact. A generic
# NN-name.* is rejected only when it is not preceded by "/" so ordinary
# repository paths such as docs/00-intro.md stay citable.
ARTIFACT_NAMES = "scope|accepted|repo|brief|run|intent|conventions|lead|codex|review-seal|matrix|findings|debate-selection|consultation|verification|verifier-packets|verdicts|resolution|resolution-selection|review"
ARTIFACT_SEGMENT_RE = re.compile(r"^(?:0[0-9]-(?:%s)(?:\.[A-Za-z0-9-]+)+|%s)$" % (ARTIFACT_NAMES, "|".join(SCRATCH_DIRS)))

# Provenance filter (defense-in-depth for free-text fields): rejects model
# attribution, review-process references, and run-directory paths/artifact
# filenames. Applied to claim/trigger/impact/falsifier/proposed_checks/
# open_factual_questions AND (after the structural check) to locations/
# observations.
PROVENANCE_RE = re.compile(
    r"\b(?:claude|codex|lead)[\s-]+(?:reviewer|review|opinion|position|analysis|assessment|finding|verdict|conclusion|found|says|argues|agrees?|disagrees?|concurs?|reviewed|determined|recommended|identified|concluded|agent|model|cli|code|tool|checked|confirmed|verified|noted|flagged|reported|suggested|suggests|thinks|believes|claims?|claimed|proposed|proposes|raised|observed|wrote|writes|pointed|mentioned|stated|states)s?\b|"
    r"\b(?:claude|codex|lead)['’]s\b|"
    r"\b(?:CLAUDE|CODEX)-ONLY\b|\b(?:CL|CX)-[0-9]{2,}\b|"
    r"(?:^|[\s\"'=`()\[\]{}<>,;])repro/|"
    r"\bclaude\s+and\s+codex\b|\bcodex\s+and\s+claude\b|"
    r"\breview(?:s|ed)?\s+(?:from|by)\s+(?:claude|codex|the\s+lead)\b|"
    # Attribution by preposition: "checked by Codex", "according to Codex",
    # "per Claude", "from the lead" — but not a path or tool name such as
    # "by codex-run.sh" (round-28 CX-01).
    r"\b(?:by|from|per|according\s+to|via|with|against|to)\s+(?:claude|codex|the\s+lead)(?![\w./-])|"
    r"\b(?:lead-reviewer|finding-verifier|fact-checker)\b|"
    r"\bgpt-?[0-9o][0-9a-z.-]*\b|\bclaude[\s-]+(?:opus|sonnet|haiku|fable|mythos)\b|"
    r"\b(?:the\s+)?(?:other|first|second|both)\s+(?:reviewer|opinion)s?\b|"
    r"\breviewers?\s+(?:agree|disagree|concurs?)\b|"
    r"\b(?:agreement|consensus)\s+(?:between|from|of|shows|means)\b|"
    r"\b(?:according to|per)\s+(?:the\s+)?(?:transcript|artifact)\b|"
    r"(?:^|[\s\"'=`()\[\]{}<>,;])/(?:tmp|private/tmp|Users|home|var|etc|opt|root|srv|mnt)/|"
    # A run directory name (<target>-YYYYMMDD-HHMMSS/) referenced relatively.
    r"\b[A-Za-z0-9_.-]+-[0-9]{8}-[0-9]{6}/|"
    # Any run artifact: NN-name.<ext>[.<ext>...] (covers every current and future
    # sidecar, rotated .attemptN.*, .sha256/.tree/.baseline, .stderr, the final
    # 07-review.md) and the scratch directories. Known names are rejected at any
    # depth; an unknown NN-name.* only when not preceded by "/" (round-26 CX-02).
    r"(?:^|[^A-Za-z0-9_-])(?:0[0-9]-(?:" + ARTIFACT_NAMES + r")(?:\.[A-Za-z0-9-]+)+|(?:verify|lead)-scratch)(?:$|[^A-Za-z0-9_.-])|"
    r"(?:^|[^A-Za-z0-9_/-])0[0-9]-[a-z][a-z0-9-]*(?:\.[A-Za-z0-9-]+)+(?:$|[^A-Za-z0-9_.-])",
    re.IGNORECASE,
)

# For a citation (`path:lines[@sha] "quote"`) the repository path is checked
# only for artifact/run-directory/scratch shapes — a legitimate file such as
# agents/finding-verifier.md must stay citable (round-37 CX-01) — while the
# quote is checked with the full provenance filter.
PATH_PROVENANCE_RE = re.compile(
    r"(?:^|[\s\"'=`()\[\]{}<>,;])repro/|"
    r"\b[A-Za-z0-9_.-]+-[0-9]{8}-[0-9]{6}/|"
    r"(?:^|[^A-Za-z0-9_-])(?:0[0-9]-(?:" + ARTIFACT_NAMES + r")(?:\.[A-Za-z0-9-]+)+|(?:verify|lead)-scratch)(?:$|[^A-Za-z0-9_.-])|"
    r"(?:^|[^A-Za-z0-9_/-])0[0-9]-[a-z][a-z0-9-]*(?:\.[A-Za-z0-9-]+)+(?:$|[^A-Za-z0-9_.-])",
    re.IGNORECASE,
)

def citation_has_provenance(value: str) -> bool:
    """Provenance check for a citation-shaped string: path arms on the path, full filter on the rest."""
    m = LOCATION_RE.match(value)
    if not m:
        return PROVENANCE_RE.search(value) is not None
    path_end = m.end("path")
    return PATH_PROVENANCE_RE.search(value[:path_end]) is not None or PROVENANCE_RE.search(value[path_end:]) is not None

# A verifier may write the citation in backticks (`path:line@sha` "quote"), as
# Markdown habit suggests; the machine form is the same citation without them.
# Strip exactly one surrounding pair before any evidence check (round-29 CX-01).
BACKTICKED_CITATION_RE = re.compile(r"^`([^`\s][^`]*)`(\s+\".*)$", re.DOTALL)

def normalize_evidence(value: str) -> str:
    value = value.strip()
    m = BACKTICKED_CITATION_RE.match(value)
    return m.group(1) + m.group(2) if m else value

def location_error(value: str) -> str | None:
    """Return why a location/observation string is not a repository-relative
    path:line citation, or None if it is acceptable.

    Structural checks only (no filesystem access): the citation must match
    LOCATION_RE, the path must be relative (no leading /, \\ or drive letter),
    must contain no `.`/`..` segments, and must not point into a scratch
    directory. The provenance filter is applied separately by the caller.
    """
    m = LOCATION_RE.match(value)
    if not m:
        return "must be a path:line or path:line@sha citation"
    path = m.group("path")
    if path.startswith('"'):
        path = path[1:-1]
    if path.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:[\\/]", path):
        return "path must be repository-relative, not absolute"
    segments = path.replace("\\", "/").split("/")
    if any(seg in (".", "..", "") for seg in segments):
        return "path must not contain ., .. or empty segments"
    if segments[0] in SCRATCH_PREFIXES:
        return "path must not point into a scratch directory"
    if any(ARTIFACT_SEGMENT_RE.match(seg) for seg in segments):
        return "path must not name a review artifact or scratch directory at any depth"
    return None
