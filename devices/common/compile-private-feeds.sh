#!/bin/bash

set -o pipefail
shopt -s nullglob

PRIVATE_FEEDS_FILE="${PRIVATE_FEEDS_FILE:-$PWD/.private-feeds}"

if [ ! -f "$PRIVATE_FEEDS_FILE" ]; then
	echo "Private feeds are unavailable; skipping compilation."
	exit 0
fi

jobs="$(($(nproc) + 1))"
failed=0

while read -r feed_name; do
	[ -n "$feed_name" ] || continue
	for makefile in "feeds/$feed_name"/*/Makefile; do
		package_dir="${makefile%/Makefile}"
		package_name="${package_dir##*/}"
		error_log="error_${feed_name}_${package_name}.log"
		echo "compile ${feed_name}/${package_name}"
		if ! make -k "package/feeds/${feed_name}/${package_name}/compile" -j"$jobs"; then
			if make "package/feeds/${feed_name}/${package_name}/compile" -j1 V=s 2>&1 | tee "$error_log"; then
				rm -f "$error_log"
			else
				failed=1
			fi
		fi
	done
done < "$PRIVATE_FEEDS_FILE"

exit "$failed"
