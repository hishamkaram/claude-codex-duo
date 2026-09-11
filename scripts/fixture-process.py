#!/usr/bin/env python3
"""Finite test workload with cooperative stop and optional collector lease."""
import argparse
import contextlib
import fcntl
import pathlib
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stop", type=pathlib.Path)
    parser.add_argument("role", nargs="?", default="fixture")
    parser.add_argument("--job-id")
    parser.add_argument("--lease", type=pathlib.Path)
    parser.add_argument("--ready", type=pathlib.Path)
    parser.add_argument("--lifetime", type=float, default=300)
    args = parser.parse_args()
    if not 0 < args.lifetime <= 300:
        parser.error("--lifetime must be greater than zero and at most 300 seconds")
    with contextlib.ExitStack() as stack:
        if args.lease:
            lease = stack.enter_context(args.lease.open("a"))
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.ready:
            args.ready.touch()
        deadline = time.monotonic() + args.lifetime
        while not args.stop.exists() and time.monotonic() < deadline:
            time.sleep(0.025)


if __name__ == "__main__":
    main()
