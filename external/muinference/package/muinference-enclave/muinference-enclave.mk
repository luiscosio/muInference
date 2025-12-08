################################################################################
#
# muinference-enclave
#
################################################################################

MUINFERENCE_ENCLAVE_VERSION = 1.0
MUINFERENCE_ENCLAVE_SITE = $(BR2_EXTERNAL_MUINFERENCE_PATH)
MUINFERENCE_ENCLAVE_SITE_METHOD = local
MUINFERENCE_ENCLAVE_LICENSE = Apache-2.0

define MUINFERENCE_ENCLAVE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(BR2_EXTERNAL_MUINFERENCE_PATH)/rootfs_overlay/opt/enclave_server.py \
		$(TARGET_DIR)/opt/enclave_server.py
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_MUINFERENCE_PATH)/rootfs_overlay/etc/muinference.conf \
		$(TARGET_DIR)/etc/muinference.conf
endef

$(eval $(generic-package))
