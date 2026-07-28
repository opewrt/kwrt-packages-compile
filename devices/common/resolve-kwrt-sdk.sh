#!/usr/bin/env bash
set -euo pipefail

repository="${1:-opewrt/Kwrt}"
package_arch="${2:-}"
requested_tag="${3:-}"
requested_asset="${4:-}"
metadata_dir="${5:-$PWD/sdk-metadata}"

if [ -z "$package_arch" ]; then
	echo "Usage: resolve-kwrt-sdk.sh REPOSITORY PACKAGE_ARCH [TAG] [ASSET] [METADATA_DIR]" >&2
	exit 1
fi

case "$repository" in
	[A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) ;;
	*) echo "Invalid GitHub repository: $repository" >&2; exit 1 ;;
esac

api="https://api.github.com/repos/$repository"
mkdir -p "$metadata_dir"

get_release() {
	local tag="$1"
	local release_file="$2"
	curl -fsSL --retry 5 --retry-delay 2 \
		-H 'Accept: application/vnd.github+json' \
		"$api/releases/tags/$tag" > "$release_file"
}

try_release() {
	local tag="$1"
	local work_dir="$2"
	local release_file="$work_dir/release.json"
	local manifest_url checksums_url manifest_arch sdk_asset sdk_url sdk_sha manifest_sha

	mkdir -p "$work_dir"
	if ! get_release "$tag" "$release_file"; then
		return 1
	fi
	if [ "$(jq -r '.draft or .prerelease' "$release_file")" = "true" ]; then
		return 1
	fi

	manifest_url="$(jq -r '.assets[] | select(.name == "MANIFEST.refs") | .browser_download_url' "$release_file" | head -n 1)"
	checksums_url="$(jq -r '.assets[] | select(.name == "ASSETS.sha256sums") | .browser_download_url' "$release_file" | head -n 1)"
	if [ -z "$manifest_url" ] || [ -z "$checksums_url" ]; then
		return 1
	fi

	curl -fsSL --retry 5 --retry-delay 2 "$manifest_url" -o "$work_dir/MANIFEST.refs"
	curl -fsSL --retry 5 --retry-delay 2 "$checksums_url" -o "$work_dir/ASSETS.sha256sums"
	manifest_arch="$(sed -n 's/^package_arch=//p' "$work_dir/MANIFEST.refs" | tail -n 1)"
	if [ "$manifest_arch" != "$package_arch" ]; then
		return 1
	fi

	if [ -n "$requested_asset" ]; then
		sdk_asset="$requested_asset"
	else
		sdk_asset="$(jq -r '.assets[].name | select(test("sdk"; "i") and endswith(".tar.zst"))' "$release_file" | head -n 1)"
	fi
	if [ -z "$sdk_asset" ]; then
		return 1
	fi
	sdk_url="$(jq -r --arg name "$sdk_asset" '.assets[] | select(.name == $name) | .browser_download_url' "$release_file" | head -n 1)"
	if [ -z "$sdk_url" ]; then
		return 1
	fi

	sdk_sha="$(awk -v name="$sdk_asset" '$2 == name { print $1 }' "$work_dir/ASSETS.sha256sums" | tail -n 1)"
	manifest_sha="$(awk '$2 == "MANIFEST.refs" { print $1 }' "$work_dir/ASSETS.sha256sums" | tail -n 1)"
	if ! [[ "$sdk_sha" =~ ^[0-9a-f]{64}$ ]] || ! [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]]; then
		return 1
	fi
	if [ "$(sha256sum "$work_dir/MANIFEST.refs" | awk '{print $1}')" != "$manifest_sha" ]; then
		echo "MANIFEST.refs checksum mismatch for $tag" >&2
		return 1
	fi

	printf '%s\n' "$tag" > "$work_dir/selected-tag"
	printf '%s\n' "$sdk_asset" > "$work_dir/selected-asset"
	printf '%s\n' "$sdk_url" > "$work_dir/sdk-url"
	printf '%s\n' "$sdk_sha" > "$work_dir/sdk-sha256"
	return 0
}

selected_dir=""
if [ -n "$requested_tag" ]; then
	candidate_dir="$(mktemp -d)"
	if ! try_release "$requested_tag" "$candidate_dir"; then
		rm -rf "$candidate_dir"
		echo "Kwrt release $requested_tag does not contain a verified SDK for $package_arch" >&2
		exit 1
	fi
	selected_dir="$candidate_dir"
else
	releases_file="$(mktemp)"
	page=1
	while [ -z "$selected_dir" ]; do
		curl -fsSL --retry 5 --retry-delay 2 \
			-H 'Accept: application/vnd.github+json' \
			"$api/releases?per_page=100&page=$page" > "$releases_file"
		if [ "$(jq 'length' "$releases_file")" -eq 0 ]; then
			break
		fi
		while read -r tag; do
			[ -n "$tag" ] || continue
			candidate_dir="$(mktemp -d)"
			if try_release "$tag" "$candidate_dir"; then
				selected_dir="$candidate_dir"
				break
			fi
			rm -rf "$candidate_dir"
		done < <(jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' "$releases_file")
		page=$((page + 1))
	done
	rm -f "$releases_file"
	if [ -z "$selected_dir" ]; then
		echo "No verified Kwrt SDK release matches package_arch=$package_arch" >&2
		exit 1
	fi
fi

release_tag="$(<"$selected_dir/selected-tag")"
sdk_asset="$(<"$selected_dir/selected-asset")"
sdk_url="$(<"$selected_dir/sdk-url")"
sdk_sha="$(<"$selected_dir/sdk-sha256")"
cp -f "$selected_dir/MANIFEST.refs" "$metadata_dir/MANIFEST.refs"
cp -f "$selected_dir/ASSETS.sha256sums" "$metadata_dir/ASSETS.sha256sums"
rm -rf "$selected_dir"

{
	echo "sdk_repository=$repository"
	echo "sdk_release_tag=$release_tag"
	echo "sdk_asset=$sdk_asset"
	echo "sdk_sha256=$sdk_sha"
	echo "package_arch=$package_arch"
} > "$metadata_dir/SDK.refs"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "release_tag=$release_tag"
		echo "sdk_asset=$sdk_asset"
		echo "sdk_sha256=$sdk_sha"
		echo "download_url=$sdk_url"
	} >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "SDK_RELEASE_TAG=$release_tag"
		echo "SDK_ASSET_NAME=$sdk_asset"
		echo "SDK_SHA256=$sdk_sha"
		echo "SDK_DOWNLOAD_URL=$sdk_url"
	} >> "$GITHUB_ENV"
fi

printf '%s %s\n' "$release_tag" "$sdk_asset"
