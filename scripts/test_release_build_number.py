#!/usr/bin/env python3
"""Tests for scripts/release_build_number.py: `python3 -I scripts/test_release_build_number.py`."""

import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_build_number as gate  # noqa: E402

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, env=ENV)


def commit(repo, name):
    with open(os.path.join(repo, name), "w", encoding="utf-8") as handle:
        handle.write(name)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", name)


class BuildNumberTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = os.path.join(self.tmp.name, "repo")
        os.makedirs(self.repo)
        subprocess.run(["git", "init", "-q", self.repo], check=True)
        with open(os.path.join(self.repo, ".gitignore"), "w", encoding="utf-8") as handle:
            handle.write("build/\n")
        commit(self.repo, "a")
        commit(self.repo, "b")
        commit(self.repo, "c")

    def test_the_build_number_is_the_commit_count(self):
        self.assertEqual(gate.build_number(self.repo), 3)

    def test_it_grows_with_every_commit_whatever_the_version_name(self):
        first = gate.build_number(self.repo)
        git(self.repo, "tag", "v2.0.1-beta")
        commit(self.repo, "d")
        self.assertEqual(gate.build_number(self.repo), first + 1)

    def test_a_shallow_clone_is_refused(self):
        shallow = os.path.join(self.tmp.name, "shallow")
        subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + self.repo, shallow],
                       check=True, capture_output=True)
        with self.assertRaises(gate.BuildNumberError) as raised:
            gate.build_number(shallow)
        self.assertIn("shallow", str(raised.exception))

    def test_a_full_clone_is_accepted(self):
        full = os.path.join(self.tmp.name, "full")
        subprocess.run(["git", "clone", "-q", "file://" + self.repo, full], check=True, capture_output=True)
        self.assertEqual(gate.build_number(full), 3)

    def test_a_modified_tracked_file_is_refused(self):
        with open(os.path.join(self.repo, "a"), "w", encoding="utf-8") as handle:
            handle.write("changed")
        with self.assertRaises(gate.BuildNumberError) as raised:
            gate.build_number(self.repo)
        self.assertIn("uncommitted", str(raised.exception))

    def test_an_untracked_file_is_refused(self):
        with open(os.path.join(self.repo, "new.txt"), "w", encoding="utf-8") as handle:
            handle.write("x")
        with self.assertRaises(gate.BuildNumberError):
            gate.build_number(self.repo)

    def test_an_ignored_file_is_allowed(self):
        os.makedirs(os.path.join(self.repo, "build"))
        with open(os.path.join(self.repo, "build", "out"), "w", encoding="utf-8") as handle:
            handle.write("x")
        self.assertEqual(gate.build_number(self.repo), 3)

    def test_a_folder_that_is_not_a_repository_is_refused(self):
        with self.assertRaises(gate.BuildNumberError):
            gate.build_number(self.tmp.name)

    def test_the_command_prints_the_number_and_refuses_with_status_1(self):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release_build_number.py")
        ok = subprocess.run([sys.executable, "-I", script, self.repo], capture_output=True, text=True)
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, "3"))
        with open(os.path.join(self.repo, "dirty"), "w", encoding="utf-8") as handle:
            handle.write("x")
        refused = subprocess.run([sys.executable, "-I", script, self.repo], capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertEqual(refused.stdout.strip(), "")
        self.assertIn("refusing to release", refused.stderr)


if __name__ == "__main__":
    unittest.main()
