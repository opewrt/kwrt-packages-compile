#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


COMMON_DIR = Path(__file__).resolve().parents[1]
PLANNER = COMMON_DIR / "plan-package-build.py"


class PlanPackageBuildTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        (self.root / "tmp").mkdir()
        self.packageinfo = self.root / "tmp" / ".packageinfo"
        self.printdb = self.root / "tmp" / ".make-printdb"
        self.config = self.root / "config"
        self.feeds = self.root / "managed-feeds"
        self.output = self.root / "output"
        self.feed_root = self.root / "package" / "feeds" / "packages"
        (self.feed_root / "iperf3").mkdir(parents=True)
        (self.feed_root / "iperf3" / "Makefile").write_text("", encoding="utf-8")
        self.packageinfo.write_text(
            """Source-Makefile: feeds/packages/iperf3/Makefile
Package: iperf3
Depends: +libiperf3
@@
Package: iperf3-ssl
Depends: +libopenssl
@@
Package: libiperf3
ABI-Version: 14
@@
Source-Makefile: feeds/packages/openssl/Makefile
Package: libopenssl
@@
""",
            encoding="utf-8",
        )
        self.printdb.write_text(
            "package/feeds/packages/iperf3/compile: package/feeds/packages/openssl/compile\n"
            "package/feeds/packages/openssl/compile:\n",
            encoding="utf-8",
        )
        self.config.write_text(
            "CONFIG_PACKAGE_iperf3=m\n"
            "CONFIG_PACKAGE_iperf3-ssl=m\n"
            "CONFIG_PACKAGE_libiperf3=m\n"
            "# CONFIG_PACKAGE_libopenssl is not set\n",
            encoding="utf-8",
        )
        self.feeds.write_text("packages\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_planner(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(PLANNER),
                "--packageinfo",
                str(self.packageinfo),
                "--config",
                str(self.config),
                "--printdb",
                str(self.printdb),
                "--managed-feeds",
                str(self.feeds),
                "--package-filter",
                "iperf3",
                "--output",
                str(self.output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_emits_selected_binary_packages_without_changing_queue_shape(self) -> None:
        result = self.run_planner()

        self.assertEqual(result.returncode, 0, result.stderr)
        queue_rows = (self.output / "queue.tsv").read_text(encoding="utf-8").splitlines()
        self.assertTrue(queue_rows)
        self.assertTrue(all(len(row.split("\t")) == 5 for row in queue_rows))
        iperf_unit = next(row.split("\t")[0] for row in queue_rows if "packages/iperf3" in row)
        self.assertEqual(
            (self.output / "unit-packages.tsv").read_text(encoding="utf-8").splitlines(),
            [
                f"{iperf_unit}\tiperf3\tpackages",
                f"{iperf_unit}\tiperf3-ssl\tpackages",
                f"{iperf_unit}\tlibiperf3-14\tpackages",
            ],
        )

    def test_excludes_host_only_source_from_binary_output_contract(self) -> None:
        (self.feed_root / "iperf3" / "Makefile").write_text(
            "PKG_HOST_ONLY:=1\n",
            encoding="utf-8",
        )

        result = self.run_planner()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "packages/iperf3",
            (self.output / "queue.tsv").read_text(encoding="utf-8"),
        )
        self.assertEqual(
            (self.output / "unit-packages.tsv").read_text(encoding="utf-8"),
            "",
        )

    def test_excludes_build_only_package_from_binary_output_contract(self) -> None:
        (self.feed_root / "iperf3" / "Makefile").write_text(
            """define Package/iperf3-ssl
  BUILDONLY:=1
endef
""",
            encoding="utf-8",
        )

        result = self.run_planner()

        self.assertEqual(result.returncode, 0, result.stderr)
        contracts = (self.output / "unit-packages.tsv").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("\tiperf3-ssl\t", contracts)
        self.assertIn("\tiperf3\tpackages\n", contracts)


if __name__ == "__main__":
    unittest.main()
