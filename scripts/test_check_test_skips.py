#!/usr/bin/env python3
"""Tests for check_test_skips.py. Run: python3 -I scripts/test_check_test_skips.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_test_skips as gate  # noqa: E402

KEYCHAIN = "KeychainEntitlementTests.testTheDataProtectionKeychainAcceptsThisBuild"


def line(outcome, name, legacy=False):
    cls, method = name.split(".")
    if legacy:
        return f"Test Case '-[MedNotesTests.{cls} {method}]' {outcome} (0.001 seconds)."
    return f"Test case '{cls}.{method}()' {outcome} on 'My Mac - MedNotes (123)' (0.001 seconds)"


GOOD = [
    line("passed", "SecurityTests.testSomething"),
    line("passed", KEYCHAIN),
    line("skipped", "CLIDryRunTests.testCLISourceRequiresPath"),
    line("skipped", "CLIDryRunTests.testCLISafetyRefusesBackupsFolder"),
    line("skipped", "CLIDryRunTests.testCLIDryRunOnEmptySource"),
    line("skipped", "ExternalCopiesTests.testATestSessionsLockLeavesTheAppsSwipeLogAlone"),
]


class CheckTestSkips(unittest.TestCase):
    def test_the_expected_skips_and_a_passing_keychain_test_are_accepted(self):
        self.assertEqual(gate.check(GOOD), [])

    def test_a_skipped_keychain_test_is_refused(self):
        log = [l for l in GOOD if KEYCHAIN not in l] + [line("skipped", KEYCHAIN)]
        problems = gate.check(log)
        self.assertTrue(any("must pass, and it skipped" in p for p in problems), problems)

    def test_a_keychain_test_that_never_ran_is_refused(self):
        log = [l for l in GOOD if KEYCHAIN not in l]
        problems = gate.check(log)
        self.assertTrue(any("it did not run" in p for p in problems), problems)

    def test_any_other_skip_is_refused(self):
        problems = gate.check(GOOD + [line("skipped", "SecurityTests.testNewlySkipped")])
        self.assertEqual(problems, ["unexpected skipped test: SecurityTests.testNewlySkipped"])

    def test_a_passing_test_with_Skipped_in_its_name_is_not_a_skip(self):
        log = GOOD + [line("passed", "SearchTests.testFrontMatterIsSkippedUnlessItIsTheOnlyMatch")]
        self.assertEqual(gate.check(log), [])

    def test_the_older_log_format_is_read_too(self):
        legacy = [
            line("passed", "SecurityTests.testSomething", legacy=True),
            line("passed", KEYCHAIN, legacy=True),
            line("skipped", "CLIDryRunTests.testCLISourceRequiresPath", legacy=True),
        ]
        self.assertEqual(gate.check(legacy), [])
        problems = gate.check(legacy + [line("skipped", "X.testY", legacy=True)])
        self.assertEqual(problems, ["unexpected skipped test: X.testY"])

    def test_a_skip_line_in_an_unknown_form_is_refused(self):
        problems = gate.check(GOOD + ["Test case 'Weird Name With Spaces' skipped on 'My Mac'"])
        self.assertTrue(any("cannot read" in p for p in problems), problems)

    def test_a_log_with_no_passing_test_is_refused(self):
        problems = gate.check(["Build succeeded", "some other output"])
        self.assertTrue(any("no passing test" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
