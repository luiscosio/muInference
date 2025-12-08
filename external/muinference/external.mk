# Register the external tree
# Add this directory when invoking Buildroot: BR2_EXTERNAL=../external/muinference

# Include all package makefiles from this external tree
include $(sort $(wildcard $(BR2_EXTERNAL_MUINFERENCE_PATH)/package/*/*.mk))
