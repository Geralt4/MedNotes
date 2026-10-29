#!/usr/bin/env python3
"""Fails a release when the test log shows a skipped test that may not skip.

Usage: scripts/check_test_skips.py <xcodebuild-test-log>

A skipped test is a test that did not check anything, so the release gate
allows only the skips that cannot be avoided on a release machine:

  * the three CLIDryRunTests, which skip in every sandboxed test host, and
  * the swipe-log test, which skips when the real app has a swipe log.

It also insists that KeychainEntitlementTests ran and passed. That test skips
on an ad-hoc build, and an ad-hoc build cannot use the data-protection Keychain,
so a release that skipped it would ship an app that cannot hold its key. If it
skipped, the machine has no team set: see Config/Local.xcconfig.example.

Both log formats are read. Current Xcode prints
    Test case 'Class.method()' skipped on 'My Mac ...' (0.001 seconds)
and older ones printed
    Test Case '-[MedNotesTests.Class method]' skipped (0.001 seconds).
A skip line in neither form is refused rather than ignored, and so is a log
with no passing test at all (a format this script cannot read).
"""

import re
import sys

ALLOWED_SKIPS = {
    ("CLIDryRunTests", "testCLISafetyRefusesBackupsFolder"),
    ("CLIDryRunTests", "testCLISourceRequiresPath"),
    ("CLIDryRunTests", "testCLIDryRunOnEmptySource"),
    ("ExternalCopiesTests", "testATestSessionsLockLeavesTheAppsSwipeLogAlone"),
}

MUST_PASS = {
    ("KeychainEntitlementTests", "testTheDataProtectionKeychainAcceptsThisBuild"),
}

# Case matters: a passing test whose name contains "Skipped" must not match.
CURRENT = r"^Test case '(\w+)\.(\w+)\(\)' (passed|failed|skipped)\b"
LEGACY = r"^Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' (passed|failed|skipped)\b"
ANY_SKIP = r"^Test [Cc]ase '.*' skipped\b"


def check(lines):
    """Returns the list of reasons to refuse; empty when the log is acceptable."""
    problems = []
    passed = set()
    skipped = set()
    any_passed = False
    for line in lines:
        match = re.match(CURRENT, line) or re.match(LEGACY, line)
        if match:
            test = (match.group(1), match.group(2))
            outcome = match.group(3)
            if outcome == "passed":
                any_passed = True
                passed.add(test)
            elif outcome == "skipped":
                skipped.add(test)
        elif re.match(ANY_SKIP, line):
            problems.append("a skip in a form this script cannot read: " + line.strip())
    for cls, method in sorted(skipped - ALLOWED_SKIPS):
        problems.append(f"unexpected skipped test: {cls}.{method}")
    for cls, method in sorted(MUST_PASS - passed):
        why = "it skipped" if (cls, method) in skipped else "it did not run"
        problems.append(f"{cls}.{method} must pass, and {why}")
    if not any_passed:
        problems.append("no passing test found: the log is not in a form this script can read")
    return problems


def main(path):
    with open(path, encoding="utf-8", errors="replace") as log:
        problems = check(log)
    for problem in problems:
        print("refusing to release: " + problem, file=sys.stderr)
    if problems:
        return 1
    print("test skips ok")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <test-log>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
