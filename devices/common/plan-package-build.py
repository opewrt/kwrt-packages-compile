#!/usr/bin/env python3
"""Plan dependency-aware staged builds from OpenWrt package metadata."""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path


BUILD_TARGET_RE = re.compile(r"^(?:package|tools|toolchain)/[^\s:#%$]+/(?:host/)?compile$")
DEP_SPEC_RE = re.compile(r"([A-Za-z0-9][A-Za-z0-9_.+@-]*)(/host)?")


def source_target(source_makefile: str, host: bool = False) -> str | None:
    path = source_makefile.removesuffix("/Makefile")
    if path.startswith("feeds/"):
        path = "package/" + path
    if not path.startswith(("package/", "tools/", "toolchain/")):
        return None
    return f"{path}/{'host/' if host else ''}compile"


def parse_packageinfo(path: Path) -> tuple[dict[str, set[str]], dict[str, str]]:
    graph: dict[str, set[str]] = defaultdict(set)
    package_sources: dict[str, str] = {}
    records: list[dict[str, list[str]]] = []
    record: dict[str, list[str]] = defaultdict(list)
    current_key: str | None = None

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines() + [""]:
        if not raw_line.strip() or raw_line.strip() == "@@":
            if record:
                records.append(dict(record))
                record = defaultdict(list)
                current_key = None
            continue
        if raw_line[:1].isspace() and current_key:
            record[current_key][-1] += " " + raw_line.strip()
            continue
        if ":" not in raw_line:
            continue
        key, value = raw_line.split(":", 1)
        current_key = key.strip()
        record[current_key].append(value.strip())

    current_target: str | None = None
    for item in records:
        sources = item.get("Source-Makefile", [])
        if sources:
            current_target = source_target(sources[-1])
        if not current_target:
            continue
        graph[current_target]
        for field in ("Package", "Provides"):
            for value in item.get(field, []):
                for name, _ in DEP_SPEC_RE.findall(value):
                    package_sources[name] = current_target

    return graph, package_sources


def parse_printdb(path: Path, graph: dict[str, set[str]]) -> None:
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line or raw_line[0].isspace() or raw_line.startswith("#") or ":" not in raw_line:
            continue
        left, right = raw_line.split(":", 1)
        targets = [token for token in left.split() if BUILD_TARGET_RE.match(token)]
        if not targets:
            continue
        dependencies = {token for token in right.split() if BUILD_TARGET_RE.match(token)}
        for target in targets:
            graph[target].update(dependency for dependency in dependencies if dependency != target)
            for dependency in dependencies:
                graph[dependency]


def tarjan(nodes: set[str], graph: dict[str, set[str]]) -> tuple[list[list[str]], dict[str, int]]:
    index = 0
    stack: list[str] = []
    on_stack: set[str] = set()
    indices: dict[str, int] = {}
    lowlinks: dict[str, int] = {}
    components: list[list[str]] = []

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = lowlinks[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)
        for dependency in sorted(graph.get(node, set()) & nodes):
            if dependency not in indices:
                visit(dependency)
                lowlinks[node] = min(lowlinks[node], lowlinks[dependency])
            elif dependency in on_stack:
                lowlinks[node] = min(lowlinks[node], indices[dependency])
        if lowlinks[node] == indices[node]:
            component: list[str] = []
            while True:
                member = stack.pop()
                on_stack.remove(member)
                component.append(member)
                if member == node:
                    break
            components.append(sorted(component))

    for node in sorted(nodes):
        if node not in indices:
            visit(node)
    component_of = {node: component_id for component_id, members in enumerate(components) for node in members}
    return components, component_of


def dependency_order(nodes: set[str], graph: dict[str, set[str]]) -> list[str]:
    components, component_of = tarjan(nodes, graph)
    component_dependencies: dict[int, set[int]] = defaultdict(set)
    for node in nodes:
        source = component_of[node]
        for dependency in graph.get(node, set()) & nodes:
            target = component_of[dependency]
            if source != target:
                component_dependencies[source].add(target)

    ordered_components: list[int] = []
    visited: set[int] = set()

    def visit(component: int) -> None:
        if component in visited:
            return
        visited.add(component)
        for dependency in sorted(component_dependencies[component]):
            visit(dependency)
        ordered_components.append(component)

    for component in range(len(components)):
        visit(component)
    return [node for component in ordered_components for node in components[component]]


def reachable(roots: set[str], graph: dict[str, set[str]]) -> set[str]:
    found: set[str] = set()
    pending = list(roots)
    while pending:
        node = pending.pop()
        if node in found:
            continue
        found.add(node)
        pending.extend(graph.get(node, set()) - found)
    return found


def managed_ref(target: str) -> str | None:
    match = re.match(r"^package/feeds/([^/]+)/([^/]+)/compile$", target)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def write_rows(path: Path, rows: list[tuple[str, str, int, int]]) -> None:
    path.write_text(
        "".join(f"{ref}\t{target}\t{report}\t{build}\n" for ref, target, report, build in rows),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packageinfo", type=Path, required=True)
    parser.add_argument("--printdb", type=Path, required=True)
    parser.add_argument("--managed-feeds", type=Path, required=True)
    parser.add_argument("--package-filter", default=".*")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-bundles", type=int, default=8)
    parser.add_argument("--bundle-size", type=int, default=12)
    args = parser.parse_args()

    if args.max_bundles < 1 or args.bundle_size < 1:
        parser.error("bundle limits must be positive")
    try:
        package_filter = re.compile(args.package_filter)
    except re.error as error:
        parser.error(f"invalid package regex: {error}")

    graph, _ = parse_packageinfo(args.packageinfo)
    parse_printdb(args.printdb, graph)
    feeds = {line.strip() for line in args.managed_feeds.read_text(encoding="utf-8").splitlines() if line.strip()}
    managed = {
        target: ref
        for target in graph
        if (ref := managed_ref(target)) and ref.split("/", 1)[0] in feeds
    }
    selected = {target for target, ref in managed.items() if package_filter.search(ref.split("/", 1)[1])}
    skipped = sorted(set(managed.values()) - {managed[target] for target in selected})
    if not selected:
        raise SystemExit("Package regex matched no managed source packages")

    selected_components, selected_component_of = tarjan(selected, graph)
    selected_consumers: dict[int, set[int]] = defaultdict(set)
    for consumer in selected:
        consumer_component = selected_component_of[consumer]
        for dependency in graph.get(consumer, set()) & selected:
            dependency_component = selected_component_of[dependency]
            if consumer_component != dependency_component:
                selected_consumers[dependency_component].add(consumer_component)

    leaf_components = {
        component_id
        for component_id, members in enumerate(selected_components)
        if len(members) == 1 and not selected_consumers[component_id]
    }
    leaf_targets = {selected_components[component_id][0] for component_id in leaf_components}
    closure = reachable(selected, graph)
    foundation_targets = closure - leaf_targets
    foundation_consumers: dict[str, set[str]] = defaultdict(set)
    for consumer in foundation_targets:
        for dependency in graph.get(consumer, set()) & foundation_targets:
            foundation_consumers[dependency].add(consumer)
    foundation_roots = {
        target for target in foundation_targets if not foundation_consumers[target]
    }
    foundation_order = dependency_order(foundation_targets, graph)
    foundation_rows = [
        (
            managed.get(target, f"dependency/{target}"),
            target,
            int(target in selected),
            int(target in foundation_roots),
        )
        for target in foundation_order
    ]

    leaf_order = dependency_order(leaf_targets, graph)
    bundle_count = min(args.max_bundles, max(1, math.ceil(len(leaf_order) / args.bundle_size)))
    bundles: list[list[str]] = [[] for _ in range(bundle_count)]
    for index, target in enumerate(leaf_order):
        bundles[index % bundle_count].append(target)

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "bundles").mkdir(exist_ok=True)
    write_rows(args.output / "foundation.tsv", foundation_rows)
    for index, bundle in enumerate(bundles):
        write_rows(
            args.output / "bundles" / f"bundle-{index:03d}.tsv",
            [(managed[target], target, 1, 1) for target in bundle],
        )
    (args.output / "SKIPPED.txt").write_text("".join(f"{ref}\n" for ref in skipped), encoding="utf-8")

    matrix = {"include": [{"bundle": f"bundle-{index:03d}"} for index in range(bundle_count)]}
    (args.output / "matrix.json").write_text(json.dumps(matrix, separators=(",", ":")) + "\n", encoding="utf-8")
    plan = {
        "managed": len(managed),
        "selected": len(selected),
        "skipped": len(skipped),
        "source_host_nodes": len(closure),
        "sccs": len(selected_components),
        "foundation_targets": len(foundation_rows),
        "foundation_roots": len(foundation_roots),
        "foundation_managed": sum(row[2] for row in foundation_rows),
        "leaf_targets": len(leaf_targets),
        "leaf_bundles": bundle_count,
        "stage_count": bundle_count + 1,
    }
    (args.output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(plan, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
