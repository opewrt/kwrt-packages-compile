#!/usr/bin/env bash
set -euo pipefail

stages_dir="${1:-}"
openwrt_dir="${2:-}"
metadata_dir="${3:-}"
expected_stages="${STAGE_COUNT:-1}"

if [ -z "$stages_dir" ] || [ -z "$openwrt_dir" ] || [ -z "$metadata_dir" ]; then
	echo "Usage: merge-package-shards.sh STAGES_DIR OPENWRT_DIR METADATA_DIR" >&2
	exit 1
fi
if ! [[ "$expected_stages" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid expected stage count: $expected_stages" >&2
	exit 1
fi

mkdir -p "$openwrt_dir/bin" "$openwrt_dir/build-results" "$openwrt_dir/build-logs" "$metadata_dir"
results_dir="$openwrt_dir/build-results"
printf 'feed\tpackage\tstatus\tlog\n' > "$results_dir/BUILD-RESULTS.tsv"
for result_file in EXPECTED.txt SUCCESS.txt FAILED.txt SKIPPED.txt FAILED-DEPENDENCIES.txt; do
	: > "$results_dir/$result_file"
done

mapfile -d '' stage_dirs < <(find "$stages_dir" -mindepth 1 -maxdepth 2 -type f -name STAGE.txt -printf '%h\0' | sort -z)
if [ "${#stage_dirs[@]}" -ne "$expected_stages" ]; then
	echo "Expected $expected_stages stage artifacts, found ${#stage_dirs[@]}" >&2
	exit 1
fi

canonical="${stage_dirs[0]}"
declare -A seen_stages=()
declare -A ipk_hashes=()

for stage_dir in "${stage_dirs[@]}"; do
	stage_name="$(sed -n 's/^stage_name=//p' "$stage_dir/STAGE.txt")"
	compile_outcome="$(sed -n 's/^compile_outcome=//p' "$stage_dir/STAGE.txt")"
	if [ -z "$stage_name" ] || [ -n "${seen_stages[$stage_name]:-}" ]; then
		echo "Missing or duplicate stage name in $stage_dir/STAGE.txt" >&2
		exit 1
	fi
	seen_stages[$stage_name]=1
	if [ "$compile_outcome" != "success" ]; then
		echo "Package stage $stage_name did not compile successfully" >&2
		exit 1
	fi

	for metadata_file in openwrt.config managed-feeds feeds.conf build-identity SOURCE-AUDIT.tsv SOURCE-AUDIT.json SOURCE-AUDIT-SUMMARY.txt SOURCE-MANIFEST.tsv private-workspace-commit sdk-metadata/MANIFEST.refs sdk-metadata/ASSETS.sha256sums sdk-metadata/SDK.refs; do
		if [ ! -f "$stage_dir/metadata/$metadata_file" ]; then
			echo "Missing stage metadata: $stage_dir/metadata/$metadata_file" >&2
			exit 1
		fi
		if ! cmp -s "$canonical/metadata/$metadata_file" "$stage_dir/metadata/$metadata_file"; then
			echo "Stage metadata differs: $metadata_file" >&2
			exit 1
		fi
	done

	results="$stage_dir/build-results"
	for result_file in BUILD-RESULTS.tsv EXPECTED.txt SUCCESS.txt FAILED.txt SKIPPED.txt FAILED-DEPENDENCIES.txt; do
		if [ ! -f "$results/$result_file" ]; then
			echo "Missing stage result: $results/$result_file" >&2
			exit 1
		fi
	done
	tail -n +2 "$results/BUILD-RESULTS.tsv" >> "$results_dir/BUILD-RESULTS.tsv"
	for result_file in EXPECTED.txt SUCCESS.txt FAILED.txt SKIPPED.txt FAILED-DEPENDENCIES.txt; do
		cat "$results/$result_file" >> "$results_dir/$result_file"
	done

	if [ -d "$stage_dir/build-logs" ]; then
		cp -a "$stage_dir/build-logs/." "$openwrt_dir/build-logs/"
	fi
	if [ -d "$stage_dir/ipk/bin" ]; then
		while IFS= read -r -d '' ipk; do
			relative_path="${ipk#"$stage_dir/ipk/"}"
			ipk_name="${ipk##*/}"
			if [ "$ipk_name" = "__.ipk" ]; then
				echo "Ignoring malformed IPK with empty package metadata: $relative_path" >&2
				continue
			fi
			ipk_sha256="$(sha256sum "$ipk" | cut -d ' ' -f 1)"
			if [ -n "${ipk_hashes[$ipk_name]:-}" ] && [ "${ipk_hashes[$ipk_name]}" != "$ipk_sha256" ]; then
				echo "Conflicting IPK files named $ipk_name" >&2
				exit 1
			fi
			ipk_hashes[$ipk_name]="$ipk_sha256"
			destination="$openwrt_dir/$relative_path"
			mkdir -p "${destination%/*}"
			if [ -f "$destination" ] && ! cmp -s "$ipk" "$destination"; then
				echo "Conflicting IPK path: $relative_path" >&2
				exit 1
			fi
			cp -f "$ipk" "$destination"
		done < <(find "$stage_dir/ipk/bin" -type f -name '*.ipk' -print0 | sort -z)
	fi
done

for result_file in EXPECTED.txt SUCCESS.txt FAILED.txt SKIPPED.txt FAILED-DEPENDENCIES.txt; do
	awk 'NF' "$results_dir/$result_file" | sort > "$results_dir/$result_file.sorted"
	mv "$results_dir/$result_file.sorted" "$results_dir/$result_file"
done

if [ ! -s "$results_dir/EXPECTED.txt" ]; then
	echo "Package regex matched no managed source packages" >&2
	exit 1
fi
if [ -s "$results_dir/FAILED.txt" ] || [ -s "$results_dir/FAILED-DEPENDENCIES.txt" ]; then
	echo "One or more expected packages or foundation dependencies failed to compile" >&2
	exit 1
fi
if [ -n "$(uniq -d "$results_dir/EXPECTED.txt")" ]; then
	echo "Duplicate expected package results were found" >&2
	exit 1
fi
if [ -n "$(uniq -d "$results_dir/SUCCESS.txt")" ]; then
	echo "Duplicate successful package results were found" >&2
	exit 1
fi
comm -3 "$results_dir/EXPECTED.txt" "$results_dir/SUCCESS.txt" > "$results_dir/RESULT-DIFFERENCE.txt"
if [ -s "$results_dir/RESULT-DIFFERENCE.txt" ]; then
	echo "Not all expected packages have a successful result" >&2
	cat "$results_dir/RESULT-DIFFERENCE.txt" >&2
	exit 1
fi
rm -f "$results_dir/RESULT-DIFFERENCE.txt"

cp -f "$canonical/metadata/openwrt.config" "$openwrt_dir/.config"
cp -f "$canonical/metadata/managed-feeds" "$openwrt_dir/.managed-feeds"
cp -f "$canonical/metadata/feeds.conf" "$openwrt_dir/feeds.conf"
cp -f "$canonical/metadata/build-identity" "$openwrt_dir/BUILD-IDENTITY"
for source_report in SOURCE-AUDIT.tsv SOURCE-AUDIT.json SOURCE-AUDIT-SUMMARY.txt SOURCE-MANIFEST.tsv; do
	cp -f "$canonical/metadata/$source_report" "$openwrt_dir/$source_report"
done
cp -a "$canonical/metadata/sdk-metadata/." "$metadata_dir/"

found="$(($(wc -l < "$results_dir/BUILD-RESULTS.tsv") - 1))"
matched="$(wc -l < "$results_dir/EXPECTED.txt")"
success="$(wc -l < "$results_dir/SUCCESS.txt")"
failed="$(wc -l < "$results_dir/FAILED.txt")"
skipped="$(wc -l < "$results_dir/SKIPPED.txt")"
{
	echo "stage_count=$expected_stages"
	echo "found=$found"
	echo "matched=$matched"
	echo "success=$success"
	echo "failed=$failed"
	echo "skipped=$skipped"
} > "$results_dir/SUMMARY.txt"

printf 'stages=%s found=%s matched=%s success=%s failed=%s skipped=%s ipk=%s\n' \
	"$expected_stages" "$found" "$matched" "$success" "$failed" "$skipped" "${#ipk_hashes[@]}"
