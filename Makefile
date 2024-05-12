include $(TOPDIR)/rules.mk
PKG_NAME:=autorecorder
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk
define Package/autorecorder
	SECTION:=multimedia
	CATEGORY:=Multimedia
	TITLE:=Automatic USB audio recording
endef

define Package/autorecorder/description
	Automatically record multichannel USB audio whenever
	both a USB drive and an audio interface are plugged in.
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/helloworld/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/recorder $(1)/usr/sbin/recorder
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/initscript $(1)/etc/init.d/autorecorder
	$(INSTALL_DIR) $(1)/etc/hotplug.d/block
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/hotplug $(1)/etc/hotplug.d/block/hotplug
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/hotplug $(1)/etc/hotplug.d/usb/hotplug
endef
