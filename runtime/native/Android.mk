LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := usbmanager_auth
LOCAL_SRC_FILES := usb_auth_ffs.c
LOCAL_CFLAGS := -O2 -Wall -Wextra -Werror
LOCAL_LDLIBS := -llog
include $(BUILD_SHARED_LIBRARY)
