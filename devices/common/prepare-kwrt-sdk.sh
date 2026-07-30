#!/usr/bin/env bash
set -euo pipefail

sdk_archive="${1:-}"
target="${2:-}"
manifest="${3:-}"
workspace="${4:-}"
output_dir="${5:-$PWD/openwrt}"

if [ -z "$sdk_archive" ] || [ ! -f "$sdk_archive" ] || [ -z "$target" ] || [ -z "$manifest" ] || [ ! -f "$manifest" ] || [ -z "$workspace" ]; then
	echo "Usage: prepare-kwrt-sdk.sh SDK_ARCHIVE TARGET MANIFEST.refs WORKSPACE [OUTPUT_DIR]" >&2
	exit 1
fi

sdk_archive="$(cd "${sdk_archive%/*}" && pwd)/${sdk_archive##*/}"
workspace="$(cd "$workspace" && pwd)"
rm -rf "$output_dir" "$workspace/sdk-extract"
mkdir -p "$output_dir" "$workspace/sdk-extract"
tar --zstd -xf "$sdk_archive" -C "$workspace/sdk-extract"
sdk_root="$(find "$workspace/sdk-extract" -mindepth 1 -maxdepth 1 -type d -name '*sdk*' -print -quit)"
test -n "$sdk_root"
cp -a "$sdk_root/." "$output_dir/"
rm -rf "$workspace/sdk-extract" "$output_dir/dl" "$output_dir/.ccache"
find "$output_dir/bin" -type f -name '*.ipk' -delete 2>/dev/null || true
ln -s /mnt/openwrt/dl "$output_dir/dl"
ln -s /mnt/openwrt/ccache "$output_dir/.ccache"
cp -a "$workspace/devices" "$output_dir/"
cp -a "$workspace/devices/common/." "$output_dir/"
if [ -d "$workspace/devices/$target" ]; then
	cp -a "$workspace/devices/$target/." "$output_dir/"
fi

cd "$output_dir"
chmod -R +x devices/*
apply_patch_file() {
	local patch_file="$1"
	if patch -d . -p1 --dry-run --forward --no-backup-if-mismatch < "$patch_file" >/dev/null 2>&1; then
		patch -d . -p1 -E --forward --no-backup-if-mismatch < "$patch_file"
	elif patch -d . -p1 --dry-run --reverse --no-backup-if-mismatch < "$patch_file" >/dev/null 2>&1; then
		echo "Already applied: $patch_file"
	else
		echo "Cannot apply patch: $patch_file" >&2
		return 1
	fi
}

devices/common/configure-feeds.sh "$manifest"
while IFS= read -r -d '' patch_file; do
	apply_patch_file "$patch_file"
done < <(find devices/common/patches -type f -name '*.b.patch' -print0 | sort -z)
/bin/bash devices/common/custom.sh
if [ -f "devices/$target/custom.sh" ]; then
	/bin/bash "devices/$target/custom.sh"
fi
while IFS= read -r -d '' patch_file; do
	apply_patch_file "$patch_file"
done < <(find devices/common/patches -type f -name '*.patch' ! -name '*.b.patch' -print0 | sort -z)
if [ -d "devices/$target/patches" ]; then
	while IFS= read -r -d '' patch_file; do
		apply_patch_file "$patch_file"
	done < <(find "devices/$target/patches" -type f -name '*.patch' -print0 | sort -z)
fi
cp -a ./diy/. ./ 2>/dev/null || true
if [ -f "devices/$target/.config" ]; then
	printf '\n' >> .config
	cat "devices/$target/.config" >> .config
fi
rm -f tmp/.packageinfo tmp/.config-package.in tmp/info/.packageinfo-feeds_base_mac80211
make defconfig
