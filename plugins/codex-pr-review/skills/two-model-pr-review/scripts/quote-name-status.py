#!/usr/bin/env python3
"""Format `git diff --name-status -M -z` into the brief's file list.

Git paths are bytes: they may hold non-UTF-8 sequences, newlines, tabs or
quotes. Paths are emitted the way git's own core.quotePath does — plain when
ordinary, otherwise double-quoted with C escapes and \\ooo octal for raw bytes.
That keeps one changed file on exactly one line and stays reversible: a path
containing a real newline is distinguishable from one whose own characters are
a backslash and an n.

Reads NUL-separated records on stdin, writes the sorted list on stdout.
"""
import sys

def quote(raw: bytes) -> str:
    s = raw.decode("utf-8", "surrogateescape")
    if not any(c in '"\\' or ord(c) < 0x20 or ord(c) == 0x7F or 0xDC80 <= ord(c) <= 0xDCFF for c in s):
        return s
    out = []
    for c in s:
        o = ord(c)
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif 0xDC80 <= o <= 0xDCFF:          # raw byte preserved by surrogateescape
            out.append("\\%03o" % (o - 0xDC00))
        elif o < 0x20 or o == 0x7F:
            out.append("\\%03o" % o)
        else:
            out.append(c)
    return '"' + "".join(out) + '"'

def main() -> int:
    fields = sys.stdin.buffer.read().split(b"\0")
    lines, i = [], 0
    while i < len(fields) and fields[i]:
        status = fields[i].decode("ascii", "replace")
        i += 1
        if status[0] in "RC":                 # rename/copy: old path, then new path
            old, new = quote(fields[i]), quote(fields[i + 1])
            i += 2
            lines.append(f"  - {new}  ({status[0]} from {old}, similarity {status[1:]})")
        else:
            lines.append(f"  - {quote(fields[i])}  ({status})")
            i += 1
    print("\n".join(sorted(lines)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
