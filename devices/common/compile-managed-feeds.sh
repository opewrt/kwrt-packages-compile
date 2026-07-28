#!/usr/bin/env bash
set -uo pipefail

shopt -s nullglob

managed_feeds_file="${MANAGED_FEEDS_FILE:-$PWD/.managed-feeds}"
package_filter="${PACKAGE_FILTER:-.*}"
results_dir="${BUILD_RESULTS_DIR:-$PWD/build-results}"
logs_dir="${BUILD_LOGS_DIR:-$PWD/build-logs}"
jobs="${JOBS:-$(($(nproc) + 1))}"

mkdir -p "$results_dir" "$logs_dir"
results_file="$results_dir/BUILD-RESULTS.tsv"
printf 'feed\tpackage\tstatus\tlog\n' > "$results_file"
: > "$results_dir/SUCCESS.txt"
: > "$results_dir/FAILED.txt"
: > "$results_dir/SKIPPED.txt"

if [ ! -f "$managed_feeds_file" ]; then
	echo "Managed feeds list is missing: $managed_feeds_file" >&2
	exit 1
fi

grep -E "$package_filter" /dev/null >/dev/null 2>&1
filter_status=$?
if [ "$filter_status" -eq 2 ]; then
	echo "Invalid package regex: $package_filter" >&2
	exit 1
fi

success=0
failed=0
skipped=0
found=0
matched=0

while read -r feed_name; do
	[ -n "$feed_name" ] || continue
	if [ ! -d "feeds/$feed_name" ]; then
		echo "Managed feed directory is missing: feeds/$feed_name" >&2
		failed=$((failed + 1))
		printf '%s\t%s\tfailed\t%s\n' "$feed_name" '(feed)' '-' >> "$results_file"
		printf '%s/%s\n' "$feed_name" '(feed)' >> "$results_dir/FAILED.txt"
		continue
	fi
	for makefile in "feeds/$feed_name"/*/Makefile; do
		found=$((found + 1))
		package_dir="${makefile%/Makefile}"
		package_name="${package_dir##*/}"
		package_ref="$feed_name/$package_name"
		if ! printf '%s\n' "$package_name" | grep -Eq "$package_filter"; then
			skipped=$((skipped + 1))
			printf '%s\t%s\tskipped\t%s\n' "$feed_name" "$package_name" '-' >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SKIPPED.txt"
			continue
		fi
		matched=$((matched + 1))

		echo "compile $package_ref"
		target="package/feeds/$feed_name/$package_name/compile"
		log_name="${feed_name}_${package_name}.log"
		log_file="$logs_dir/$log_name"
		if make -k "$target" -j"$jobs"; then
			success=$((success + 1))
			printf '%s\t%s\tsuccess\t%s\n' "$feed_name" "$package_name" '-' >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SUCCESS.txt"
			continue
		fi

		echo "retry $package_ref with -j1 V=s"
		if make "$target" -j1 V=s 2>&1 | tee "$log_file"; then
			success=$((success + 1))
			printf '%s\t%s\tsuccess-after-retry\t%s\n' "$feed_name" "$package_name" "build-logs/$log_name" >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/SUCCESS.txt"
		else
			failed=$((failed + 1))
			printf '%s\t%s\tfailed\t%s\n' "$feed_name" "$package_name" "build-logs/$log_name" >> "$results_file"
			printf '%s\n' "$package_ref" >> "$results_dir/FAILED.txt"
		fi
	done
done < "$managed_feeds_file"

if [ "$found" -eq 0 ]; then
	echo "No managed source packages were found" >&2
	exit 1
fi
if [ "$matched" -eq 0 ]; then
	echo "Package regex matched no managed source packages: $package_filter" >&2
	exit 1
fi

{
	echo "found=$found"
	echo "matched=$matched"
	echo "success=$success"
	echo "failed=$failed"
	echo "skipped=$skipped"
} > "$results_dir/SUMMARY.txt"

printf 'found=%s matched=%s success=%s failed=%s skipped=%s\n' "$found" "$matched" "$success" "$failed" "$skipped"
[ "$failed" -eq 0 ]
