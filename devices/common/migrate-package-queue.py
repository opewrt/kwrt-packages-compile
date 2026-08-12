#!/usr/bin/env python3
"""Migrate completed queue units when the current plan only adds units."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def queue_units(path: Path) -> dict[str, tuple[tuple[str, str, str, str], ...]]:
    units: dict[str, list[tuple[str, str, str, str]]] = {}
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
    ):
        fields = line.split("\t")
        if len(fields) != 5 or not fields[0]:
            raise SystemExit(f"invalid queue row in {path}:{line_number}")
        unit_id, phase, ref, target, report = fields
        units.setdefault(unit_id, []).append((phase, ref, target, report))
    return {unit_id: tuple(rows) for unit_id, rows in units.items()}


def unique_signatures(
    units: dict[str, tuple[tuple[str, str, str, str], ...]], path: Path
) -> dict[tuple[tuple[str, str, str, str], ...], str]:
    signatures: dict[tuple[tuple[str, str, str, str], ...], str] = {}
    for unit_id, signature in units.items():
        if signature in signatures:
            raise SystemExit(
                f"duplicate queue unit signature in {path}: "
                f"{signatures[signature]} and {unit_id}"
            )
        signatures[signature] = unit_id
    return signatures


def migrate(
    previous_queue: Path,
    current_queue: Path,
    completed_file: Path,
) -> tuple[list[str], dict[str, int]]:
    previous_units = queue_units(previous_queue)
    current_units = queue_units(current_queue)
    current_signatures = unique_signatures(current_units, current_queue)

    missing_units = sorted(
        unit_id
        for unit_id, signature in previous_units.items()
        if signature not in current_signatures
    )
    if missing_units:
        raise SystemExit(
            "current queue changed or removed previous units:\n" + "\n".join(missing_units)
        )

    completed = {
        line
        for line in completed_file.read_text(encoding="utf-8", errors="replace").splitlines()
        if line
    }
    unknown = sorted(completed - previous_units.keys())
    if unknown:
        raise SystemExit(
            "completed state contains units absent from previous queue:\n"
            + "\n".join(unknown)
        )

    migrated = sorted(
        current_signatures[previous_units[unit_id]] for unit_id in completed
    )
    return migrated, {
        "previous_units": len(previous_units),
        "current_units": len(current_units),
        "added_units": len(current_units) - len(previous_units),
        "previous_completed": len(completed),
        "migrated_completed": len(migrated),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--previous-queue", type=Path, required=True)
    parser.add_argument("--current-queue", type=Path, required=True)
    parser.add_argument("--completed", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    migrated, summary = migrate(
        args.previous_queue,
        args.current_queue,
        args.completed,
    )
    args.output.write_text(
        "".join(f"{unit_id}\n" for unit_id in migrated),
        encoding="utf-8",
    )
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
