include $(TOPDIR)/rules.mk

PKG_NAME:=locked-installs

define Build/Compile
	pnpm install --frozen-lockfile
	yarn install --immutable
	yarn install --frozen-lockfile
	npm ci
	cargo fetch --locked
endef
