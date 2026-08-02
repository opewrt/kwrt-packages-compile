include $(TOPDIR)/rules.mk

PKG_NAME:=custom-download
PKG_SOURCE:=custom-download-1.0.tar.gz
PKG_SOURCE_URL:=https://example.invalid/releases
PKG_HASH:=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

define Download/generated
	URL:=https://example.invalid/generated
	URL_FILE:=generated-1.0.tar.gz
	FILE:=generated.tar.gz
	VERSION:=1.0
	HASH:=skip
endef

define Download/missing-hash
	URL:=https://example.invalid/missing-hash
	FILE:=missing-hash.tar.gz
endef
