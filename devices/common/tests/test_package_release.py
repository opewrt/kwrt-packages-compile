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
MERGER = COMMON_DIR / "merge-package-shards.sh"
RELEASER = COMMON_DIR / "prepare-package-release.sh"
METADATA_FILES = (
    "openwrt.config",
    "managed-feeds",
    "feeds.conf",
    "build-identity",
    "unit-packages.tsv",
    "SOURCE-AUDIT.tsv",
    "SOURCE-AUDIT.json",
    "SOURCE-AUDIT-SUMMARY.txt",
    "SOURCE-MANIFEST.tsv",
    "private-workspace-commit",
)
SDK_METADATA_FILES = ("MANIFEST.refs", "ASSETS.sha256sums", "SDK.refs")


class PackageReleaseTest(unittest.TestCase):
    def test_target_ipk_satisfies_contract_and_is_released(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            stages = root / "stages"
            stage = stages / "sequential"
            openwrt = root / "openwrt"
            metadata = root / "sdk-metadata"
            release = root / "release"
            self.prepare_stage(stage)
            self.write_ipk(
                stage
                / "ipk/bin/targets/x86/64/packages/autocore_3_x86_64.ipk",
                "autocore",
            )

            merge = subprocess.run(
                [str(MERGER), str(stages), str(openwrt), str(metadata)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(merge.returncode, 0, merge.stderr)
            self.assertTrue(
                (openwrt / "bin/targets/x86/64/packages/autocore_3_x86_64.ipk").is_file()
            )

            env = os.environ.copy()
            env["GITHUB_SHA"] = "0" * 40
            package_release = subprocess.run(
                [str(RELEASER), str(openwrt), str(release), "x86_64", str(metadata)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(package_release.returncode, 0, package_release.stderr)
            target_asset = release / "release-assets/targets-x86_64.tar.zst"
            self.assertTrue(target_asset.is_file())
            listing = subprocess.run(
                ["tar", "--zstd", "-tf", str(target_asset)],
                text=True,
                capture_output=True,
                check=True,
            ).stdout
            self.assertIn(
                "targets/x86/64/packages/autocore_3_x86_64.ipk",
                listing,
            )

    def prepare_stage(self, stage: Path) -> None:
        metadata = stage / "metadata"
        sdk_metadata = metadata / "sdk-metadata"
        results = stage / "build-results"
        sdk_metadata.mkdir(parents=True)
        results.mkdir(parents=True)
        (stage / "STAGE.txt").write_text(
            "stage_name=sequential\ncompile_outcome=success\n",
            encoding="utf-8",
        )
        for name in METADATA_FILES:
            value = "packages\n"
            if name == "unit-packages.tsv":
                value = "unit-0000\tautocore\tkiddin9\n"
            elif name == "build-identity":
                value = "identity\n"
            (metadata / name).write_text(value, encoding="utf-8")
        for name in SDK_METADATA_FILES:
            (sdk_metadata / name).write_text("metadata\n", encoding="utf-8")
        (results / "BUILD-RESULTS.tsv").write_text(
            "feed\tpackage\tstatus\tlog\n"
            "kiddin9\tautocore\tsuccess\t-\n",
            encoding="utf-8",
        )
        for name in (
            "EXPECTED.txt",
            "SUCCESS.txt",
        ):
            (results / name).write_text("kiddin9/autocore\n", encoding="utf-8")
        for name in ("FAILED.txt", "SKIPPED.txt", "FAILED-DEPENDENCIES.txt"):
            (results / name).write_text("", encoding="utf-8")

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
