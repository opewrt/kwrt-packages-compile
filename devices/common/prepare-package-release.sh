#!/usr/bin/env bash
set -euo pipefail

openwrt_dir="${1:-}"
release_dir="${2:-}"
package_arch="${3:-}"
metadata_dir="${4:-}"

if [ -z "$openwrt_dir" ] || [ -z "$release_dir" ] || [ -z "$package_arch" ] || [ -z "$metadata_dir" ]; then
	echo "Usage: prepare-package-release.sh OPENWRT_DIR RELEASE_DIR PACKAGE_ARCH METADATA_DIR" >&2
	exit 1
fi

openwrt_dir="$(cd "$openwrt_dir" && pwd)"
metadata_dir="$(cd "$metadata_dir" && pwd)"
rm -rf "$release_dir"
mkdir -p "$release_dir/packages/$package_arch" "$release_dir/release-assets"

if [ -d "$openwrt_dir/bin/packages/$package_arch" ]; then
	while read -r feed_name; do
		[ -n "$feed_name" ] || continue
		feed_dir="$openwrt_dir/bin/packages/$package_arch/$feed_name"
		[ -d "$feed_dir" ] || continue
		mkdir -p "$release_dir/packages/$package_arch/$feed_name"
		cp -a "$feed_dir/." "$release_dir/packages/$package_arch/$feed_name/"
	done < "$openwrt_dir/.managed-feeds"
fi

if find "$release_dir/packages" -type f \( -name 'kernel_*.ipk' -o -name 'kmod-*.ipk' \) -print -quit | grep -q .; then
	echo "Package Release must not contain kernel or kmod IPKs" >&2
	exit 1
fi

if ! find "$release_dir/packages" -type f -name '*.ipk' -print -quit | grep -q .; then
	if [ "${REQUIRE_IPK:-true}" = "true" ]; then
		echo "No compiled IPK files were found" >&2
		exit 1
	fi
fi

cp -f "$metadata_dir/MANIFEST.refs" "$release_dir/SDK-MANIFEST.refs"
cp -f "$metadata_dir/ASSETS.sha256sums" "$release_dir/SDK-ASSETS.sha256sums"
cp -f "$metadata_dir/SDK.refs" "$release_dir/SDK.refs"
cp -f "$openwrt_dir/.config" "$release_dir/package.config" 2>/dev/null || true
cp -f "$openwrt_dir/.managed-feeds" "$release_dir/MANAGED-FEEDS.txt" 2>/dev/null || true
cp -f "$openwrt_dir/feeds.conf" "$release_dir/feeds.conf"
cp -f "$openwrt_dir/BUILD-IDENTITY" "$release_dir/BUILD-IDENTITY"
for source_report in SOURCE-AUDIT.tsv SOURCE-AUDIT.json SOURCE-AUDIT-SUMMARY.txt SOURCE-MANIFEST.tsv; do
	cp -f "$openwrt_dir/$source_report" "$release_dir/$source_report"
done
if [ -d "$openwrt_dir/build-results" ]; then
	cp -a "$openwrt_dir/build-results/." "$release_dir/"
fi
if [ -d "$openwrt_dir/build-logs" ]; then
	mkdir -p "$release_dir/build-logs"
	cp -a "$openwrt_dir/build-logs/." "$release_dir/build-logs/"
fi

{
	echo "sdk_repository=${SDK_REPOSITORY:-unknown}"
	echo "sdk_release_tag=${SDK_RELEASE_TAG:-unknown}"
	echo "sdk_asset=${SDK_ASSET_NAME:-unknown}"
	echo "sdk_sha256=${SDK_SHA256:-unknown}"
	echo "package_arch=$package_arch"
	echo "package_filter=${PACKAGE_FILTER:-.*}"
	echo "build_identity=$(<"$openwrt_dir/BUILD-IDENTITY")"
	echo "package_compiler=${GITHUB_SHA:-$(git -C "${GITHUB_WORKSPACE:-$openwrt_dir}" rev-parse HEAD 2>/dev/null || true)}"
	echo "kwrt_main=${PRIVATE_WORKSPACE_COMMIT:-none}"
	if [ -d "${GITHUB_WORKSPACE:-}/private-workspace/.git" ]; then
		git -C "$GITHUB_WORKSPACE/private-workspace" config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
		while read -r key submodule_path; do
			case "$submodule_path" in
				luci-apps/*)
					feed_name="${submodule_path##*/}"
					feed_name="${feed_name#luci-app-}"
					commit="$(git -C "$GITHUB_WORKSPACE/private-workspace" ls-tree HEAD "$submodule_path" | awk '{print $3}')"
					echo "private.${feed_name}=$commit"
					;;
			esac
		done
	fi
} > "$release_dir/PACKAGE-BUILD.refs"

rm -rf "$release_dir/release-assets"
(cd "$release_dir" && find . -mindepth 1 -printf '%P\n' | sort > FILES.txt)
(cd "$release_dir" && rm -f SHA256SUMS && find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum > SHA256SUMS)

asset_dir="$release_dir/release-assets"
mkdir -p "$asset_dir"
package_asset_limit="${PACKAGE_ASSET_LIMIT:-$((1800 * 1024 * 1024))}"
if ! [[ "$package_asset_limit" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid package asset size limit: $package_asset_limit" >&2
	exit 1
fi
mapfile -d '' package_files < <(cd "$release_dir" && find packages \( -type f -o -type l \) -print0 | sort -z)
package_total_size=0
for package_file in "${package_files[@]}"; do
	package_total_size=$((package_total_size + $(stat -c %s "$release_dir/$package_file")))
done
if [ "$package_total_size" -le "$package_asset_limit" ]; then
	tar --use-compress-program="zstd -T0 -6" -cf "$asset_dir/packages-${package_arch}.tar.zst" -C "$release_dir" packages
else
	part_number=1
	part_size=0
	part_list="$asset_dir/.packages-part"
	: > "$part_list"
	for package_file in "${package_files[@]}"; do
		package_file_size="$(stat -c %s "$release_dir/$package_file")"
		if [ "$part_size" -gt 0 ] && [ $((part_size + package_file_size)) -gt "$package_asset_limit" ]; then
			printf -v part_asset 'packages-%s.part-%03d.tar.zst' "$package_arch" "$part_number"
			tar --null --use-compress-program="zstd -T0 -6" -cf "$asset_dir/$part_asset" -C "$release_dir" -T "$part_list"
			part_number=$((part_number + 1))
			part_size=0
			: > "$part_list"
		fi
		printf '%s\0' "$package_file" >> "$part_list"
		part_size=$((part_size + package_file_size))
	done
	if [ "$part_size" -gt 0 ]; then
		printf -v part_asset 'packages-%s.part-%03d.tar.zst' "$package_arch" "$part_number"
		tar --null --use-compress-program="zstd -T0 -6" -cf "$asset_dir/$part_asset" -C "$release_dir" -T "$part_list"
	fi
	rm -f "$part_list"
fi
while IFS= read -r package_asset; do
	if [ "$(stat -c %s "$package_asset")" -ge 2147483648 ]; then
		echo "Package release asset exceeds the GitHub 2 GiB limit: ${package_asset##*/}" >&2
		exit 1
	fi
done < <(find "$asset_dir" -maxdepth 1 -type f -name "packages-${package_arch}*.tar.zst" | sort)
if find "$release_dir/build-logs" -type f -print -quit 2>/dev/null | grep -q .; then
	tar --use-compress-program="zstd -T0 -6" -cf "$asset_dir/build-logs.tar.zst" -C "$release_dir" build-logs
fi

for file in \
	SDK-MANIFEST.refs \
	SDK-ASSETS.sha256sums \
	SDK.refs \
	PACKAGE-BUILD.refs \
	package.config \
	BUILD-RESULTS.tsv \
	EXPECTED.txt \
	FAILED-DEPENDENCIES.txt \
	SUMMARY.txt \
	SUCCESS.txt \
	FAILED.txt \
	SKIPPED.txt \
	MANAGED-FEEDS.txt \
	feeds.conf \
	BUILD-IDENTITY \
	SOURCE-AUDIT.tsv \
	SOURCE-AUDIT.json \
	SOURCE-AUDIT-SUMMARY.txt \
	SOURCE-MANIFEST.tsv \
	FILES.txt \
	SHA256SUMS; do
	if [ -s "$release_dir/$file" ]; then
		cp -f "$release_dir/$file" "$asset_dir/"
	fi
done

(
	cd "$asset_dir"
	find . -maxdepth 1 -type f ! -name ASSETS.sha256sums -printf '%P\n' | sort > ASSETS.txt
	find . -maxdepth 1 -type f ! -name ASSETS.sha256sums -printf '%P\0' | sort -z | xargs -0 sha256sum > ASSETS.sha256sums
)

printf '%s\n' "$release_dir"
