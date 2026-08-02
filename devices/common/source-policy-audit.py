#!/usr/bin/env python3
"""Audit assembled managed-feed Makefiles for reproducible source policy."""

from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path


ASSIGN_RE = re.compile(r"^\s*([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*(?::=|\?=|\+=|=)\s*(.*?)\s*$")
FULL_HASH_RE = re.compile(r"^[0-9a-fA-F]{64}$")
SHORT_COMMIT_RE = re.compile(r"^[0-9a-fA-F]{4,39}$")
BRANCH_RE = re.compile(r"^(?:(?:refs/heads/|origin/)\S+|master|main|develop(?:ment)?|dev|trunk)$", re.I)
URL_RE = re.compile(r"https?://[^\s'\"<>]+", re.I)
LATEST_RE = re.compile(r"/latest/download(?:/|$)", re.I)
FLOATING_RAW_RE = re.compile(r"(?:raw\.githubusercontent\.com/[^/]+/[^/]+|/raw)/(?:refs/heads/)?(?:master|main|HEAD)(?:/|$)", re.I)
FLOATING_ARCHIVE_RE = re.compile(r"/archive/(?:refs/heads/)?(?:master|main|HEAD)(?:[/.]|$)", re.I)
NETWORK_RE = re.compile(
    r"(?:^|[;&|]\s*|\s)(?:curl|wget|aria2c?|git\s+(?:clone|fetch|pull|ls-remote|submodule\s+update)|"
    r"svn\s+(?:checkout|update)|hg\s+(?:clone|pull)|rsync\s+[^\n]*(?:://|@[^ :]+:))\b",
    re.I,
)
DEPENDENCY_RE = re.compile(
    r"(?:^|[;&|]\s*|\s)(?:(?:bun)\s+(?:install|update|upgrade|add)|"
    r"(?:python[0-9.]*\s+-m\s+)?pip[0-9.]*\s+install|go\s+(?:get|install|mod\s+(?:download|tidy|vendor))|"
    r"composer\s+(?:install|update)|bundle\s+(?:install|update)|"
    r"(?:apt-get|apt|apk|dnf|yum)\s+(?:install|update|upgrade))\b",
    re.I,
)
FRONTEND_INSTALL_RE = re.compile(r"(?:^|[;&|]\s*|\s)(npm|pnpm|yarn)\s+(ci|install|update|upgrade|add)\b([^;&|]*)", re.I)
CARGO_RE = re.compile(r"(?:^|[;&|]\s*|\s)cargo\s+(install|update|fetch)\b([^;&|]*)", re.I)
LOCKFILE_DELETE_RE = re.compile(r"(?:^|[;&|]\s*|\s)rm\s+(?:-[A-Za-z]+\s+)*(?:[^;&|\s]*[/])?(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock)\b", re.I)
PHASES = {"Build/Prepare", "Build/Configure", "Build/Compile"}
REPORT_FILES = ("SOURCE-AUDIT.tsv", "SOURCE-AUDIT.json", "SOURCE-AUDIT-SUMMARY.txt", "SOURCE-MANIFEST.tsv")


@dataclass(frozen=True, order=True)
class Finding:
    severity: str
    code: str
    feed: str
    package: str
    makefile: str
    line: int
    field: str
    value: str
    message: str


@dataclass(frozen=True, order=True)
class SourceEntry:
    feed: str
    scope: str
    package: str
    makefile: str
    source_kind: str
    source_name: str
    url: str
    url_file: str
    file: str
    version: str
    hash: str


def strip_comment(line: str) -> str:
    """Remove Make/shell comments while preserving quoted # characters."""
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "'\"":
            quote = char
        elif char == "#":
            return line[:index]
    return line


def logical_lines(lines: list[str]) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    start = 0
    parts: list[str] = []
    for number, raw in enumerate(lines, 1):
        active = strip_comment(raw.rstrip("\n"))
        if not parts:
            start = number
        continued = active.rstrip().endswith("\\")
        parts.append(active.rstrip()[:-1] if continued else active)
        if not continued:
            result.append((start, " ".join(part.strip() for part in parts)))
            parts = []
    if parts:
        result.append((start, " ".join(part.strip() for part in parts)))
    return result


def read_feed_names(path: Path, required: bool) -> list[str]:
    if not path.is_file():
        if required:
            raise SystemExit(f"feed list not found: {path}")
        return []
    names = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        name = strip_comment(raw).strip()
        if name:
            names.append(name)
    return sorted(set(names))


def display_value(value: str) -> str:
    return value.replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")


def makefiles_under(feed_root: Path) -> list[Path]:
    makefiles: list[Path] = []
    for directory, directories, files in os.walk(feed_root, followlinks=True):
        directories.sort()
        if "Makefile" in files:
            makefiles.append(Path(directory) / "Makefile")
    return makefiles


def add(findings: list[Finding], code: str, feed: str, package: str, makefile: str,
        line: int, field: str, value: str, message: str) -> None:
    findings.append(Finding("P0", code, feed, package, makefile, line, field, display_value(value), message))


def audit_hash(findings: list[Finding], feed: str, package: str, makefile: str,
               line: int, field: str, value: str) -> None:
    normalized = value.strip().strip("'\"")
    lowered = normalized.lower()
    if not normalized:
        add(findings, "HASH_EMPTY", feed, package, makefile, line, field, value, "source hash is empty")
    elif lowered == "skip":
        add(findings, "HASH_SKIP", feed, package, makefile, line, field, value, "source hash uses skip")
    elif lowered in {"dummy", "none"} or re.fullmatch(r"0{64}", normalized):
        add(findings, "HASH_DUMMY", feed, package, makefile, line, field, value, "source hash uses a dummy value")
    elif re.search(r"\b(?:skip|dummy)\b", normalized, re.I):
        add(findings, "HASH_FALLBACK", feed, package, makefile, line, field, value, "source hash contains an unsupported skip/dummy fallback")
    elif "$" not in normalized and not FULL_HASH_RE.fullmatch(normalized):
        add(findings, "HASH_INVALID", feed, package, makefile, line, field, value, "source hash is not a SHA-256 digest")


def dependency_update(line: str) -> bool:
    if DEPENDENCY_RE.search(line) or LOCKFILE_DELETE_RE.search(line):
        return True
    for match in FRONTEND_INSTALL_RE.finditer(line):
        tool, command, options = match.groups()
        if tool.lower() == "npm" and command.lower() == "ci":
            continue
        if command.lower() == "install":
            locked = "--frozen-lockfile" in options or (tool.lower() == "yarn" and "--immutable" in options)
            if locked:
                continue
        return True
    for match in CARGO_RE.finditer(line):
        if "--locked" not in match.group(2):
            return True
    return False


def audit_makefile(root: Path, path: Path, feed: str, private: set[str]) -> tuple[list[SourceEntry], list[Finding]]:
    relative = path.relative_to(root).as_posix()
    feed_root = root / "package" / "feeds" / feed
    package = path.parent.relative_to(feed_root).as_posix()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    logical = logical_lines(lines)
    assignments: dict[str, tuple[str, int]] = {}
    downloads: list[tuple[str, int, dict[str, tuple[str, int]]]] = []
    current_define = ""
    current_download: dict[str, tuple[str, int]] | None = None
    findings: list[Finding] = []

    for number, text in logical:
        define_match = re.match(r"^define\s+(\S+)", text)
        if define_match:
            current_define = define_match.group(1)
            if current_define.startswith("Download/"):
                current_download = {}
                downloads.append((current_define.removeprefix("Download/"), number, current_download))
            continue
        if text.strip() == "endef":
            current_define = ""
            current_download = None
            continue
        match = ASSIGN_RE.match(text)
        if match:
            field, raw_value = match.groups()
            target = current_download if current_download is not None else assignments if not current_define else None
            if target is not None:
                target[field] = (raw_value.strip(), number)
                if field in {"PKG_HASH", "PKG_MIRROR_HASH"} or current_download is not None and field == "HASH":
                    audit_hash(findings, feed, package, relative, number, field, raw_value)

        for url in URL_RE.findall(text):
            clean_url = url.rstrip(",);]")
            if LATEST_RE.search(clean_url):
                add(findings, "URL_LATEST_DOWNLOAD", feed, package, relative, number, "URL", clean_url, "URL uses a floating latest/download asset")
            if FLOATING_RAW_RE.search(clean_url):
                add(findings, "URL_FLOATING_RAW", feed, package, relative, number, "URL", clean_url, "raw URL uses master/main/HEAD")
            if FLOATING_ARCHIVE_RE.search(clean_url):
                add(findings, "URL_FLOATING_ARCHIVE", feed, package, relative, number, "URL", clean_url, "archive URL uses master/main/HEAD")

    for name, define_line, download in downloads:
        if any(field in download for field in ("URL", "URL_FILE", "FILE")) and "HASH" not in download:
            add(findings, "CUSTOM_HASH_MISSING", feed, package, relative, define_line,
                f"Download/{name}", "", "custom download is missing HASH")

    value = lambda key: assignments.get(key, ("", 0))[0]
    proto = value("PKG_SOURCE_PROTO").strip("'\"")
    source_url = value("PKG_SOURCE_URL")
    source_file = value("PKG_SOURCE")
    git_source = proto.lower().startswith("git") or bool(re.search(r"(?:^|\s)(?:git://|git\+https?://|https?://\S+\.git(?:\^\S+)?(?:\s|$))", source_url, re.I))
    if git_source:
        version, version_line = assignments.get("PKG_SOURCE_VERSION", ("", assignments.get("PKG_SOURCE_PROTO", ("", 1))[1]))
        normalized = version.strip().strip("'\"")
        if not normalized:
            add(findings, "GIT_VERSION_MISSING", feed, package, relative, version_line, "PKG_SOURCE_VERSION", version, "git source version is missing and may resolve HEAD")
        elif normalized.upper() == "HEAD":
            add(findings, "GIT_VERSION_HEAD", feed, package, relative, version_line, "PKG_SOURCE_VERSION", version, "git source version uses HEAD")
        elif BRANCH_RE.fullmatch(normalized):
            add(findings, "GIT_VERSION_BRANCH", feed, package, relative, version_line, "PKG_SOURCE_VERSION", version, "git source version uses a branch")
        elif SHORT_COMMIT_RE.fullmatch(normalized):
            add(findings, "GIT_VERSION_SHORT_COMMIT", feed, package, relative, version_line, "PKG_SOURCE_VERSION", version, "git source version uses a short commit")
        if "PKG_MIRROR_HASH" not in assignments:
            line = assignments.get("PKG_SOURCE_VERSION", assignments.get("PKG_SOURCE_PROTO", ("", 1)))[1]
            add(findings, "GIT_MIRROR_HASH_MISSING", feed, package, relative, line, "PKG_MIRROR_HASH", "", "git source is missing PKG_MIRROR_HASH")
    elif source_file:
        source_line = assignments["PKG_SOURCE"][1]
        normalized_source = source_file.strip().strip("'\"").lower()
        if normalized_source in {"dummy", "none"}:
            add(findings, "SOURCE_DUMMY", feed, package, relative, source_line, "PKG_SOURCE", source_file, "PKG_SOURCE uses a dummy/none source")
        elif "PKG_HASH" not in assignments:
            add(findings, "ARCHIVE_HASH_MISSING", feed, package, relative, source_line, "PKG_HASH", "", "archive source is missing PKG_HASH")

    phase = ""
    for number, raw in enumerate(lines, 1):
        active = strip_comment(raw).strip()
        define_match = re.match(r"^define\s+(\S+)", active)
        if define_match:
            phase = define_match.group(1) if define_match.group(1) in PHASES else ""
            continue
        if active == "endef":
            phase = ""
            continue
        if not phase or not active:
            continue
        if NETWORK_RE.search(active):
            add(findings, "BUILD_PHASE_NETWORK", feed, package, relative, number, phase, active, f"{phase} performs a network operation")
        if dependency_update(active):
            add(findings, "BUILD_PHASE_DEPENDENCY_UPDATE", feed, package, relative, number, phase, active, f"{phase} installs or updates dependencies")

    common = {
        "feed": feed,
        "scope": "private" if feed in private else "public",
        "package": package,
        "makefile": relative,
    }
    entries: list[SourceEntry] = []
    if source_file or source_url or proto:
        entries.append(SourceEntry(
            **common,
            source_kind="primary",
            source_name="primary",
            url=source_url,
            url_file="",
            file=source_file,
            version=value("PKG_SOURCE_VERSION"),
            hash=value("PKG_MIRROR_HASH") if git_source else value("PKG_HASH"),
        ))
    for name, _, download in downloads:
        custom_value = lambda key: download.get(key, ("", 0))[0]
        entries.append(SourceEntry(
            **common,
            source_kind="custom",
            source_name=name,
            url=custom_value("URL"),
            url_file=custom_value("URL_FILE"),
            file=custom_value("FILE"),
            version=custom_value("VERSION"),
            hash=custom_value("HASH"),
        ))
    return entries, findings


def write_reports(output: Path, managed: list[str], private: list[str], makefile_count: int,
                  entries: list[SourceEntry], findings: list[Finding]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    findings.sort()
    entries.sort()
    audit_header = "severity\tcode\tfeed\tpackage\tmakefile\tline\tfield\tvalue\tmessage\n"
    audit_rows = "".join("\t".join(display_value(str(value)) for value in asdict(item).values()) + "\n" for item in findings)
    (output / REPORT_FILES[0]).write_text(audit_header + audit_rows, encoding="utf-8")

    payload = {
        "findings": [asdict(item) for item in findings],
        "managed_feeds": managed,
        "makefiles": makefile_count,
        "p0": len(findings),
        "private_feeds": private,
        "sources": len(entries),
        "status": "fail" if findings else "pass",
        "version": 1,
    }
    (output / REPORT_FILES[1]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output / REPORT_FILES[2]).write_text(
        f"status={payload['status']}\nmanaged_feeds={len(managed)}\nprivate_feeds={len(private)}\n"
        f"makefiles={makefile_count}\nsources={len(entries)}\np0={len(findings)}\n",
        encoding="utf-8",
    )

    manifest_header = "feed\tscope\tpackage\tmakefile\tsource_kind\tsource_name\turl\turl_file\tfile\tversion\thash\n"
    manifest_rows = "".join("\t".join(display_value(value) for value in asdict(item).values()) + "\n" for item in entries)
    (output / REPORT_FILES[3]).write_text(manifest_header + manifest_rows, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--managed-feeds", type=Path, default=Path(".managed-feeds"))
    parser.add_argument("--private-feeds", type=Path, default=Path(".private-feeds"))
    parser.add_argument("--output", type=Path, default=Path("."))
    parser.add_argument("--mode", choices=("report", "strict"), default="report")
    args = parser.parse_args()

    root = args.root.resolve()
    managed_path = args.managed_feeds if args.managed_feeds.is_absolute() else root / args.managed_feeds
    private_path = args.private_feeds if args.private_feeds.is_absolute() else root / args.private_feeds
    output = args.output if args.output.is_absolute() else root / args.output
    managed = read_feed_names(managed_path, required=True)
    private = read_feed_names(private_path, required=False)
    private_set = set(private)

    entries: list[SourceEntry] = []
    findings: list[Finding] = []
    makefile_count = 0
    for feed in sorted(set(managed) | private_set):
        feed_root = root / "package" / "feeds" / feed
        if not feed_root.is_dir():
            continue
        for makefile in makefiles_under(feed_root):
            makefile_count += 1
            package_entries, package_findings = audit_makefile(root, makefile, feed, private_set)
            entries.extend(package_entries)
            findings.extend(package_findings)

    write_reports(output, managed, private, makefile_count, entries, findings)
    print(f"source audit: makefiles={makefile_count} sources={len(entries)} p0={len(findings)} mode={args.mode}")
    return 1 if args.mode == "strict" and findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
