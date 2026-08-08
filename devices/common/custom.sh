#!/bin/bash
set -euo pipefail

shopt -s extglob nullglob

PRIVATE_FEEDS_FILE="$PWD/.private-feeds"
MANAGED_FEEDS_FILE="$PWD/.managed-feeds"
rm -f "$PRIVATE_FEEDS_FILE" "$MANAGED_FEEDS_FILE"
printf '%s\n' packages luci routing kiddin9 > "$MANAGED_FEEDS_FILE"

if [ -d "${PRIVATE_FEEDS_ROOT:-}" ]; then
	for repo_path in "$PRIVATE_FEEDS_ROOT"/*; do
		[ -d "$repo_path" ] || continue
		repo_name="${repo_path##*/}"
		feed_name="${repo_name#luci-app-}"
		printf 'src-link %s %s\n' "$feed_name" "$repo_path" >> feeds.conf
		printf '%s\n' "$feed_name" >> "$PRIVATE_FEEDS_FILE"
		printf '%s\n' "$feed_name" >> "$MANAGED_FEEDS_FILE"
	done
else
	echo "Private feeds are unavailable; skipping."
fi

./scripts/feeds update -a

cjdns_makefile="feeds/routing/cjdns/Makefile"
cjdns_patch="feeds/routing/cjdns/patches/040-gyp-python_310.patch"
grep -qx 'PKG_RELEASE:=6' "$cjdns_makefile"
sed -i 's/^PKG_RELEASE:=6$/PKG_RELEASE:=7/' "$cjdns_makefile"
install -m0644 devices/common/cjdns-gyp-python311.patch "$cjdns_patch"

rm -rf feeds/kiddin9/{diy,mt-drivers,shortcut-fe,luci-app-mtwifi,base-files,luci-app-package-manager,\
dnsmasq,firewall*,wifi-scripts,opkg,ppp,curl,luci-app-firewall,\
nftables,fstools,wireless-regdb,libnftnl}

./scripts/feeds install -a -p kiddin9 -f
./scripts/feeds install -a
if [ -f "$PRIVATE_FEEDS_FILE" ]; then
	while read -r feed_name; do
		[ -n "$feed_name" ] || continue
		./scripts/feeds install -a -p "$feed_name" -f
	done < "$PRIVATE_FEEDS_FILE"
fi

rm -f package/feeds/kiddin9/luci-app-quickstart/root/usr/share/luci/menu.d/luci-app-quickstart.json

controller_files=(package/feeds/kiddin9/luci-*/luasrc/controller/*.lua)
if [ "${#controller_files[@]}" -gt 0 ]; then
	sed -i 's/\(page\|e\)\?.acl_depends.*\?}//' "${controller_files[@]}"
fi

kiddin9_makefiles=(package/feeds/kiddin9/*/Makefile)
if [ "${#kiddin9_makefiles[@]}" -gt 0 ]; then
	sed -i \
		-e "s/+\(luci\|luci-ssl\|uhttpd\)\( \|$\)/\2/" \
		-e "s/+nginx\( \|$\)/+nginx-ssl\1/" \
		-e 's/+python\( \|$\)/+python3/' \
		-e 's?../../lang?$(TOPDIR)/feeds/packages/lang?' \
		-e 's,$(STAGING_DIR_HOST)/bin/upx,upx,' \
		"${kiddin9_makefiles[@]}"
fi

cp -f devices/common/.config .config
make defconfig

for defaults_file in package/feeds/*/luci-theme*/root/etc/uci-defaults/*; do
	[ -f "$defaults_file" ] || continue
	sed -i '/mediaurlbase/d' "$defaults_file"
done

sed -i '/WARNING: Makefile/d' scripts/package-metadata.pl

cp -f devices/common/po2lmo staging_dir/host/bin/po2lmo
chmod +x staging_dir/host/bin/po2lmo
