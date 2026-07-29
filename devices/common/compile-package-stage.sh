#!/usr/bin/env bash
set -uo pipefail

plan_file="${1:-}"
stage_name="${2:-}"
mode="${3:-}"
results_dir="${BUILD_RESULTS_DIR:-$PWD/build-results}"
logs_dir="${BUILD_LOGS_DIR:-$PWD/build-logs}"
jobs="${JOBS:-$(($(nproc) + 1))}"

if [ -z "$plan_file" ] || [ ! -f "$plan_file" ] || [ -z "$stage_name" ]; then
	echo "Usage: compile-package-stage.sh PLAN_TSV STAGE_NAME [foundation|leaf]" >&2
	exit 1
fi
case "$mode" in
	foundation|leaf) ;;
	*) echo "Invalid build stage mode: $mode" >&2; exit 1 ;;
esac

mkdir -p "$results_dir" "$logs_dir"
results_file="$results_dir/BUILD-RESULTS.tsv"
printf 'feed\tpackage\tstatus\tlog\n' > "$results_file"
: > "$results_dir/EXPECTED.txt"
: > "$results_dir/SUCCESS.txt"
: > "$results_dir/FAILED.txt"
: > "$results_dir/SKIPPED.txt"
: > "$results_dir/FAILED-DEPENDENCIES.txt"
if [ "$mode" = "foundation" ] && [ -f "${BUILD_PLAN_DIR:-$PWD/build-plan}/SKIPPED.txt" ]; then
	cp -f "${BUILD_PLAN_DIR:-$PWD/build-plan}/SKIPPED.txt" "$results_dir/SKIPPED.txt"
fi

mapfile -t build_targets < <(awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' "$plan_file")
bulk_status=0
if [ "${#build_targets[@]}" -gt 0 ]; then
	bulk_args=(-k -j"$jobs")
	if [ "$mode" = "leaf" ]; then
		bulk_args+=(NO_DEPS=1)
	fi
	echo "compile ${#build_targets[@]} targets in one dependency graph ($stage_name)"
	make "${bulk_args[@]}" "${build_targets[@]}" || bulk_status=$?
fi

success=0
failed=0
dependency_failed=0
found=0
while IFS=$'\t' read -r package_ref target report; do
	[ -n "$target" ] || continue
	found=$((found + 1))
	feed_name="${package_ref%%/*}"
	package_name="${package_ref#*/}"
	if [ "$report" = "1" ]; then
		printf '%s\n' "$package_ref" >> "$results_dir/EXPECTED.txt"
	fi
	if [ "$bulk_status" -eq 0 ]; then
		if [ "$report" = "1" ]; then
			success=$((success + 1))
			printf '%s\t%s\tsuccess\t%s\n' "$feed_name" "$package_name" '-' >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SUCCESS.txt"
		fi
		continue
	fi

	echo "diagnose $target ($stage_name)"
	log_name="${stage_name}_${target//\//_}.log"
	log_file="$logs_dir/$log_name"
	make_args=("$target" -j"$jobs")
	if [ "$mode" = "leaf" ]; then
		make_args+=(NO_DEPS=1)
	fi
	if make -k "${make_args[@]}"; then
		if [ "$report" = "1" ]; then
			success=$((success + 1))
			printf '%s\t%s\tsuccess\t%s\n' "$feed_name" "$package_name" '-' >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SUCCESS.txt"
		fi
		continue
	fi

	echo "retry $target with -j1 V=s"
	retry_args=("$target" -j1 V=s)
	if [ "$mode" = "leaf" ]; then
		retry_args+=(NO_DEPS=1)
	fi
	if make "${retry_args[@]}" 2>&1 | tee "$log_file"; then
		if [ "$report" = "1" ]; then
			success=$((success + 1))
			printf '%s\t%s\tsuccess-after-retry\t%s\n' "$feed_name" "$package_name" "build-logs/$log_name" >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SUCCESS.txt"
		fi
	elif [ "$report" = "1" ]; then
		failed=$((failed + 1))
		printf '%s\t%s\tfailed\t%s\n' "$feed_name" "$package_name" "build-logs/$log_name" >> "$results_file"
		printf '%s\n' "$package_ref" >> "$results_dir/FAILED.txt"
	else
		dependency_failed=$((dependency_failed + 1))
		printf '%s\t%s\n' "$target" "build-logs/$log_name" >> "$results_dir/FAILED-DEPENDENCIES.txt"
	fi
done < "$plan_file"

skipped="$(awk 'NF { count++ } END { print count + 0 }' "$results_dir/SKIPPED.txt")"
{
	echo "stage=$stage_name"
	echo "mode=$mode"
	echo "found=$found"
	echo "success=$success"
	echo "failed=$failed"
	echo "dependency_failed=$dependency_failed"
	echo "skipped=$skipped"
} > "$results_dir/SUMMARY.txt"

printf 'stage=%s mode=%s found=%s success=%s failed=%s dependency_failed=%s skipped=%s\n' \
	"$stage_name" "$mode" "$found" "$success" "$failed" "$dependency_failed" "$skipped"
[ "$failed" -eq 0 ] && [ "$dependency_failed" -eq 0 ]
