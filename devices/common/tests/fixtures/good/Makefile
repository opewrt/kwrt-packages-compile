include $(TOPDIR)/rules.mk

PKG_NAME:=good-source
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/example/good-source.git
PKG_SOURCE_VERSION:=0123456789abcdef0123456789abcdef01234567
PKG_MIRROR_HASH:=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# https://github.com/example/good-source/releases/latest/download/source.tar.gz
# PKG_HASH:=skip

define Build/Prepare
	# wget https://example.invalid/source.tar.gz
	$(call Build/Prepare/Default)
endef
