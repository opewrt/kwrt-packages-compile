#!/usr/bin/env python3

from __future__ import annotations

import io
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


COMMON_DIR = Path(__file__).resolve().parents[1]
COMPILER = COMMON_DIR / "compile-package-queue.sh"


class CompilePackageQueueTest(unittest.TestCase):
    def test_final_validation_reads_package_column_only(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            state = root / "build-state"
            state.mkdir()
            (state / "completed.units").write_text(
                "unit-0000\n", encoding="utf-8"
            )
            queue = root / "queue.tsv"
            queue.write_text(
                "unit-0000\tpackages\tpackages/foo\t"
                "package/feeds/packages/foo/compile\t1\n",
                encoding="utf-8",
            )
            unit_packages = root / "unit-packages.tsv"
            unit_packages.write_text(
                "unit-0000\tfoo\tpackages\n", encoding="utf-8"
            )
            self.write_ipk(root / "bin" / "packages" / "foo.ipk", "foo")

            env = os.environ.copy()
            env["BUILD_STATE_DIR"] = str(state)
            result = subprocess.run(
                [str(COMPILER), str(queue), str(unit_packages)],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status=complete", result.stdout)

    @staticmethod
    def write_ipk(path: Path, package: str) -> None:
        path.parent.mkdir(parents=True)
        control_data = f"Package: {package}\n".encode()
        control_archive = io.BytesIO()
        with tarfile.open(fileobj=control_archive, mode="w:gz") as archive:
            info = tarfile.TarInfo("./control")
            info.size = len(control_data)
            archive.addfile(info, io.BytesIO(control_data))
        payload = control_archive.getvalue()
        with tarfile.open(path, mode="w") as archive:
            info = tarfile.TarInfo("./control.tar.gz")
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))


if __name__ == "__main__":
    unittest.main()
