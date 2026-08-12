#!/usr/bin/env python3
"""Download one file from a GitHub Actions artifact using HTTP ranges."""

from __future__ import annotations

import argparse
import os
import struct
import urllib.error
import urllib.request
import zlib
from pathlib import Path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):  # type: ignore[no-untyped-def]
        return None


def open_signed_url(url: str, token: str) -> str:
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        opener.open(request)
    except urllib.error.HTTPError as error:
        if error.code in (302, 307) and error.headers.get("Location"):
            return error.headers["Location"]
        raise
    raise SystemExit("artifact download endpoint did not redirect")


def read_range(url: str, start: int, end: int) -> tuple[bytes, int]:
    request = urllib.request.Request(
        url,
        headers={"Range": f"bytes={start}-{end}"},
    )
    with urllib.request.urlopen(request) as response:
        content_range = response.headers.get("Content-Range", "")
        if response.status != 206 or "/" not in content_range:
            raise SystemExit("artifact storage did not honor the HTTP range request")
        length = int(content_range.rsplit("/", 1)[1])
        return response.read(), length


def central_directory(url: str) -> bytes:
    _, length = read_range(url, 0, 0)
    start = max(0, length - 65_557)
    tail, _ = read_range(url, start, length - 1)
    marker = tail.rfind(b"PK\x05\x06")
    if marker < 0:
        raise SystemExit("artifact ZIP end record was not found")
    end_record = tail[marker : marker + 22]
    _, _, _, _, _, directory_size, directory_offset, _ = struct.unpack(
        "<4s4H2LH", end_record
    )
    directory, _ = read_range(
        url,
        directory_offset,
        directory_offset + directory_size - 1,
    )
    return directory


def find_entry(directory: bytes, expected_name: str) -> tuple[int, int, int]:
    offset = 0
    while offset < len(directory):
        if directory[offset : offset + 4] != b"PK\x01\x02":
            break
        fields = struct.unpack("<4s6H3L5H2L", directory[offset : offset + 46])
        method = fields[4]
        compressed_size = fields[8]
        name_length = fields[10]
        extra_length = fields[11]
        comment_length = fields[12]
        local_offset = fields[16]
        name = directory[offset + 46 : offset + 46 + name_length].decode()
        if name == expected_name:
            return method, compressed_size, local_offset
        offset += 46 + name_length + extra_length + comment_length
    raise SystemExit(f"artifact entry was not found: {expected_name}")


def download_entry(url: str, entry_name: str) -> bytes:
    method, compressed_size, local_offset = find_entry(
        central_directory(url), entry_name
    )
    local_header, _ = read_range(url, local_offset, local_offset + 29)
    fields = struct.unpack("<4s5H3L2H", local_header)
    name_length, extra_length = fields[-2:]
    data_offset = local_offset + 30 + name_length + extra_length
    data, _ = read_range(
        url,
        data_offset,
        data_offset + compressed_size - 1,
    )
    if method == 8:
        return zlib.decompress(data, -15)
    if method == 0:
        return data
    raise SystemExit(f"unsupported artifact ZIP compression method: {method}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--artifact-id", required=True)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise SystemExit("GITHUB_TOKEN is required")
    signed_url = open_signed_url(
        f"https://api.github.com/repos/{args.repository}/actions/artifacts/"
        f"{args.artifact_id}/zip",
        token,
    )
    args.output.write_bytes(download_entry(signed_url, args.entry))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
