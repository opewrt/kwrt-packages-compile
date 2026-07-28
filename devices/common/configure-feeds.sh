#!/usr/bin/env bash
set -euo pipefail

manifest="${1:-}"
if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
	echo "Usage: configure-feeds.sh MANIFEST.refs" >&2
	exit 1
fi

get_ref() {
	local key="$1"
	local ref
	ref="$(sed -n "s/^${key}=//p" "$manifest" | tail -n 1)"
	if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
		echo "Missing or invalid ${key} in $manifest" >&2
		exit 1
	fi
	printf '%s\n' "$ref"
}

openwrt_ref="$(get_ref openwrt)"
packages_ref="$(get_ref feed.packages)"
luci_ref="$(get_ref feed.luci)"
routing_ref="$(get_ref feed.routing)"
kiddin9_ref="$(get_ref feed.kiddin9)"

cat > feeds.conf <<EOF
src-git-full base https://git.openwrt.org/openwrt/openwrt.git^${openwrt_ref}
src-git packages https://github.com/opewrt/openwrt-packages.git^${packages_ref}
src-git luci https://github.com/opewrt/openwrt-luci.git^${luci_ref}
src-git routing https://github.com/opewrt/openwrt-routing.git^${routing_ref}
src-git kiddin9 https://github.com/opewrt/kwrt-packages.git^${kiddin9_ref}
EOF
