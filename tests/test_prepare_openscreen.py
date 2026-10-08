"""Real local Git fixtures cover preparation; only gclient's network is faked."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prepare_openscreen.py"
SPEC = importlib.util.spec_from_file_location("prepare_openscreen", SCRIPT)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class PreparationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.git(self.remote, "init", "-q")
        self.git(self.remote, "config", "user.name", "Preparation test")
        self.git(self.remote, "config", "user.email", "test@example.invalid")
        (self.remote / "source.txt").write_text("old upstream\n")
        self.commit("old")
        old = self.git(self.remote, "rev-parse", "HEAD")
        (self.remote / "source.txt").write_text("new upstream\n")
        self.commit("new")
        revision = self.git(self.remote, "rev-parse", "HEAD")
        self.lock = {
            "version": 1,
            "openscreen": {"repository": str(self.remote), "revision": revision,
                           "previous_revision": old},
            "libraries": {},
            "integration": {"expected_upstream_revision": revision, "patches": []},
        }
        self.depot = self.root / "depot_tools"
        self.depot.mkdir()
        self.log = self.root / "gclient_calls.jsonl"
        executable = self.depot / "gclient"
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            f"with Path({str(self.log)!r}).open('a') as log:\n"
            "    log.write(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd()}) + '\\n')\n"
        )
        executable.chmod(0o755)
        self.pristine = self.root / "pristine"

    @staticmethod
    def git(directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args],
                                       text=True).strip()

    def commit(self, message):
        self.git(self.remote, "add", ".")
        self.git(self.remote, "commit", "--no-gpg-sign", "-qm", message)

    def run_prepare(self, destination=None, lock=None, pristine=None):
        return prepare.prepare(destination or self.pristine, lock or self.lock,
                               self.depot, self.root, pristine)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def add_patch(self, filename, old, new):
        path = self.root / filename
        path.write_text("diff --git a/source.txt b/source.txt\n"
                        "--- a/source.txt\n+++ b/source.txt\n"
                        f"@@ -1 +1 @@\n-{old}\n+{new}\n")
        self.lock["integration"]["patches"].append({
            "path": filename, "sha256": prepare.digest(path.read_bytes())})
        return path

    def test_sync_is_pinned_and_second_run_does_no_work(self):
        self.assertTrue(self.run_prepare())
        source = self.pristine / "openscreen"
        self.assertEqual(self.git(source, "rev-parse", "HEAD"),
                         self.lock["openscreen"]["revision"])
        self.git(source, "merge-base", "--is-ancestor",
                 self.lock["openscreen"]["previous_revision"], "HEAD")
        self.assertEqual(self.calls(), [
            {"args": ["sync", "--nohooks", "--no-history", "--revision",
                      "openscreen@" + self.lock["openscreen"]["revision"]],
             "cwd": str(self.pristine.resolve())},
            {"args": ["runhooks"], "cwd": str(self.pristine.resolve())},
        ])
        self.assertFalse(self.run_prepare())
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.git(source, "status", "--porcelain"), "")

    def test_ordered_patches_apply_once_only_to_integration(self):
        self.run_prepare()
        self.add_patch("one.patch", "new upstream", "first seam")
        self.add_patch("two.patch", "first seam", "second seam")
        integration = self.root / "integration"
        self.assertTrue(self.run_prepare(integration, pristine=self.pristine))
        self.assertEqual((integration / "openscreen/source.txt").read_text(),
                         "second seam\n")
        self.assertEqual((self.pristine / "openscreen/source.txt").read_text(),
                         "new upstream\n")
        self.assertFalse(self.run_prepare(integration, pristine=self.pristine))
        self.assertEqual((integration / "openscreen/applescreen").resolve(),
                         self.root.resolve())
        self.assertEqual(len(self.calls()), 4)
        (integration / "openscreen/source.txt").write_text("unauthorized change\n")
        with self.assertRaisesRegex(prepare.PreparationError, "Unstaged"):
            self.run_prepare(integration, pristine=self.pristine)
        self.assertEqual(len(self.calls()), 4)

    def test_refuses_dirty_source_without_touching_it(self):
        for change in ("staged", "unstaged", "untracked"):
            with self.subTest(change=change):
                workspace = self.root / change
                self.run_prepare(workspace)
                source = workspace / "openscreen"
                filename = "new.txt" if change == "untracked" else "source.txt"
                (source / filename).write_text("owner work\n")
                if change == "staged":
                    self.git(source, "add", filename)
                before = self.git(source, "status", "--porcelain")
                calls_before = len(self.calls())
                with self.assertRaises(prepare.PreparationError):
                    self.run_prepare(workspace)
                self.assertEqual(self.git(source, "status", "--porcelain"), before)
                self.assertEqual((source / filename).read_text(), "owner work\n")
                self.assertEqual(len(self.calls()), calls_before)

    def test_refuses_changed_pin_head_origin_and_shared_gclient(self):
        self.run_prepare()
        changed = copy.deepcopy(self.lock)
        changed["openscreen"]["revision"] = "0" * 40
        with self.assertRaisesRegex(prepare.PreparationError, "input changed"):
            self.run_prepare(lock=changed)
        source = self.pristine / "openscreen"
        self.git(source, "checkout", "--detach", self.lock["openscreen"]["previous_revision"])
        with self.assertRaisesRegex(prepare.PreparationError, "Unexpected HEAD"):
            self.run_prepare()
        self.git(source, "checkout", "--detach", self.lock["openscreen"]["revision"])
        self.git(source, "remote", "set-url", "origin", "other-repository")
        with self.assertRaisesRegex(prepare.PreparationError, "Unexpected origin"):
            self.run_prepare()
        shared = self.root / "shared"
        shared.mkdir()
        config = shared / ".gclient"
        config.write_text("solutions = [{'name': 'other-project'}]\n")
        with self.assertRaisesRegex(prepare.PreparationError, "unrelated"):
            self.run_prepare(shared)
        self.assertEqual(config.read_text(), "solutions = [{'name': 'other-project'}]\n")
        self.assertEqual(len(self.calls()), 2)

    def test_patch_hash_and_base_are_validated_before_mutation(self):
        self.run_prepare()
        patch = self.add_patch("one.patch", "new upstream", "first seam")
        patch.write_text("modified patch\n")
        integration = self.root / "integration"
        with self.assertRaisesRegex(prepare.PreparationError, "checksum mismatch"):
            self.run_prepare(integration, pristine=self.pristine)
        self.assertFalse(integration.exists())
        self.lock["integration"]["expected_upstream_revision"] = "0" * 40
        lock_path = self.root / "dependencies.lock.json"
        lock_path.write_text(json.dumps(self.lock))
        with self.assertRaisesRegex(prepare.PreparationError, "base does not match"):
            prepare.load_lock(lock_path)

    def test_failed_partial_patch_application_is_not_repaired_heuristically(self):
        self.run_prepare()
        self.add_patch("one.patch", "new upstream", "first seam")
        self.add_patch("two.patch", "incorrect base", "second seam")
        integration = self.root / "integration"
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_prepare(integration, pristine=self.pristine)
        self.assertFalse((integration / prepare.STAMP).exists())
        with self.assertRaisesRegex(prepare.PreparationError, "Unexpected staged"):
            self.run_prepare(integration, pristine=self.pristine)
        self.assertEqual((integration / "openscreen/source.txt").read_text(), "first seam\n")
        self.assertEqual(len(self.calls()), 4)


if __name__ == "__main__":
    unittest.main()
