#!/usr/bin/env python3

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


COMMON_DIR = Path(__file__).resolve().parents[1]
AUDITOR = COMMON_DIR / "source-policy-audit.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class SourcePolicyAuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        (self.root / ".managed-feeds").write_text("public\n", encoding="utf-8")
        (self.root / ".private-feeds").write_text("private\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def add_fixture(self, fixture: str, feed: str, package: str) -> None:
        destination = self.root / "package" / "feeds" / feed / package
        destination.mkdir(parents=True)
        shutil.copyfile(FIXTURES / fixture / "Makefile", destination / "Makefile")

    def add_linked_fixture(self, fixture: str, feed: str, package: str) -> None:
        source = self.root / "feeds" / feed / package
        source.mkdir(parents=True)
        shutil.copyfile(FIXTURES / fixture / "Makefile", source / "Makefile")
        feed_root = self.root / "package" / "feeds" / feed
        feed_root.mkdir(parents=True, exist_ok=True)
        (feed_root / package).symlink_to(source, target_is_directory=True)

    def run_audit(self, mode: str = "report") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(AUDITOR), "--root", str(self.root), "--mode", mode],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_report_detects_p0_patterns_and_writes_stable_outputs(self) -> None:
        self.add_fixture("bad-git", "private", "bad-git")
        self.add_fixture("bad-branch", "public", "bad-branch")
        self.add_fixture("bad-hashes", "public", "bad-hashes")
        self.add_fixture("bad-head", "public", "bad-head")
        self.add_fixture("good", "public", "good")

        result = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.root / "SOURCE-AUDIT.json").read_text(encoding="utf-8"))
        self.assertEqual(
            {finding["code"] for finding in payload["findings"]},
            {
                "BUILD_PHASE_DEPENDENCY_UPDATE",
                "BUILD_PHASE_NETWORK",
                "GIT_MIRROR_HASH_MISSING",
                "GIT_VERSION_BRANCH",
                "GIT_VERSION_HEAD",
                "GIT_VERSION_SHORT_COMMIT",
                "HASH_DUMMY",
                "HASH_EMPTY",
                "HASH_FALLBACK",
                "HASH_INVALID",
                "HASH_SKIP",
                "URL_FLOATING_ARCHIVE",
                "URL_FLOATING_RAW",
                "URL_LATEST_DOWNLOAD",
            },
        )
        self.assertEqual(payload["makefiles"], 5)
        self.assertEqual(payload["p0"], 16)
        self.assertEqual(payload["status"], "fail")

        manifest = (self.root / "SOURCE-MANIFEST.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(manifest[1].split("\t")[:6], ["private", "private", "bad-git", "package/feeds/private/bad-git/Makefile", "primary", "primary"])
        self.assertEqual(manifest[2].split("\t")[:3], ["public", "public", "bad-branch"])
        self.assertEqual(manifest[3].split("\t")[:3], ["public", "public", "bad-head"])
        self.assertEqual(manifest[4].split("\t")[:3], ["public", "public", "good"])

        first_outputs = {
            name: (self.root / name).read_bytes()
            for name in ("SOURCE-AUDIT.tsv", "SOURCE-AUDIT.json", "SOURCE-AUDIT-SUMMARY.txt", "SOURCE-MANIFEST.tsv")
        }
        self.assertEqual(self.run_audit().returncode, 0)
        self.assertEqual(first_outputs, {name: (self.root / name).read_bytes() for name in first_outputs})

    def test_installed_feed_symlinks_are_scanned(self) -> None:
        self.add_linked_fixture("bad-head", "public", "bad-head")

        result = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.root / "SOURCE-AUDIT.json").read_text(encoding="utf-8"))
        self.assertEqual(payload["makefiles"], 1)
        self.assertEqual({finding["code"] for finding in payload["findings"]}, {"GIT_VERSION_HEAD"})

    def test_custom_and_primary_archive_sources_are_audited_and_manifested(self) -> None:
        self.add_fixture("custom-download", "public", "custom-download")
        self.add_fixture("missing-archive-hash", "public", "missing-archive-hash")
        self.add_fixture("dummy-source", "public", "dummy-source")

        result = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.root / "SOURCE-AUDIT.json").read_text(encoding="utf-8"))
        self.assertEqual(
            {finding["code"] for finding in payload["findings"]},
            {"ARCHIVE_HASH_MISSING", "CUSTOM_HASH_MISSING", "HASH_SKIP", "SOURCE_DUMMY"},
        )
        manifest = (self.root / "SOURCE-MANIFEST.tsv").read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            manifest[0],
            "feed\tscope\tpackage\tmakefile\tsource_kind\tsource_name\turl\turl_file\tfile\tversion\thash",
        )
        custom = next(row.split("\t") for row in manifest[1:] if "\tcustom\tgenerated\t" in row)
        self.assertEqual(custom[6:], ["https://example.invalid/generated", "generated-1.0.tar.gz", "generated.tar.gz", "1.0", "skip"])
        self.assertEqual(payload["makefiles"], 3)
        self.assertEqual(payload["sources"], 5)

    def test_locked_dependency_installs_are_allowed(self) -> None:
        self.add_fixture("locked-installs", "public", "locked-installs")

        result = self.run_audit("strict")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.root / "SOURCE-AUDIT.json").read_text(encoding="utf-8"))
        self.assertEqual(payload["findings"], [])

    def test_comments_do_not_trigger_and_strict_passes_clean_fixture(self) -> None:
        self.add_fixture("good", "public", "good")

        result = self.run_audit("strict")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.root / "SOURCE-AUDIT.json").read_text(encoding="utf-8"))
        self.assertEqual(payload["findings"], [])
        self.assertEqual(payload["status"], "pass")

    def test_strict_writes_reports_before_failing(self) -> None:
        self.add_fixture("bad-git", "private", "bad-git")

        result = self.run_audit("strict")

        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.root / "SOURCE-AUDIT.tsv").is_file())
        self.assertIn("status=fail\n", (self.root / "SOURCE-AUDIT-SUMMARY.txt").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
