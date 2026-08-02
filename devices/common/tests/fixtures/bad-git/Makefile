include $(TOPDIR)/rules.mk

PKG_NAME:=bad-git
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/example/bad-git.git
PKG_SOURCE_VERSION:=abcdef1
PKG_HASH:=skip
LATEST_URL:=https://github.com/example/bad-git/releases/latest/download/source.tar.gz
RAW_URL:=https://raw.githubusercontent.com/example/bad-git/main/file.txt
ARCHIVE_URL:=https://github.com/example/bad-git/archive/HEAD.tar.gz

define Build/Prepare
	curl -fL https://example.invalid/generated.txt -o generated.txt
endef

define Build/Configure
	npm install
	go get example.invalid/module
	rm -f package-lock.json
endef
