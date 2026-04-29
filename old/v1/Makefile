include $(TOPDIR)/rules.mk

PKG_NAME:=autorecorder
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/autorecorder
  SECTION:=multimedia
  CATEGORY:=Multimedia
  TITLE:=Automatic USB audio recording
  DEPENDS:=+alsa-utils +kmod-usb-storage +block-mount +kmod-usb3 \
           +moreutils +kmod-usb-audio +usbutils +perlbase-time
  PKGARCH:=all
endef

define Package/autorecorder/description
  Automatically record multichannel USB audio whenever
  both a USB drive and an audio interface are plugged in.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/autorecorder/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./recorder $(1)/usr/sbin/recorder
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./initscript $(1)/etc/init.d/autorecorder
	$(INSTALL_DIR) $(1)/etc/hotplug.d/block
	$(INSTALL_CONF) ./hotplug $(1)/etc/hotplug.d/block/autorecorder
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_CONF) ./hotplug $(1)/etc/hotplug.d/usb/autorecorder
endef

$(eval $(call BuildPackage,autorecorder))
