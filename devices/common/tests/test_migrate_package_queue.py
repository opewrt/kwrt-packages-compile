#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


COMMON_DIR = Path(__file__).resolve().parents[1]
MIGRATOR = COMMON_DIR / "migrate-package-queue.py"


class MigratePackageQueueTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.previous = self.root / "previous.tsv"
        self.current = self.root / "current.tsv"
        self.completed = self.root / "completed.units"
        self.output = self.root / "migrated.units"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_migrator(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(MIGRATOR),
                "--previous-queue",
                str(self.previous),
                "--current-queue",
                str(self.current),
                "--completed",
                str(self.completed),
                "--output",
                str(self.output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_maps_completed_units_when_new_units_shift_ids(self) -> None:
        self.previous.write_text(
            "unit-0000\tfoundation\tpackages/a\tpackage/feeds/packages/a/compile\t1\n"
            "unit-0001\tpackages\tpackages/b\tpackage/feeds/packages/b/compile\t1\n",
            encoding="utf-8",
        )
        self.current.write_text(
            "unit-0000\tfoundation\tpackages/new\tpackage/feeds/packages/new/compile\t1\n"
            "unit-0001\tfoundation\tpackages/a\tpackage/feeds/packages/a/compile\t1\n"
            "unit-0002\tpackages\tpackages/b\tpackage/feeds/packages/b/compile\t1\n",
            encoding="utf-8",
        )
        self.completed.write_text("unit-0000\nunit-0001\n", encoding="utf-8")

        result = self.run_migrator()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8"),
            "unit-0001\nunit-0002\n",
        )
        self.assertIn('"added_units": 1', result.stdout)

    def test_rejects_changed_previous_unit(self) -> None:
        self.previous.write_text(
            "unit-0000\tpackages\tpackages/a\tpackage/feeds/packages/a/compile\t1\n",
            encoding="utf-8",
        )
        self.current.write_text(
            "unit-0000\tpackages\tpackages/a\tpackage/feeds/packages/a-changed/compile\t1\n",
            encoding="utf-8",
        )
        self.completed.write_text("unit-0000\n", encoding="utf-8")

        result = self.run_migrator()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current queue changed or removed previous units", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
