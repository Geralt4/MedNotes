#!/usr/bin/env python3
"""The build number of a release: the number of commits that lead to it.

  scripts/release_build_number.py [REPO]

Prints `git rev-list --count HEAD` of REPO (default: the repository this
script is in) and exits 0. Every release commit then has a build number that
is unique and larger than any earlier release's, whatever the version name or
suffix. `scripts/release.sh` passes it as CFBundleVersion.

It refuses, with a plain reason and exit status 1, when the count could not be
trusted:

  * a shallow clone: the history is cut off, so the count is too small;
  * a tree with uncommitted changes (untracked files included, ignored files
    not): what is built is not the commit that is counted;
  * a repository it cannot read.
"""

from __future__ import annotations

import os
import subprocess
import sys


class BuildNumberError(Exception):
    pass


def _git(repo: str, *args: str) -> str:
    try:
        result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    except FileNotFoundError:
        raise BuildNumberError("git is not installed")
    if result.returncode != 0:
        raise BuildNumberError(f"git {' '.join(args)} failed: {result.stderr.strip() or 'no output'}")
    return result.stdout.strip()


def build_number(repo: str) -> int:
    if _git(repo, "rev-parse", "--is-shallow-repository") == "true":
        raise BuildNumberError(
            "this is a shallow clone, so the commit count would be too small; "
            "run `git fetch --unshallow` first")
    if _git(repo, "status", "--porcelain"):
        raise BuildNumberError(
            "the working tree has uncommitted changes (or untracked files); "
            "commit or remove them so the build number counts what is built")
    count = _git(repo, "rev-list", "--count", "HEAD")
    if not count.isdigit() or int(count) < 1:
        raise BuildNumberError(f"git gave an unusable commit count: {count!r}")
    return int(count)


def main(argv: list[str]) -> int:
    repo = argv[0] if argv else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        print(build_number(repo))
    except BuildNumberError as error:
        print(f"refusing to release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
