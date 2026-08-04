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
tar --use-compress-program="zstd -T0 -6" -cf "$asset_dir/packages-${package_arch}.tar.zst" -C "$release_dir" packages
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
