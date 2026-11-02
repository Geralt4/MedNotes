#!/usr/bin/env python3
"""Tests for scripts/check_licenses.py: `python3 -I scripts/test_check_licenses.py`."""

import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_licenses as gate  # noqa: E402


def git(folder, *args):
    subprocess.run(["git", "-C", folder, *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})


def make_checkout(root, folder, license_name, text, readme=None):
    path = os.path.join(root, folder)
    os.makedirs(path)
    subprocess.run(["git", "init", "-q", path], check=True)
    with open(os.path.join(path, license_name), "w", encoding="utf-8") as handle:
        handle.write(text)
    if readme is not None:
        with open(os.path.join(path, "README.md"), "w", encoding="utf-8") as handle:
            handle.write(readme)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "x")
    git(path, "tag", "1.0.0")
    return subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()


SQLCIPHER = "## Community Edition Open Source License\n\nCopyright (c) Zetetic\n\n# Begin SQLite README.md\n\nnoise\n"
SODIUM = "ISC License\n\nCopyright (c) Frank Denis\n"
README = "generated at revision `" + "8" * 40 + "` of libsodium\n"


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.checkouts = os.path.join(self.tmp.name, "checkouts")
        os.makedirs(self.checkouts)
        self.sqlcipher_rev = make_checkout(self.checkouts, "SQLCipher.swift", "LICENSE.md", SQLCIPHER)
        self.sodium_rev = make_checkout(self.checkouts, "swift-sodium", "LICENSE", SODIUM, README)
        self.resolved = os.path.join(self.tmp.name, "Package.resolved")
        self.pin(self.sqlcipher_rev, self.sodium_rev)

    def pin(self, sqlcipher, sodium):
        with open(self.resolved, "w", encoding="utf-8") as handle:
            json.dump({"pins": [
                {"identity": "sqlcipher.swift", "state": {"revision": sqlcipher}},
                {"identity": "swift-sodium", "state": {"revision": sodium}}]}, handle)

    def expected(self):
        return gate.derive(self.checkouts, self.resolved)


class CheckLicensesTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.tmp.cleanup)

    def test_the_text_holds_both_licences_and_the_pinned_versions(self):
        text = self.f.expected()
        self.assertIn("SQLCipher.swift 1.0.0 (revision " + self.f.sqlcipher_rev + ")", text)
        self.assertIn("swift-sodium 1.0.0 (revision " + self.f.sodium_rev + ")", text)
        self.assertIn("Community Edition Open Source License", text)
        self.assertIn("ISC License", text)
        self.assertIn("revision " + "8" * 40, text, "the libsodium revision comes from the package's README")
        self.assertNotIn("noise", text, "SQLCipher.swift's file continues with SQLite's README, which is not a licence")

    def test_a_matching_text_passes(self):
        text = self.f.expected()
        self.assertEqual(gate.check_text(text, text), [])

    def test_a_changed_licence_text_fails(self):
        text = self.f.expected()
        problems = gate.check_text(text.replace("Frank Denis", "Someone Else"), text)
        self.assertTrue(any("differs" in p for p in problems), problems)

    def test_a_missing_licence_fails(self):
        text = self.f.expected()
        cut = text.split("swift-sodium 1.0.0")[0]
        problems = gate.check_text(cut, text)
        self.assertTrue(any("ISC License" in p for p in problems), problems)
        self.assertTrue(any("libsodium" in p for p in problems), problems)

    def test_a_checkout_at_another_revision_than_the_pin_fails(self):
        self.f.pin(self.f.sqlcipher_rev, "0" * 40)
        with self.assertRaises(gate.LicenseError) as raised:
            self.f.expected()
        self.assertIn("pins", str(raised.exception))

    def test_a_package_that_is_not_pinned_fails(self):
        with open(self.f.resolved, "w", encoding="utf-8") as handle:
            json.dump({"pins": [{"identity": "swift-sodium", "state": {"revision": self.f.sodium_rev}}]}, handle)
        with self.assertRaises(gate.LicenseError):
            self.f.expected()

    def test_a_folder_without_the_file_fails(self):
        with tempfile.TemporaryDirectory() as empty:
            problems = gate.check_folder(empty, self.f.expected())
        self.assertTrue(any("missing" in p for p in problems), problems)

    def test_a_folder_with_another_text_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, gate.DMG_FILE_NAME), "w", encoding="utf-8") as handle:
                handle.write("SQLCipher only\n")
            problems = gate.check_folder(folder, self.f.expected())
        self.assertTrue(any("not the licence text" in p for p in problems), problems)
        self.assertTrue(any("ISC License" in p for p in problems), problems)

    def test_a_folder_with_the_text_passes(self):
        text = self.f.expected()
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, gate.DMG_FILE_NAME), "w", encoding="utf-8") as handle:
                handle.write(text)
            self.assertEqual(gate.check_folder(folder, text), [])

    def test_a_missing_dmg_fails(self):
        self.assertTrue(gate.check_dmg("/nonexistent/MedNotes.dmg", self.f.expected()))

    def make_dmg(self, folder_contents):
        """A real DMG holding `folder_contents` ({name: text})."""
        source = os.path.join(self.f.tmp.name, "dmg-root")
        os.makedirs(source)
        for name, text in folder_contents.items():
            with open(os.path.join(source, name), "w", encoding="utf-8") as handle:
                handle.write(text)
        dmg = os.path.join(self.f.tmp.name, "Test.dmg")
        made = subprocess.run(["hdiutil", "create", "-volname", "T", "-srcfolder", source, "-ov",
                               "-format", "UDZO", dmg], capture_output=True, text=True)
        if made.returncode != 0:
            self.skipTest("hdiutil cannot make a DMG here: " + made.stderr.strip())
        return dmg

    def test_a_dmg_with_the_license_file_passes(self):
        text = self.f.expected()
        self.assertEqual(gate.check_dmg(self.make_dmg({gate.DMG_FILE_NAME: text}), text), [])

    def test_a_dmg_without_the_license_file_is_refused(self):
        text = self.f.expected()
        problems = gate.check_dmg(self.make_dmg({"README": "nothing here"}), text)
        self.assertTrue(any("missing" in p for p in problems), problems)

    def test_a_dmg_with_an_incomplete_license_file_is_refused(self):
        text = self.f.expected()
        problems = gate.check_dmg(self.make_dmg({gate.DMG_FILE_NAME: "SQLCipher only"}), text)
        self.assertTrue(problems)

    def test_the_file_in_the_repository_is_what_the_pinned_checkouts_yield(self):
        """The real file, when the real checkouts exist on this machine."""
        try:
            checkouts = gate.find_checkouts()
        except gate.LicenseError:
            self.skipTest("the pinned packages are not checked out here")
        with open(gate.LICENSES_FILE, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), gate.derive(checkouts))


if __name__ == "__main__":
    unittest.main()
