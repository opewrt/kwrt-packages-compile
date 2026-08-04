#!/usr/bin/env python3
"""Plan a dependency-ordered build queue from OpenWrt package metadata."""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path


BUILD_TARGET_RE = re.compile(r"^(?:package|tools|toolchain)/[^\s:#%$]+/(?:host/)?compile$")
DEP_SPEC_RE = re.compile(r"([A-Za-z0-9][A-Za-z0-9_.+@-]*)(/host)?")


def unconditional_dependencies(value: str) -> list[str]:
    dependencies: list[str] = []
    for token in value.split():
        if ":" in token or token.startswith("@"):
            continue
        match = DEP_SPEC_RE.fullmatch(token.removeprefix("+"))
        if match:
            dependencies.append(match.group(1))
    return dependencies


def source_target(source_makefile: str, host: bool = False) -> str | None:
    path = source_makefile.removesuffix("/Makefile")
    if path.startswith("feeds/"):
        path = "package/" + path
    if not path.startswith(("package/", "tools/", "toolchain/")):
        return None
    return f"{path}/{'host/' if host else ''}compile"


def parse_packageinfo(
    path: Path,
) -> tuple[dict[str, set[str]], dict[str, str], dict[str, set[str]]]:
    graph: dict[str, set[str]] = defaultdict(set)
    package_sources: dict[str, str] = {}
    target_packages: dict[str, set[str]] = defaultdict(set)
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
    record_targets: list[tuple[str, dict[str, list[str]]]] = []
    for item in records:
        sources = item.get("Source-Makefile", [])
        if sources:
            current_target = source_target(sources[-1])
        if not current_target:
            continue
        graph[current_target]
        record_targets.append((current_target, item))
        for field in ("Package", "Provides"):
            for value in item.get(field, []):
                for name, _ in DEP_SPEC_RE.findall(value):
                    package_sources[name] = current_target
                    if field == "Package":
                        target_packages[current_target].add(name)

    for target, item in record_targets:
        for value in item.get("Depends", []):
            for name in unconditional_dependencies(value):
                dependency = package_sources.get(name)
                if dependency and dependency != target:
                    graph[target].add(dependency)

    return graph, package_sources, target_packages


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


def dependency_units(nodes: set[str], graph: dict[str, set[str]]) -> list[list[str]]:
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
    return [components[component] for component in ordered_components]


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packageinfo", type=Path, required=True)
    parser.add_argument("--printdb", type=Path, required=True)
    parser.add_argument("--managed-feeds", type=Path, required=True)
    parser.add_argument("--package-filter", default=".*")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        package_filter = re.compile(args.package_filter)
    except re.error as error:
        parser.error(f"invalid package regex: {error}")

    graph, _, target_packages = parse_packageinfo(args.packageinfo)
    parse_printdb(args.printdb, graph)
    feeds = {line.strip() for line in args.managed_feeds.read_text(encoding="utf-8").splitlines() if line.strip()}
    kernel_sources = {
        target
        for target, packages in target_packages.items()
        if any(package == "kernel" or package.startswith("kmod-") for package in packages)
    }
    managed = {
        target: ref
        for target in graph
        if (ref := managed_ref(target)) and ref.split("/", 1)[0] in feeds
    }
    selected = {
        target
        for target, ref in managed.items()
        if target not in kernel_sources and package_filter.search(ref.split("/", 1)[1])
    }
    skipped = sorted(set(managed.values()) - {managed[target] for target in selected})
    if not selected:
        raise SystemExit("Package regex matched no managed source packages")

    closure = {
        target
        for target in reachable(selected, graph)
        if target not in kernel_sources
    }
    closure_components, closure_component_of = tarjan(closure, graph)
    closure_consumers: dict[int, set[int]] = defaultdict(set)
    for consumer in closure:
        consumer_component = closure_component_of[consumer]
        for dependency in graph.get(consumer, set()) & closure:
            dependency_component = closure_component_of[dependency]
            if consumer_component != dependency_component:
                closure_consumers[dependency_component].add(consumer_component)

    leaf_components = {
        component_id
        for component_id, members in enumerate(closure_components)
        if len(members) == 1
        and members[0] in selected
        and not closure_consumers[component_id]
    }
    leaf_targets = {closure_components[component_id][0] for component_id in leaf_components}
    foundation_targets = closure - leaf_targets
    foundation_units = dependency_units(foundation_targets, graph)
    package_units = dependency_units(leaf_targets, graph)

    queue_rows: list[tuple[str, str, str, str, int]] = []
    unit_index = 0
    for phase, units in (("foundation", foundation_units), ("packages", package_units)):
        for unit in units:
            unit_id = f"unit-{unit_index:04d}"
            unit_index += 1
            for target in unit:
                queue_rows.append(
                    (
                        unit_id,
                        phase,
                        managed.get(target, f"dependency/{target}"),
                        target,
                        int(target in selected),
                    )
                )

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "queue.tsv").write_text(
        "".join(
            f"{unit_id}\t{phase}\t{ref}\t{target}\t{report}\n"
            for unit_id, phase, ref, target, report in queue_rows
        ),
        encoding="utf-8",
    )
    (args.output / "SKIPPED.txt").write_text("".join(f"{ref}\n" for ref in skipped), encoding="utf-8")

    plan = {
        "managed": len(managed),
        "selected": len(selected),
        "skipped": len(skipped),
        "source_host_nodes": len(closure),
        "sccs": len(foundation_units) + len(package_units),
        "foundation_targets": len(foundation_targets),
        "foundation_units": len(foundation_units),
        "package_targets": len(leaf_targets),
        "package_units": len(package_units),
        "queue_units": unit_index,
        "stage_count": 1,
    }
    (args.output / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(plan, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
