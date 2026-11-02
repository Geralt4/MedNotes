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


def make_checkout(root, folder, license_name, text, readme=None, extra=None):
    path = os.path.join(root, folder)
    os.makedirs(path)
    subprocess.run(["git", "init", "-q", path], check=True)
    with open(os.path.join(path, license_name), "w", encoding="utf-8") as handle:
        handle.write(text)
    if readme is not None:
        with open(os.path.join(path, "README.md"), "w", encoding="utf-8") as handle:
            handle.write(readme)
    for relative, content in (extra or {}).items():
        os.makedirs(os.path.dirname(os.path.join(path, relative)), exist_ok=True)
        with open(os.path.join(path, relative), "w", encoding="utf-8") as handle:
            handle.write(content)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "x")
    git(path, "tag", "1.0.0")
    return subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()


SQLCIPHER = ("## Community Edition Open Source License\n\nCopyright (c) ZETETIC LLC\n\n"
             "# Begin SQLite README.md\n\nnoise\n")
SODIUM = "ISC License\n\nCopyright (c) Frank Denis\n"
README = "generated at revision `" + gate.AUDIT["libsodium_revision"] + "` of libsodium\n"
VERSION_H = "#define SODIUM_VERSION_STRING \"" + gate.AUDIT["libsodium_version"] + "\"\n"
VERSION_PATH = "Clibsodium.xcframework/macos/Headers/Clibsodium/sodium/version.h"
SQLITE_H = "#define SQLITE_VERSION        \"" + gate.AUDIT["sqlite_version"] + "\"\n"
SQLITE_PATH = ("artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos/SQLCipher.framework/"
               "Headers/sqlite3.h")

# What the libsodium notices are in these tests (the real ones are pinned in the script).
FAKE_BODIES = {
    "libsodium": "/* ISC License, Frank Denis, libsodium */",
    "libsodium-bsd": ("Files: a.c\n/*- Copyright Colin Percival, Alexander Peslyak.\n"
                      " * Redistributions in binary form must reproduce the above copyright */"),
}
FAKE_PINS = {key: gate._sha256(text) for key, text in FAKE_BODIES.items()}


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.checkouts = os.path.join(self.tmp.name, "checkouts")
        os.makedirs(self.checkouts)
        self.sqlcipher_rev = make_checkout(self.checkouts, "SQLCipher.swift", "LICENSE.md", SQLCIPHER)
        self.sodium_rev = make_checkout(self.checkouts, "swift-sodium", "LICENSE", SODIUM, README,
                                        {VERSION_PATH: VERSION_H})
        self.write_sqlite_header(SQLITE_H)
        self.resolved = os.path.join(self.tmp.name, "Package.resolved")
        self.pin(self.sqlcipher_rev, self.sodium_rev)

    def write_sqlite_header(self, text):
        path = os.path.join(self.tmp.name, SQLITE_PATH)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def pin(self, sqlcipher, sodium):
        with open(self.resolved, "w", encoding="utf-8") as handle:
            json.dump({"pins": [
                {"identity": "sqlcipher.swift", "state": {"revision": sqlcipher}},
                {"identity": "swift-sodium", "state": {"revision": sodium}}]}, handle)

    def expected(self, bodies=None, pins=None):
        return gate.derive(self.checkouts, self.resolved, libsodium_bodies=FAKE_BODIES if bodies is None else bodies,
                           pins=FAKE_PINS if pins is None else pins)


class CheckLicensesTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.tmp.cleanup)

    def test_the_text_holds_every_component_s_notice_and_the_pinned_versions(self):
        text = self.f.expected()
        self.assertIn("SQLCipher.swift 1.0.0 (revision " + self.f.sqlcipher_rev + ")", text)
        self.assertIn("swift-sodium 1.0.0 (revision " + self.f.sodium_rev + ")", text)
        self.assertIn("Community Edition Open Source License", text)
        self.assertIn("ISC License", text)
        self.assertIn(gate.LIBSODIUM_TITLE, text, "libsodium has its own section, with its own revision")
        self.assertIn(gate.AUDIT["libsodium_revision"], text)
        self.assertIn(FAKE_BODIES["libsodium"], text)
        self.assertIn(gate.LIBSODIUM_BSD_TITLE, text)
        self.assertIn(FAKE_BODIES["libsodium-bsd"], text)
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

    def mounted_check_points(self):
        info = subprocess.run(["hdiutil", "info"], capture_output=True, text=True).stdout
        return [line for line in info.splitlines() if "mednotes-dmg-check-" in line]

    def test_a_dmg_with_the_license_file_passes_and_is_not_left_mounted(self):
        text = self.f.expected()
        self.assertEqual(gate.check_dmg(self.make_dmg({gate.DMG_FILE_NAME: text}), text), [])
        self.assertEqual(self.mounted_check_points(), [], "the DMG was left mounted")

    def test_a_dmg_that_cannot_be_detached_is_reported(self):
        text = self.f.expected()
        dmg = self.make_dmg({gate.DMG_FILE_NAME: text})
        original = gate._detach
        gate._detach = lambda mount: (original(mount), False)[1]  # detached, but reported as stuck
        self.addCleanup(setattr, gate, "_detach", original)
        problems = gate.check_dmg(dmg, text)
        self.assertTrue(any("still mounted" in p for p in problems), problems)

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
            actual = handle.read()
        try:
            expected = gate.derive(checkouts, libsodium_bodies=gate.libsodium_bodies_from_text(actual))
        except gate.LicenseError as error:
            if "SQLCipher framework is not downloaded" in str(error):
                self.skipTest(str(error))
            raise
        self.assertEqual(actual, expected)


class LibsodiumNoticeTests(unittest.TestCase):
    """libsodium's notices are not in the checkouts: they are pinned and parsed from the file."""

    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.tmp.cleanup)

    def test_the_committed_notices_are_the_audited_ones(self):
        with open(gate.LICENSES_FILE, encoding="utf-8") as handle:
            bodies = gate.libsodium_bodies_from_text(handle.read())
        self.assertEqual(sorted(bodies), ["libsodium", "libsodium-bsd"], "a libsodium notice is missing")
        gate.verify_bodies(bodies)  # raises when one differs from its pinned hash
        self.assertIn("Frank Denis", bodies["libsodium"])
        self.assertIn("2013-2026", bodies["libsodium"], "libsodium's own LICENSE, not swift-sodium's")
        for holder in ("Colin Percival", "Alexander Peslyak"):
            self.assertIn(holder, bodies["libsodium-bsd"])

    def test_the_bsd_notices_cover_every_file_that_needs_one(self):
        with open(gate.LICENSES_FILE, encoding="utf-8") as handle:
            body = gate.libsodium_bodies_from_text(handle.read())["libsodium-bsd"]
        for name in gate.BSD_NOTICE_FILES:
            self.assertIn(name, body, f"the notice of {name} does not ship")

    def test_a_missing_libsodium_notice_is_refused(self):
        for key in FAKE_BODIES:
            bodies = {k: v for k, v in FAKE_BODIES.items() if k != key}
            with self.assertRaises(gate.LicenseError) as raised:
                self.f.expected(bodies=bodies)
            self.assertIn("missing", str(raised.exception))

    def test_an_altered_libsodium_notice_is_refused(self):
        for key in FAKE_BODIES:
            bodies = dict(FAKE_BODIES, **{key: FAKE_BODIES[key] + " (edited)"})
            with self.assertRaises(gate.LicenseError) as raised:
                self.f.expected(bodies=bodies)
            self.assertIn("differs from the audited text", str(raised.exception))

    def test_the_text_round_trips_through_its_sections(self):
        text = self.f.expected()
        self.assertEqual(gate.libsodium_bodies_from_text(text), FAKE_BODIES)

    def test_a_release_text_without_the_bsd_section_fails_the_check(self):
        text = self.f.expected()
        cut = text.split("\n" + gate.DELIM + "\n" + gate.LIBSODIUM_BSD_TITLE)[0] + "\n"
        problems = gate.check_text(cut, text)
        self.assertTrue(any("differs" in p for p in problems), problems)

    def test_a_folder_without_libsodium_s_own_licence_fails(self):
        text = self.f.expected()
        without = text.replace(FAKE_BODIES["libsodium"], "")
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, gate.DMG_FILE_NAME), "w", encoding="utf-8") as handle:
                handle.write(without)
            problems = gate.check_folder(folder, text)
        self.assertTrue(any("not the licence text" in p for p in problems), problems)

    def test_another_libsodium_version_than_the_audited_one_is_refused(self):
        version_h = os.path.join(self.f.checkouts, "swift-sodium", VERSION_PATH)
        with open(version_h, "w", encoding="utf-8") as handle:
            handle.write(VERSION_H.replace(gate.AUDIT["libsodium_version"], "1.0.99"))
        with self.assertRaises(gate.LicenseError) as raised:
            self.f.expected()
        self.assertIn("audited version", str(raised.exception))

    def test_another_libsodium_revision_than_the_audited_one_is_refused(self):
        readme = os.path.join(self.f.checkouts, "swift-sodium", "README.md")
        with open(readme, "w", encoding="utf-8") as handle:
            handle.write("generated at revision `" + "1" * 40 + "` of libsodium\n")
        with self.assertRaises(gate.LicenseError) as raised:
            self.f.expected()
        self.assertIn("audit what it bundles first", str(raised.exception))

    def test_another_sqlite_version_than_the_audited_one_is_refused(self):
        self.f.write_sqlite_header(SQLITE_H.replace(gate.AUDIT["sqlite_version"], "3.99.0"))
        with self.assertRaises(gate.LicenseError) as raised:
            self.f.expected()
        self.assertIn("SQLite", str(raised.exception))

    def test_a_missing_sqlcipher_download_is_refused_not_skipped(self):
        os.remove(os.path.join(self.f.tmp.name, SQLITE_PATH))
        with self.assertRaises(gate.LicenseError) as raised:
            self.f.expected()
        self.assertIn("SQLite version", str(raised.exception))


class VendoredCodeTests(unittest.TestCase):
    """The component list is closed: nothing third-party is tracked in the repository."""

    def make_repo(self, files):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        subprocess.run(["git", "init", "-q", tmp.name], check=True)
        for name, text in files.items():
            path = os.path.join(tmp.name, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        git(tmp.name, "add", "-A")
        return tmp.name

    def test_a_repository_of_swift_and_scripts_has_nothing_vendored(self):
        repo = self.make_repo({"App/Main.swift": "", "scripts/a.py": "", "Resources/Licenses.txt": ""})
        self.assertEqual(gate.vendored_files(repo), [])

    def test_a_c_source_or_library_is_found(self):
        repo = self.make_repo({"Vendor/crypto.c": "", "Vendor/crypto.h": "", "libs/libfoo.a": "", "A.swift": ""})
        self.assertEqual(gate.vendored_files(repo), ["Vendor/crypto.c", "Vendor/crypto.h", "libs/libfoo.a"])

    def test_a_framework_folder_is_found_whatever_is_inside(self):
        repo = self.make_repo({"Frameworks/Foo.xcframework/Info.plist": "", "Frameworks/Bar.framework/Bar": ""})
        self.assertEqual(len(gate.vendored_files(repo)), 2)

    def test_an_accounted_for_file_is_not_reported(self):
        repo = self.make_repo({"Vendor/crypto.c": ""})
        self.assertEqual(gate.vendored_files(repo, allowed=["Vendor/crypto.c"]), [])

    def test_the_real_repository_has_nothing_vendored(self):
        self.assertEqual(gate.vendored_files(), [])


class LibsodiumSourceTests(unittest.TestCase):
    """The notices read word for word from a libsodium source tree, and the audit of that tree."""

    HEADER = ("/*-\n * Copyright 2005 Colin Percival\n * Redistribution and use in source and binary forms,\n"
              " * 2. Redistributions in binary form must reproduce the above copyright\n */\n")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "libsodium")
        self.write("LICENSE", "/*\n * ISC License\n * Copyright (c) Frank Denis\n */\n")
        for name in gate.BSD_NOTICE_FILES:
            self.write(os.path.join("src", "libsodium", name), self.HEADER + "int x;\n")
        self.write("src/libsodium/crypto_stream/chacha20/ref/chacha20_ref.c", "/*\n D. J. Bernstein\n Public domain.\n */\n")
        self.write("src/libsodium/crypto_pwhash/argon2/argon2.c",
                   "/*\n * Argon2 source code package\n * licensed under a Creative Commons CC0 1.0 License/Waiver.\n"
                   " * Copyright 2015 the authors\n */\n")
        self.write("src/libsodium/crypto_core/plain.c", "int y;\n")

    def write(self, relative, text):
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def commit(self):
        if not os.path.isdir(os.path.join(self.root, ".git")):
            subprocess.run(["git", "init", "-q", self.root], check=True)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "x", "--allow-empty")
        return subprocess.run(["git", "-C", self.root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    def test_a_clean_tree_has_nothing_unshipped(self):
        self.assertEqual(gate.audit_libsodium_source(self.root), [])

    def test_a_new_file_with_a_licence_with_conditions_is_found(self):
        self.write("src/libsodium/crypto_new/new.c",
                   "/* Permission is hereby granted, free of charge, to any person obtaining a copy */\n")
        problems = gate.audit_libsodium_source(self.root)
        self.assertTrue(any("crypto_new/new.c" in p for p in problems), problems)

    def test_a_new_file_with_a_copyright_and_no_dedication_is_found(self):
        self.write("src/libsodium/crypto_new/new.c", "/* Copyright 2030 Someone */\n")
        problems = gate.audit_libsodium_source(self.root)
        self.assertTrue(any("crypto_new/new.c" in p for p in problems), problems)

    def test_a_listed_file_that_lost_its_notice_is_found(self):
        self.write("src/libsodium/" + gate.BSD_NOTICE_FILES[0], "int x;\n")
        problems = gate.audit_libsodium_source(self.root)
        self.assertTrue(any("carries no BSD-style notice" in p for p in problems), problems)

    def test_a_listed_file_that_is_gone_is_found(self):
        os.remove(os.path.join(self.root, "src", "libsodium", gate.BSD_NOTICE_FILES[0]))
        problems = gate.audit_libsodium_source(self.root)
        self.assertTrue(any("is not in the libsodium source" in p for p in problems), problems)

    def test_the_notices_are_read_word_for_word_and_identical_ones_share_a_group(self):
        revision = self.commit()
        bodies = gate.libsodium_bodies_from_source(self.root, revision)
        self.assertIn("Frank Denis", bodies["libsodium"])
        self.assertEqual(bodies["libsodium"], "/*\n * ISC License\n * Copyright (c) Frank Denis\n */")
        self.assertEqual(bodies["libsodium-bsd"].count("Files:"), 1, "nine files, one distinct notice")
        self.assertIn(self.HEADER.strip(), bodies["libsodium-bsd"])
        for name in gate.BSD_NOTICE_FILES:
            self.assertIn(name, bodies["libsodium-bsd"])

    def test_a_different_notice_in_one_file_gets_its_own_group(self):
        self.write("src/libsodium/" + gate.BSD_NOTICE_FILES[0],
                   self.HEADER.replace("2005 Colin Percival", "2009 Alexander Peslyak") + "int x;\n")
        revision = self.commit()
        bodies = gate.libsodium_bodies_from_source(self.root, revision)
        self.assertEqual(bodies["libsodium-bsd"].count("Files:"), 2)
        self.assertIn("2009 Alexander Peslyak", bodies["libsodium-bsd"])

    def test_a_source_at_another_revision_is_refused(self):
        self.commit()
        with self.assertRaises(gate.LicenseError) as raised:
            gate.libsodium_bodies_from_source(self.root, "0" * 40)
        self.assertIn("audited revision", str(raised.exception))

    def test_a_source_with_an_unshipped_licence_is_refused(self):
        self.write("src/libsodium/crypto_new/new.c", "/* Copyright 2030 Someone */\n")
        revision = self.commit()
        with self.assertRaises(gate.LicenseError) as raised:
            gate.libsodium_bodies_from_source(self.root, revision)
        self.assertIn("does not ship", str(raised.exception))

    def test_the_real_libsodium_source_when_it_is_given(self):
        """Run with LIBSODIUM_SOURCE=<a checkout at the audited revision> to prove the pinned text."""
        source = os.environ.get("LIBSODIUM_SOURCE")
        if not source:
            self.skipTest("set LIBSODIUM_SOURCE to a libsodium checkout at the audited revision")
        bodies = gate.libsodium_bodies_from_source(source)
        gate.verify_bodies(bodies)
        with open(gate.LICENSES_FILE, encoding="utf-8") as handle:
            self.assertEqual(gate.libsodium_bodies_from_text(handle.read()), bodies)


if __name__ == "__main__":
    unittest.main()
